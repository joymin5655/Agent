#!/usr/bin/env bash
# supervisor-goal.sh — Goal state machine (SQLite-backed) for multi-wave plan execution.
#
# Usage:
#   bash core/infra/supervisor-goal.sh init <plan-slug> <total-waves> [budget] [objective]
#   bash core/infra/supervisor-goal.sh status [plan-slug]
#   bash core/infra/supervisor-goal.sh advance-wave <plan-slug> <completed-wave-num>
#   bash core/infra/supervisor-goal.sh pause <plan-slug>
#   bash core/infra/supervisor-goal.sh resume <plan-slug>
#   bash core/infra/supervisor-goal.sh complete <plan-slug>
#   bash core/infra/supervisor-goal.sh abort <plan-slug> <reason>
#   bash core/infra/supervisor-goal.sh clear <plan-slug>
#   bash core/infra/supervisor-goal.sh check-active
#   bash core/infra/supervisor-goal.sh track-tokens <plan-slug> <delta>
#   bash core/infra/supervisor-goal.sh heartbeat <plan-slug>
#
# 5 status: active / paused / budget_limited / complete / aborted

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOCK_DIR="$REPO_ROOT/.agent/locks"
DB_FILE="$LOCK_DIR/goal-state.db"
SCHEMA_FILE="$REPO_ROOT/core/infra/sql/001_supervisor_goals.sql"
AUDIT_LOG="$REPO_ROOT/.agent/logs/supervisor-goal-audit.jsonl"

# Optional graceful-wrap output paths (consumer project may override).
GRACEFUL_WIKI_DIR="${AGENT_GRACEFUL_WIKI_DIR:-$REPO_ROOT/wiki/synthesis}"
GRACEFUL_MEMORY_DIR="${AGENT_GRACEFUL_MEMORY_DIR:-}"

mkdir -p "$LOCK_DIR" "$(dirname "$AUDIT_LOG")"

for cmd in sqlite3 jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd missing. Install via your package manager (e.g., brew install $cmd)" >&2
        exit 127
    fi
done

init_db() {
    if [[ ! -f "$DB_FILE" ]]; then
        if [[ ! -f "$SCHEMA_FILE" ]]; then
            echo "ERROR: schema missing: $SCHEMA_FILE" >&2
            exit 2
        fi
        sqlite3 "$DB_FILE" < "$SCHEMA_FILE"
    fi
}

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

sql_escape() { printf "%s" "$1" | sed "s/'/''/g"; }

cmd_init() {
    # objective's default references slug, so it must be a SEPARATE local
    # statement: bash 3.2 + set -u treats a same-line reference as unbound,
    # which made every objective-less `init <slug> <waves>` crash (latent
    # until the F-2 battery first exercised the 2-arg form).
    local slug="${1:-}" waves="${2:-}" budget="${3:-}"
    local objective="${4:-$slug}"
    if [[ -z "$slug" || -z "$waves" ]]; then
        echo "usage: supervisor-goal.sh init <plan-slug> <total-waves> [budget] [objective]" >&2
        exit 2
    fi

    init_db
    local goal_id="goal_$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '-' | head -c 16 || date +%s)"
    local ts; ts="$(now_ms)"

    local budget_sql="NULL"
    if [[ -n "$budget" && "$budget" =~ ^[0-9]+$ ]]; then
        budget_sql="$budget"
    fi

    sqlite3 "$DB_FILE" <<SQL
INSERT INTO supervisor_goals (
    goal_id, plan_slug, objective, status, token_budget,
    current_wave, total_waves, created_at_ms, updated_at_ms, last_heartbeat_ms
) VALUES (
    '$goal_id',
    '$(sql_escape "$slug")',
    '$(sql_escape "$objective")',
    'active',
    $budget_sql,
    1,
    $waves,
    $ts,
    $ts,
    $ts
);
SQL

    sqlite3 "$DB_FILE" "SELECT json_object(
        'goal_id', goal_id,
        'plan_slug', plan_slug,
        'status', status,
        'current_wave', current_wave,
        'total_waves', total_waves,
        'token_budget', token_budget,
        'tokens_used', tokens_used,
        'created_at_ms', created_at_ms
    ) FROM supervisor_goals WHERE goal_id = '$goal_id';"
}

