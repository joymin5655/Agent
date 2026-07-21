#!/usr/bin/env bash
# call-worker.sh — cross-vendor worker dispatcher.
#
# Resolves a role from core/infra/backends.json (role -> backend at a tier ->
# CLI argv), streams the prompt from stdin to the backend CLI, and captures the
# reply to .agent/workers/<utc-ts>-<role>.md (path printed on stdout). Model
# names never appear here or in backends.json — each vendor's adapter/profile
# owns its tier (docs/model-routing.md § Cross-vendor lanes).
#
# Registry v2 (v1 registries keep exact v1 behavior — every new key optional):
#   - argv = backend.cmd + backend.tier_args[role.tier] + role.args_extra
#   - backend.enabled: false -> loud refusal citing disabled_reason (never a
#     silent fallback); backend.preflight argv is run first when present, and
#     a failing preflight is the same loud-unavailable path.
#   - The capture header carries "status:" — the mechanical truth layer
#     (complete|failed|timeout|unavailable) beneath any lane self-report.
#
# Design (explicit failure over silence):
#   - External calls cost money. Without AGENT_WORKER_YES=1 the dispatcher
#     refuses (exit 3) and says how to approve. The gate is env-only by design:
#     a dispatched/headless caller cannot answer an interactive confirm — the
#     session that owns the user relationship asks, then sets the env.
#   - A missing CLI names the missing tool (exit 127 when no backend remains).
#   - Fallback records WHY the primary was skipped (header + stderr).
#   - A hung worker is killed at timeout_s (exit 124 when no fallback remains).
#
# usage: call-worker.sh <role> < prompt.md
# exit:  0 ok | 1 backend failed (its raw exit code is reported on stderr,
#        never forwarded — it would collide with the codes below)
#        2 usage/config | 3 not approved | 124 timeout | 127 no backend CLI
#        (disabled/preflight-failed backends terminate 127 too — "unavailable")
# env seams (tests): AGENT_BACKENDS_FILE, AGENT_WORKERS_DIR, AGENT_WORKER_YES,
#                    AGENT_WORKER_TIMEOUT_S, AGENT_WORKER_KILL_GRACE_S,
#                    AGENT_WORKER_PREFLIGHT_TIMEOUT_S
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKENDS_FILE="${AGENT_BACKENDS_FILE:-$REPO_ROOT/core/infra/backends.json}"
WORKERS_DIR="${AGENT_WORKERS_DIR:-$REPO_ROOT/.agent/workers}"

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
    echo "usage: call-worker.sh <role> < prompt.md   (roles: $(command -v jq >/dev/null 2>&1 && jq -r '.roles | keys | join(", ")' "$BACKENDS_FILE" 2>/dev/null || echo "see backends.json"))" >&2
    exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "call-worker: jq is required (brew install jq / apt install jq)" >&2; exit 2; }
[[ -f "$BACKENDS_FILE" ]] || { echo "call-worker: backends registry not found: $BACKENDS_FILE" >&2; exit 2; }

PRIMARY="$(jq -r --arg r "$ROLE" '.roles[$r].backend // empty' "$BACKENDS_FILE")"
if [[ -z "$PRIMARY" ]]; then
    echo "call-worker: unknown role '$ROLE' (known: $(jq -r '.roles | keys | join(", ")' "$BACKENDS_FILE"))" >&2
    exit 2
fi
FALLBACK="$(jq -r --arg r "$ROLE" '.roles[$r].fallback // empty' "$BACKENDS_FILE")"
ROLE_TIER="$(jq -r --arg r "$ROLE" '.roles[$r].tier // empty' "$BACKENDS_FILE")"

# Cost gate — env-only on purpose: headless callers can't answer prompts.
if [[ "${AGENT_WORKER_YES:-0}" != "1" ]]; then
    echo "call-worker: '$ROLE' dispatches to external backend '$PRIMARY' (paid call)." >&2
    echo "call-worker: approve with AGENT_WORKER_YES=1 (per-invocation; the caller asks the user first)." >&2
    exit 3
fi

