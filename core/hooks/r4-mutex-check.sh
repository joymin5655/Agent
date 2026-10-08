#!/usr/bin/env bash
# PreToolUse hook — R4 resource mutex
#
# When multiple AI sessions run in parallel (Claude in worktree A, Codex in worktree B,
# Gemini in worktree C), they can't all hold a write-lock on the same shared resource
# (production database, serverless function deploy, production deploy command).
#
# This hook checks the central lock file (.agent/locks/active-sessions.json) and returns
# `ask` if a different session has claimed the resource the current tool call targets.
#
# Wire into your AI's PreToolUse with matcher "*" (see adapters/<ai>/settings.template).
#
# Resource categories (defaults — extend via hook-config.yml):
#   - production-db      DB migration / direct SQL on production
#   - edge-function-deploy  Serverless function deploy
#   - production-deploy  Frontend/backend production deploy
#
# Hook protocol: reads canonical event JSON from stdin, writes decision JSON
# (ask) to stdout when a different session owns the resource, or empty stdout
# (allow) otherwise. Exit always 0.

set -e

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "R4 reminder: jq unavailable — mutex check skipped. Install with: brew install jq" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve canonical repo root (handles worktrees) — needed both by the
# WorktreeCreate/WorktreeRemove branch below and by the resource-lock path.
# ---------------------------------------------------------------------------
resolve_canonical_root() {
  local common_dir root
  if common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    if [[ "$(basename "$common_dir")" == ".git" ]]; then
      root="$(dirname "$common_dir")"
    else
      root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    (cd "$root" 2>/dev/null && pwd -P) && return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

ROOT="$(resolve_canonical_root)"
WORKTREES_DIR="$ROOT/.worktrees"
LOCK_FILE="$ROOT/.agent/locks/active-sessions.json"

# ---------------------------------------------------------------------------
# Resolve current session ID — shared by WorktreeCreate/WorktreeRemove
# registration and the resource-mutex path below.
# ---------------------------------------------------------------------------
resolve_session_id() {
  local sid=""
  if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
    sid="$AGENT_SESSION_ID"
  fi
  if [[ -z "$sid" ]]; then
    local cwd wt_rel wt_name
    cwd="$(pwd -P)"
    if [[ "$cwd" == "$WORKTREES_DIR"/* ]]; then
      wt_rel="${cwd#"$WORKTREES_DIR"/}"
      wt_name="${wt_rel%%/*}"
      if [[ "$wt_name" =~ ^(claude|codex|gemini)-(.+)$ ]]; then
        sid="${BASH_REMATCH[1]}-wt-${BASH_REMATCH[2]}"
      fi
    fi
  fi
  if [[ -z "$sid" ]]; then
    sid="${AGENT:-claude}-main"
  fi
  echo "$sid"
}

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // .event // ""' 2>/dev/null) || HOOK_EVENT=""

case "$HOOK_EVENT" in
  WorktreeCreate|WorktreeRemove)
    # NOT wired in hooks/hooks.json or settings.json.template: Claude Code treats
    # a WorktreeCreate hook as a replacement for git's worktree creation (it must
    # print the new path), so this observer branch would break every worktree.
    # Kept as tested logic — docs/hook-protocol.md §12.
    # Register/release the worktree as a session-held resource in the SAME
    # lock file the resource-mutex path below reads (.agent/locks/active-sessions.json,
    # shared_resource_locks map) — reuses the existing R4 mechanism rather than
    # inventing a second lock store. Probe stdin keys defensively: the Claude
    # docs (2026-09-26) don't pin an exact field name for the worktree path, so
    # try path / worktree_path / name / branch in that order, first hit wins.
    # Per docs/hook-protocol.md these events are observation-only — NEVER emit
    # a decision (empty stdout always), exit 0 always.
    WT_PATH=$(printf '%s' "$INPUT" | jq -r '.path // .worktree_path // .name // .branch // ""' 2>/dev/null) || WT_PATH=""
    if [[ -z "$WT_PATH" ]]; then
      exit 0
    fi
    RESOURCE="worktree:${WT_PATH}"
    SESSION_ID="$(resolve_session_id)"
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    # Delegate the write to agent-session.sh claim/release: its update_lock()
    # runs under the .mutex.d mkdir-mutex, so two concurrent Worktree events
    # cannot lose each other's update (an inline jq+mv here would race).
    # Same canonical root => same lock file. A 1s mutex budget keeps a busy
    # lock from stalling the hook; claim exits 1 when another session owns the
    # worktree, which is not our problem to decide here (observation only).
    SESSION_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)/agent-session.sh"
    if [[ -x "$SESSION_SH" ]]; then
      if [[ "$HOOK_EVENT" == "WorktreeCreate" ]]; then
        AGENT_SESSION_ID="$SESSION_ID" AGENT_SESSION_MUTEX_TIMEOUT=1 \
          "$SESSION_SH" claim "$RESOURCE" >/dev/null 2>&1 || true
      else
        AGENT_SESSION_ID="$SESSION_ID" AGENT_SESSION_MUTEX_TIMEOUT=1 \
          "$SESSION_SH" release "$RESOURCE" >/dev/null 2>&1 || true
      fi
    fi
    exit 0
    ;;
esac

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // ""')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# ---------------------------------------------------------------------------
# Resource detection — match tool call to a known shared resource.
# Default patterns shown; extend via hook-config.yml: resources[].matches.
# ---------------------------------------------------------------------------
RESOURCE=""

case "$TOOL_NAME" in
  Bash)
    # Database migration commands (multiple frameworks)
    if echo "$COMMAND" | grep -qE '(^|[;&|`(])\s*(npx|pnpm|npm exec)?\s*(supabase|prisma|knex|sequelize-cli)\s+(db\s+push|migrate\s+(up|deploy)|migration\s+(up|apply|run))'; then
      RESOURCE=production-db
    elif echo "$COMMAND" | grep -qE '(alembic\s+upgrade|django-admin\s+migrate|rails\s+db:migrate)'; then
      RESOURCE=production-db
    # Serverless function deploy commands
    elif echo "$COMMAND" | grep -qE '(supabase|firebase|vercel|netlify)\s+functions?\s+(deploy|publish)'; then
      RESOURCE=edge-function-deploy
    # Production deploy commands
    elif echo "$COMMAND" | grep -qE '(wrangler\s+(pages|workers)\s+deploy|fly\s+deploy|vercel\s+--prod|netlify\s+deploy\s+--prod|gh\s+workflow\s+run\s+[^ ]*deploy)'; then
      RESOURCE=production-deploy
    fi
    ;;
  *)
    # MCP tool patterns (match common DB / deploy MCP servers)
    case "$TOOL_NAME" in
      *__apply_migration|*__execute_sql|*__db_push)    RESOURCE=production-db ;;
      *__deploy_edge_function|*__deploy_function)      RESOURCE=edge-function-deploy ;;
      *__deploy_project|*__deploy_production)          RESOURCE=production-deploy ;;
    esac
    ;;
esac

if [[ -z "$RESOURCE" ]]; then
  exit 0
fi

# ROOT / LOCK_FILE / WORKTREES_DIR were already resolved above (shared with
# the WorktreeCreate/WorktreeRemove branch).
SESSION_ID="$(resolve_session_id)"

# ---------------------------------------------------------------------------
# Look up the resource owner
# ---------------------------------------------------------------------------
if [[ ! -f "$LOCK_FILE" ]]; then
  echo "R4 reminder: '$RESOURCE' targeted but no lock file found at $LOCK_FILE — coordinate manually." >&2
  exit 0
fi

OWNER=$(jq -r --arg r "$RESOURCE" '.shared_resource_locks[$r].session_id // empty' "$LOCK_FILE" 2>/dev/null || echo "")

if [[ -z "$OWNER" ]]; then
  echo "R4 reminder: '$RESOURCE' is unclaimed. Consider: AGENT_SESSION_ID=$SESSION_ID core/infra/agent-session.sh claim $RESOURCE" >&2
  exit 0
fi

if [[ "$OWNER" == "$SESSION_ID" ]]; then
  exit 0
fi

CLAIMED=$(jq -r --arg r "$RESOURCE" '.shared_resource_locks[$r].claimed_at // ""' "$LOCK_FILE")
OWNER_AGENT=$(jq -r --arg sid "$OWNER" '[.sessions[]? | select(.session_id == $sid) | .agent] | first // "unknown"' "$LOCK_FILE")
OWNER_BRANCH=$(jq -r --arg sid "$OWNER" '[.sessions[]? | select(.session_id == $sid) | .branch] | first // "unknown"' "$LOCK_FILE")

# Append to security-violations.jsonl (silent-fail)
log_violation() {
  local guard="$1" reason="$2" resource="$3"
  local log_dir="${AGENT_GATE_SINK_DIR:-$ROOT/.agent/logs}"
  local log_file="$log_dir/security-violations.jsonl"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  local origin="${AGENT_LOG_ORIGIN:-session}"
  origin="${origin//[^A-Za-z0-9_.-]/}"
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${SESSION_ID:-main}"
  local repro="false"
  case "${AGENT_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  printf '{"ts":"%s","guard":"%s","hook":"r4-mutex-check.sh","resource":"%s","reason":%s,"session_id":"%s","decision":"ask","reproduce_test":%s,"origin":"%s","schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$resource" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$repro" "$origin" \
    >> "$log_file" 2>/dev/null || true
  [[ -x "$ROOT/core/infra/agent-session.sh" ]] && \
    "$ROOT/core/infra/agent-session.sh" broadcast blocked \
      "[security] r4-mutex-check.sh: $resource owned by other session" >/dev/null 2>&1 || true
}

case "$RESOURCE" in
  production-db)          GUARD=production-data ;;
  edge-function-deploy)   GUARD=deploy ;;
  production-deploy)      GUARD=deploy ;;
  *)                      GUARD=other ;;
esac
log_violation "$GUARD" "R4 BLOCK $RESOURCE owned by $OWNER" "$RESOURCE"

python3 - "$RESOURCE" "$OWNER" "$OWNER_AGENT" "$OWNER_BRANCH" "$CLAIMED" "$SESSION_ID" <<'PY'
import json, sys
resource, owner, owner_agent, owner_branch, claimed, current = sys.argv[1:7]
reason = (
    f"R4 BLOCK: '{resource}' is claimed by another session.\n"
    f"  owner_session = {owner}\n"
    f"  owner_agent   = {owner_agent}\n"
    f"  owner_branch  = {owner_branch}\n"
    f"  claimed_at    = {claimed}\n"
    f"  current       = {current}\n"
    f"Wait for the owner to release, or coordinate manually:\n"
    f"  AGENT_SESSION_ID={owner} core/infra/agent-session.sh release {resource}"
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