cmd_status() {
    init_db
    local slug="${1:-}"
    if [[ -z "$slug" ]]; then
        sqlite3 "$DB_FILE" "SELECT json_group_array(json_object(
            'goal_id', goal_id,
            'plan_slug', plan_slug,
            'status', status,
            'current_wave', current_wave,
            'total_waves', total_waves,
            'tokens_used', tokens_used,
            'token_budget', token_budget,
            'last_heartbeat_ms', last_heartbeat_ms
        )) FROM supervisor_goals;"
    else
        sqlite3 "$DB_FILE" "SELECT json_object(
            'goal_id', goal_id,
            'plan_slug', plan_slug,
            'objective', objective,
            'status', status,
            'current_wave', current_wave,
            'total_waves', total_waves,
            'waves_completed', waves_completed,
            'tokens_used', tokens_used,
            'token_budget', token_budget,
            'time_used_seconds', time_used_seconds,
            'safeguard_aborts', safeguard_aborts,
            'last_heartbeat_ms', last_heartbeat_ms
        ) FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';"
    fi
}

cmd_advance_wave() {
    local slug="${1:-}" wave_num="${2:-}"
    if [[ -z "$slug" || -z "$wave_num" ]]; then
        echo "usage: supervisor-goal.sh advance-wave <plan-slug> <completed-wave-num>" >&2
        exit 2
    fi
    init_db
    local ts; ts="$(now_ms)"

    local current_completed
    current_completed=$(sqlite3 "$DB_FILE" "SELECT waves_completed FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';")
    if [[ -z "$current_completed" ]]; then
        echo "ERROR: goal not found: $slug" >&2
        exit 3
    fi

    local new_completed
    new_completed=$(echo "$current_completed" | jq --argjson w "$wave_num" '. + [$w] | unique')

    sqlite3 "$DB_FILE" <<SQL
UPDATE supervisor_goals SET
    waves_completed = '$new_completed',
    current_wave = current_wave + 1,
    updated_at_ms = $ts,
    last_heartbeat_ms = $ts
WHERE plan_slug = '$(sql_escape "$slug")';

UPDATE supervisor_goals SET status = 'complete'
WHERE plan_slug = '$(sql_escape "$slug")'
  AND current_wave > total_waves
  AND status = 'active';
SQL

    cmd_status "$slug"
}

cmd_pause() {
    local slug="${1:-}"
    [[ -z "$slug" ]] && { echo "usage: ... pause <plan-slug>" >&2; exit 2; }
    init_db
    sqlite3 "$DB_FILE" "UPDATE supervisor_goals SET status = 'paused', updated_at_ms = $(now_ms) WHERE plan_slug = '$(sql_escape "$slug")' AND status = 'active';"
    cmd_status "$slug"
}

cmd_resume() {
    local slug="${1:-}"
    [[ -z "$slug" ]] && { echo "usage: ... resume <plan-slug>" >&2; exit 2; }
    init_db
    sqlite3 "$DB_FILE" "UPDATE supervisor_goals SET status = 'active', updated_at_ms = $(now_ms), last_heartbeat_ms = $(now_ms) WHERE plan_slug = '$(sql_escape "$slug")' AND status = 'paused';"
    cmd_status "$slug"
}