# The prompt is consumed once so both primary and fallback can replay it.
PROMPT_TMP="$(mktemp)"
OUT_TMP="$(mktemp)"
cleanup() { rm -f "$PROMPT_TMP" "$OUT_TMP"; }
trap cleanup EXIT INT TERM
cat > "$PROMPT_TMP"

# run_backend <name> — 0 ok, 124 timeout, 125 unavailable (disabled/preflight,
# reason in $UNAVAILABLE_REASON), 127 CLI missing, else CLI's exit.
# Reply lands in $OUT_TMP. Portable timeout (macOS ships no GNU timeout):
# background worker + watchdog; TERM from the watchdog maps to 124.
UNAVAILABLE_REASON=""
run_backend() {
    local name="$1" timeout_s grace_s rc=0 pid wpid
    jq -e --arg b "$name" '.backends[$b]' "$BACKENDS_FILE" >/dev/null 2>&1 \
        || { echo "call-worker: backend '$name' not defined in $BACKENDS_FILE" >&2; return 64; }
    # v2: a declared backend can be switched off — refuse loudly, never silently.
    # (== false, not `// true`: jq's // treats false itself as absent.)
    if [[ "$(jq -r --arg b "$name" '.backends[$b].enabled == false' "$BACKENDS_FILE")" == "true" ]]; then
        UNAVAILABLE_REASON="backend '$name' disabled in registry: $(jq -r --arg b "$name" '.backends[$b].disabled_reason // "no reason recorded"' "$BACKENDS_FILE")"
        echo "call-worker: $UNAVAILABLE_REASON" >&2
        return 125
    fi
    local cmd=()
    while IFS= read -r line; do cmd+=("$line"); done \
        < <(jq -r --arg b "$name" '.backends[$b].cmd[]' "$BACKENDS_FILE")
    [[ ${#cmd[@]} -gt 0 ]] || { echo "call-worker: backend '$name' has an empty cmd in $BACKENDS_FILE" >&2; return 64; }
    command -v "${cmd[0]}" >/dev/null 2>&1 || return 127
    # v2 preflight (absent in v1 registries -> skipped): a cheap health probe
    # so an unauthenticated/broken CLI surfaces as "unavailable", not a paid
    # dispatch that dies mid-flight. Watchdogged so a hung probe can't wedge us.
    local pf=()
    while IFS= read -r line; do pf+=("$line"); done \
        < <(jq -r --arg b "$name" '.backends[$b].preflight // [] | .[]' "$BACKENDS_FILE")
    if [[ ${#pf[@]} -gt 0 ]]; then
        local prc=0
        "${pf[@]}" </dev/null >/dev/null 2>&1 &
        pid=$!
        ( sleep "${AGENT_WORKER_PREFLIGHT_TIMEOUT_S:-10}" && kill -KILL "$pid" 2>/dev/null ) &
        wpid=$!
        wait "$pid" || prc=$?
        kill "$wpid" 2>/dev/null || true
        wait "$wpid" 2>/dev/null || true
        if [[ $prc -ne 0 ]]; then
            UNAVAILABLE_REASON="backend '$name' preflight failed (${pf[*]} -> exit $prc)"
            echo "call-worker: $UNAVAILABLE_REASON" >&2
            return 125
        fi
    fi
    # v2 argv composition: cmd + tier_args[role.tier] + role.args_extra.
    # All optional — a v1 registry composes to bare cmd, byte-for-byte.
    if [[ -n "$ROLE_TIER" ]]; then
        while IFS= read -r line; do cmd+=("$line"); done \
            < <(jq -r --arg b "$name" --arg t "$ROLE_TIER" '.backends[$b].tier_args[$t] // [] | .[]' "$BACKENDS_FILE")
    fi
    while IFS= read -r line; do cmd+=("$line"); done \
        < <(jq -r --arg r "$ROLE" '.roles[$r].args_extra // [] | .[]' "$BACKENDS_FILE")
    timeout_s="${AGENT_WORKER_TIMEOUT_S:-$(jq -r --arg b "$name" '.backends[$b].timeout_s // 300' "$BACKENDS_FILE")}"
    [[ "$timeout_s" =~ ^[0-9]+$ ]] \
        || { echo "call-worker: backend '$name' timeout_s is not numeric ('$timeout_s') — the watchdog would silently never fire" >&2; return 64; }
    grace_s="${AGENT_WORKER_KILL_GRACE_S:-5}"

    "${cmd[@]}" < "$PROMPT_TMP" > "$OUT_TMP" 2>&1 &
    pid=$!
    # TERM at timeout, KILL after a grace period — a CLI wrapper that traps or
    # fails to forward TERM must not defeat the timeout guarantee.
    ( sleep "$timeout_s" && kill -TERM "$pid" 2>/dev/null \
        && sleep "$grace_s" && kill -KILL "$pid" 2>/dev/null ) &
    wpid=$!
    wait "$pid" || rc=$?
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    # SIGTERM (143) / SIGKILL (137) can only come from the watchdog in this
    # process tree — report the conventional timeout code (race-free: no
    # watchdog liveness check, which the fired-vs-tearing-down window defeats).
    [[ $rc -eq 143 || $rc -eq 137 ]] && rc=124
    return "$rc"
}

FALLBACK_REASON=""
BACKEND_USED="$PRIMARY"
rc=0
run_backend "$PRIMARY" || rc=$?

if [[ $rc -ne 0 && -n "$FALLBACK" ]]; then
    case "$rc" in
        127) FALLBACK_REASON="primary '$PRIMARY' CLI not found" ;;
        125) FALLBACK_REASON="primary '$PRIMARY' unavailable (${UNAVAILABLE_REASON:-backend exited 125})" ;;
        124) FALLBACK_REASON="primary '$PRIMARY' timed out" ;;
        *)   FALLBACK_REASON="primary '$PRIMARY' exited $rc" ;;
    esac
    echo "call-worker: $FALLBACK_REASON — falling back to '$FALLBACK'" >&2
    BACKEND_USED="$FALLBACK"
    rc=0
    run_backend "$FALLBACK" || rc=$?
fi

# write_capture <status> — durable evidence for every terminal path where a
# backend was (or should have been) engaged; path printed on stdout. status is
# the mechanical truth layer: a lane's own success claim never overrides it.
write_capture() {
    mkdir -p "$WORKERS_DIR"
    OUT_FILE="$WORKERS_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$ROLE.md"
    {
        echo "---"
        echo "role: $ROLE"
        echo "backend: $BACKEND_USED"
        echo "status: $1"
        echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [[ -n "$FALLBACK_REASON" ]] && echo "fallback_reason: $FALLBACK_REASON"
        [[ -n "$UNAVAILABLE_REASON" ]] && echo "unavailable_reason: $UNAVAILABLE_REASON"
        echo "---"
        echo
        cat "$OUT_TMP"
    } > "$OUT_FILE"
    echo "$OUT_FILE"
}

if [[ $rc -eq 127 || $rc -eq 125 ]]; then
    if [[ -n "$FALLBACK_REASON" ]]; then
        echo "call-worker: no backend available for '$ROLE' — $FALLBACK_REASON, and fallback '$FALLBACK' is unavailable too. Fix one of them." >&2
    elif [[ $rc -eq 127 ]]; then
        echo "call-worker: backend '$PRIMARY' CLI not found (role '$ROLE' has no fallback). Install it or add a fallback in $BACKENDS_FILE." >&2
    fi   # 125 with no fallback already printed its reason inside run_backend
    write_capture "unavailable" >/dev/null
    exit 127
fi
if [[ $rc -ne 0 ]]; then
    echo "call-worker: backend '$BACKEND_USED' failed (exit $rc) for role '$ROLE'; output follows:" >&2
    cat "$OUT_TMP" >&2
    # Normalize: only the documented codes escape this script — a backend's
    # raw exit code (reported above) must not collide with 2/3/124/127.
    [[ $rc -eq 124 ]] && { write_capture "timeout" >/dev/null; exit 124; }
    [[ $rc -eq 64 ]] && exit 2     # run_backend registry/config error (EX_USAGE internally, so a backend's own raw 2 can't collide)
    write_capture "failed" >/dev/null
    exit 1
fi

write_capture "complete"
