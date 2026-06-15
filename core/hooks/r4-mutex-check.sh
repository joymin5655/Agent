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

# ---------------------------------------------------------------------------
# Resolve canonical repo root (handles worktrees)
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
LOCK_FILE="$ROOT/.agent/locks/active-sessions.json"
WORKTREES_DIR="$ROOT/.worktrees"

# ---------------------------------------------------------------------------
# Resolve current session ID
# ---------------------------------------------------------------------------
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
  local log_file="$ROOT/.agent/logs/security-violations.jsonl"
  mkdir -p "$ROOT/.agent/logs" 2>/dev/null || return 0
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${SESSION_ID:-main}"
  local repro="false"
  case "${AGENT_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  printf '{"ts":"%s","guard":"%s","hook":"r4-mutex-check.sh","resource":"%s","reason":%s,"session_id":"%s","decision":"ask","reproduce_test":%s,"schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$resource" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$repro" \
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