# F-2: repo-native execution ledger. On complete, drop a RECORD.md stub into
# the plan's dir so the execution record exists even on runtimes with no
# global recording layer. Mechanical ledger only (waves / PRs / audit verdict /
# carried items) — the session narrative belongs to the global layer, so the
# two never duplicate. The supervise skill fills the <fill …> slots; this stub
# is the deterministic guarantee that the file exists. Fail-safe by contract:
# a ledger write must never block goal completion, and a RECORD.md the skill
# already wrote is never clobbered.
write_record_stub() {
    local slug="$1"
    # slug is a path component below: refuse separators / traversal so a weird
    # slug can never place the ledger outside the plans root (fail-safe skip)
    case "$slug" in */*|*..*) return 0 ;; esac
    local plans_root="${AGENT_PLANS_DIR:-$REPO_ROOT/.agent/plans}"
    local rec="$plans_root/$slug/RECORD.md"
    [[ -f "$rec" ]] && return 0
    mkdir -p "$plans_root/$slug" 2>/dev/null || return 0
    local waves total
    waves=$(sqlite3 "$DB_FILE" "SELECT waves_completed FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';" 2>/dev/null | jq -r 'length' 2>/dev/null) || waves="?"
    total=$(sqlite3 "$DB_FILE" "SELECT total_waves FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';" 2>/dev/null) || total="?"
    {
        echo "# ${slug} — execution record"
        echo ""
        echo "status: complete ($(now_iso))"
        echo ""
        echo "- waves: ${waves:-?}/${total:-?} completed"
        echo "- prs: <fill — PRs opened/merged by this plan>"
        echo "- audit verdict: <fill — per-wave audit outcomes>"
        echo "- carried: <fill — deferred items from the plan>"
    } > "$rec" 2>/dev/null || return 0
}

cmd_complete() {
    local slug="${1:-}"
    [[ -z "$slug" ]] && { echo "usage: ... complete <plan-slug>" >&2; exit 2; }
    init_db
    sqlite3 "$DB_FILE" "UPDATE supervisor_goals SET status = 'complete', updated_at_ms = $(now_ms) WHERE plan_slug = '$(sql_escape "$slug")';"
    write_record_stub "$slug" || true
    cmd_status "$slug"
}

cmd_abort() {
    local slug="${1:-}" reason="${2:-unspecified}"
    [[ -z "$slug" ]] && { echo "usage: ... abort <plan-slug> <reason>" >&2; exit 2; }
    init_db
    local ts; ts="$(now_ms)"

    local current_aborts
    current_aborts=$(sqlite3 "$DB_FILE" "SELECT safeguard_aborts FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';")
    if [[ -z "$current_aborts" ]]; then
        echo "ERROR: goal not found: $slug" >&2
        exit 3
    fi
    local new_aborts
    new_aborts=$(echo "$current_aborts" | jq --arg r "$reason" --arg t "$(now_iso)" '. + [{"ts":$t,"reason":$r}]')

    sqlite3 "$DB_FILE" <<SQL
UPDATE supervisor_goals SET
    status = 'aborted',
    safeguard_aborts = '$(echo "$new_aborts" | sed "s/'/''/g")',
    updated_at_ms = $ts
WHERE plan_slug = '$(sql_escape "$slug")';
SQL

    cmd_status "$slug"
}

cmd_clear() {
    local slug="${1:-}"
    [[ -z "$slug" ]] && { echo "usage: ... clear <plan-slug>" >&2; exit 2; }
    init_db
    sqlite3 "$DB_FILE" "DELETE FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';"
    echo "{\"cleared\":\"$slug\"}"
}

cmd_check_active() {
    init_db
    local cutoff_ms
    cutoff_ms=$(( $(now_ms) - 5*60*1000 ))
    sqlite3 "$DB_FILE" "SELECT json_group_array(json_object(
        'goal_id', goal_id,
        'plan_slug', plan_slug,
        'status', status,
        'current_wave', current_wave,
        'total_waves', total_waves,
        'tokens_used', tokens_used,
        'token_budget', token_budget,
        'last_heartbeat_ms', last_heartbeat_ms
    )) FROM supervisor_goals
      WHERE status = 'active'
        AND last_heartbeat_ms >= $cutoff_ms;"
}

cmd_track_tokens() {
    local slug="${1:-}" delta="${2:-}"
    if [[ -z "$slug" || -z "$delta" ]]; then
        echo "usage: ... track-tokens <plan-slug> <delta>" >&2
        exit 2
    fi
    if [[ ! "$delta" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR: delta not integer: $delta" >&2
        exit 2
    fi
    init_db
    local ts; ts="$(now_ms)"

    sqlite3 "$DB_FILE" <<SQL
UPDATE supervisor_goals SET
    tokens_used = tokens_used + $delta,
    updated_at_ms = $ts,
    last_heartbeat_ms = $ts
WHERE plan_slug = '$(sql_escape "$slug")' AND status = 'active';

UPDATE supervisor_goals SET status = 'budget_limited'
WHERE plan_slug = '$(sql_escape "$slug")'
  AND status = 'active'
  AND token_budget IS NOT NULL
  AND tokens_used >= token_budget;
SQL

    local new_status
    new_status="$(sqlite3 "$DB_FILE" "SELECT status FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';" 2>/dev/null || echo "")"
    if [[ "$new_status" == "budget_limited" ]]; then
        _emit_graceful_wrap "$slug" || true
    fi

    cmd_status "$slug"
}

# Emit a graceful-wrap stub when status transitions to 'budget_limited'.
# Output dir defaults to $REPO_ROOT/wiki/synthesis; override via AGENT_GRACEFUL_WIKI_DIR.
# Optional second stub in AGENT_GRACEFUL_MEMORY_DIR (e.g., for an auto-memory system).
_emit_graceful_wrap() {
    local slug="$1"
    local date_iso; date_iso="$(date +%Y-%m-%d)"

    local wiki_file="$GRACEFUL_WIKI_DIR/${slug}-budget-limited-${date_iso}.md"
    if [[ -d "$GRACEFUL_WIKI_DIR" && ! -f "$wiki_file" ]]; then
        local goal_dump
        goal_dump="$(sqlite3 "$DB_FILE" -line "SELECT * FROM supervisor_goals WHERE plan_slug = '$(sql_escape "$slug")';" 2>/dev/null || echo "(SQLite read fail)")"
        cat > "$wiki_file" <<EOF
---
title: ${slug} — budget_limited graceful wrap
type: synthesis
created: ${date_iso}
sources:
  - core/infra/supervisor-goal.sh
tags:
  - supervisor-goal
  - budget-limited
  - graceful-wrap
  - auto-generated
---

# ${slug} — Budget Limited Graceful Wrap

Auto-generated when supervisor-goal status transitioned 'active' → 'budget_limited'.

## Goal State

\`\`\`
${goal_dump}
\`\`\`

## Continuation

On next session:
1. Inspect: \`bash core/infra/supervisor-goal.sh status ${slug}\`
2. Resume by explicit user invocation (no auto-resume).
3. Re-budget: \`bash core/infra/supervisor-goal.sh init ${slug} <total> <new-budget>\`

## Notes

This file is a stub. Expand in the next session with:
- Per-wave results / artifacts / PRs / lessons.
- Verification: zero risk-area violations.
- Remaining-wave trigger inventory.
EOF
    fi

    if [[ -n "$GRACEFUL_MEMORY_DIR" && -d "$GRACEFUL_MEMORY_DIR" ]]; then
        local mem_file="$GRACEFUL_MEMORY_DIR/handoff_${date_iso}_${slug}-budget-limited.md"
        if [[ ! -f "$mem_file" ]]; then
            cat > "$mem_file" <<EOF
---
name: ${slug} budget_limited graceful wrap stub
description: Auto-generated when supervisor-goal status='budget_limited'. Full content in graceful-wrap wiki file.
type: project
---

# ${slug} — Budget Limited (stub)

Auto-generated $(date +%Y-%m-%d\ %H:%M:%S). status transitioned 'active' → 'budget_limited'.

See: \`${wiki_file}\`
EOF
        fi
    fi
}

cmd_heartbeat() {
    local slug="${1:-}"
    [[ -z "$slug" ]] && { echo "usage: ... heartbeat <plan-slug>" >&2; exit 2; }
    init_db
    sqlite3 "$DB_FILE" "UPDATE supervisor_goals SET last_heartbeat_ms = $(now_ms) WHERE plan_slug = '$(sql_escape "$slug")' AND status = 'active';"
}

case "${1:-}" in
    init)         shift; cmd_init "$@" ;;
    status)       shift; cmd_status "$@" ;;
    advance-wave) shift; cmd_advance_wave "$@" ;;
    pause)        shift; cmd_pause "$@" ;;
    resume)       shift; cmd_resume "$@" ;;
    complete)     shift; cmd_complete "$@" ;;
    abort)        shift; cmd_abort "$@" ;;
    clear)        shift; cmd_clear "$@" ;;
    check-active) shift; cmd_check_active "$@" ;;
    track-tokens) shift; cmd_track_tokens "$@" ;;
    heartbeat)    shift; cmd_heartbeat "$@" ;;
    *)
        cat >&2 <<EOF
supervisor-goal.sh — SQLite goal state machine

Commands:
  init <plan-slug> <total-waves> [budget] [objective]
  status [plan-slug]
  advance-wave <plan-slug> <completed-wave-num>
  pause <plan-slug>
  resume <plan-slug>
  complete <plan-slug>
  abort <plan-slug> <reason>
  clear <plan-slug>
  check-active
  track-tokens <plan-slug> <delta>
  heartbeat <plan-slug>

DB:         $DB_FILE
schema:     $SCHEMA_FILE
audit log:  $AUDIT_LOG
EOF
        exit 2
        ;;
esac
