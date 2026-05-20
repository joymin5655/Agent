#!/usr/bin/env bash
# AirLens — PreToolUse R4 mutex check.
# Blocks production-db / edge-function-deploy / production-deploy tool calls
# when a different agent session has claimed the resource.
# Wire in .claude/settings.local.json PreToolUse with matcher "*".

set -e

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "R4 reminder: jq unavailable — mutex check skipped." >&2
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // ""')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

RESOURCE=""

case "$TOOL_NAME" in
  Bash)
    if echo "$COMMAND" | grep -qE '(^|[;&|`(])\s*(npx|pnpm|npm exec)?\s*supabase\s+(db\s+push|migration\s+(up|apply))'; then
      RESOURCE=production-db
    elif echo "$COMMAND" | grep -qE 'supabase\s+functions\s+deploy'; then
      RESOURCE=edge-function-deploy
    elif echo "$COMMAND" | grep -qE '(wrangler\s+pages\s+deploy|fly\s+deploy|gh\s+workflow\s+run\s+[^ ]*deploy)'; then
      RESOURCE=production-deploy
    fi
    ;;
  *)
    case "$TOOL_NAME" in
      *supabase__apply_migration|*supabase__execute_sql) RESOURCE=production-db ;;
      *supabase__deploy_edge_function)                   RESOURCE=edge-function-deploy ;;
    esac
    ;;
esac

if [[ -z "$RESOURCE" ]]; then
  exit 0
fi

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
LOCK_FILE="$ROOT/.claude/locks/active-sessions.json"
WORKTREES_DIR="$ROOT/.worktrees"

SESSION_ID=""
if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
  SESSION_ID="$AGENT_SESSION_ID"
fi
if [[ -z "$SESSION_ID" ]]; then
  CWD="$(pwd -P)"
  if [[ "$CWD" == "$WORKTREES_DIR"/* ]]; then
    rel="${CWD#"$WORKTREES_DIR"/}"
    wt_name="${rel%%/*}"
    if [[ "$wt_name" =~ ^(claude|codex|gemini)-(.+)$ ]]; then
      SESSION_ID="${BASH_REMATCH[1]}-wt-${BASH_REMATCH[2]}"
    fi
  fi
fi
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="${AGENT:-claude}-main"
fi

if [[ ! -f "$LOCK_FILE" ]] || ! command -v jq >/dev/null 2>&1; then
  echo "R4 reminder: '$RESOURCE' targeted but lock file or jq unavailable — coordinate manually." >&2
  exit 0
fi

OWNER=$(jq -r --arg r "$RESOURCE" '.shared_resource_locks[$r].session_id // empty' "$LOCK_FILE" 2>/dev/null || echo "")

if [[ -z "$OWNER" ]]; then
  echo "R4 reminder: '$RESOURCE' is unclaimed. Consider: AGENT=... AGENT_SESSION_ID=$SESSION_ID scripts/infra/agent-session.sh claim $RESOURCE" >&2
  exit 0
fi

if [[ "$OWNER" == "$SESSION_ID" ]]; then
  exit 0
fi

CLAIMED=$(jq -r --arg r "$RESOURCE" '.shared_resource_locks[$r].claimed_at // ""' "$LOCK_FILE")
OWNER_AGENT=$(jq -r --arg sid "$OWNER" '[.sessions[]? | select(.session_id == $sid) | .agent] | first // "unknown"' "$LOCK_FILE")
OWNER_BRANCH=$(jq -r --arg sid "$OWNER" '[.sessions[]? | select(.session_id == $sid) | .branch] | first // "unknown"' "$LOCK_FILE")

# security-violations.jsonl sink (security-guards.md SOT 정합, schema v2 2026-05-14)
log_violation() {
  local guard="$1" reason="$2" resource="$3" decision="${4:-ask}"
  local log_file="$ROOT/.claude/logs/security-violations.jsonl"
  mkdir -p "$ROOT/.claude/logs" 2>/dev/null || return 0
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${SESSION_ID:-main}"
  local repro="false"
  case "${AIRLENS_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  printf '{"ts":"%s","guard":%s,"hook":"r4-mutex-check.sh","resource":"%s","reason":%s,"session_id":"%s","decision":"%s","reproduce_test":%s,"schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$resource" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$decision" "$repro" \
    >> "$log_file" 2>/dev/null || true
  # work-feed broadcast (R13 — blocked event, multi-agent visibility)
  [[ -x "$ROOT/scripts/infra/agent-session.sh" ]] && \
    "$ROOT/scripts/infra/agent-session.sh" broadcast blocked \
      "[security] r4-mutex-check.sh: $resource owned by other session" >/dev/null 2>&1 || true
}

case "$RESOURCE" in
  production-db)          GUARD=1 ;;
  edge-function-deploy)   GUARD=3 ;;
  production-deploy)      GUARD=1 ;;
  *)                      GUARD=0 ;;
esac
log_violation "$GUARD" "R4 ASK $RESOURCE owned by $OWNER" "$RESOURCE" "ask"

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
    f"Wait for owner to release, or coordinate manually:\n"
    f"  AGENT=... AGENT_SESSION_ID={owner} scripts/infra/agent-session.sh release {resource}"
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
