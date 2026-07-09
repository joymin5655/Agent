#!/usr/bin/env bash
# PreToolUse hook — Context-Mode sandbox guard
#
# Catches `ctx_execute` / `ctx_execute_file` / `ctx_batch_execute` MCP tool calls
# (from the Context-Mode plugin) whose nested code or commands attempt:
#   - R4-protected resources (production DB, deploy, edge functions)
#   - Direct secrets/ path reference
#   - source / .  on .env files
#   - Production secret env var dereference
#
# These plugin tools run in a permissive sandbox that bypasses Bash matchers,
# so a separate guard is required.
#
# Wire under PreToolUse "*" matcher, AFTER r4-mutex-check.sh. See adapters/<ai>/settings.template.

set -e

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "context-mode-guard: jq unavailable — skipped." >&2
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // ""')

# Match only the 3 sandbox-execute tools (other context-mode tools are read-only / safe)
TARGET=""
case "$TOOL_NAME" in
  *context-mode__ctx_execute|*context_mode__ctx_execute)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.code // ""')
    ;;
  *context-mode__ctx_execute_file|*context_mode__ctx_execute_file)
    TARGET=$(printf '%s' "$INPUT" | jq -r '"\(.tool_input.path // "") \(.tool_input.code // "")"')
    ;;
  *context-mode__ctx_batch_execute|*context_mode__ctx_batch_execute)
    TARGET=$(printf '%s' "$INPUT" | jq -r '[.tool_input.commands[]?.command // ""] | join(" || ")')
    ;;
  *)
    exit 0
    ;;
esac

if [[ -z "$TARGET" ]]; then
  exit 0
fi

REASON=""
if echo "$TARGET" | grep -qE '(^|[;&|`(])\s*(npx|pnpm|npm exec)?\s*(supabase|prisma|knex)\s+(db\s+push|migration\s+(up|apply)|migrate\s+(up|deploy))'; then
  REASON="R4 production-db (DB migration command)"
elif echo "$TARGET" | grep -qE '(alembic\s+upgrade|django-admin\s+migrate|rails\s+db:migrate)'; then
  REASON="R4 production-db (DB migration command)"
elif echo "$TARGET" | grep -qE '(supabase|firebase|vercel|netlify)\s+functions?\s+(deploy|publish)'; then
  REASON="R4 edge-function-deploy (serverless function deploy)"
elif echo "$TARGET" | grep -qE '(wrangler\s+(pages|workers)\s+deploy|fly\s+deploy|vercel\s+--prod|netlify\s+deploy\s+--prod|gh\s+workflow\s+run\s+[^ ]*deploy)'; then
  REASON="R4 production-deploy (production deploy command)"
elif echo "$TARGET" | grep -qE '(^|[[:space:]/=])secrets/'; then
  REASON="secrets/ path reference"
elif echo "$TARGET" | grep -qE '(\.\s|source\s)[^|;&]*(/\.env(\.|$|\s)|\.env\b)'; then
  REASON="source .env (token plaintext exposure risk)"
elif echo "$TARGET" | grep -qE '\$(AWS_SECRET_ACCESS_KEY|GCP_SERVICE_ACCOUNT_KEY|CLOUDFLARE_API_TOKEN|ANTHROPIC_API_KEY|OPENAI_API_KEY|STRIPE_SECRET_KEY|GITHUB_TOKEN|SUPABASE_SERVICE_ROLE_KEY)'; then
  REASON="production secret env var reference"
fi

if [[ -z "$REASON" ]]; then
  exit 0
fi

TARGET_PREVIEW=$(printf '%s' "$TARGET" | head -c 200)
TRUNC_MARKER=""
if [[ "${#TARGET}" -gt 200 ]]; then
  TRUNC_MARKER="...(truncated)"
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

log_violation() {
  local guard="$1" reason="$2" decision="$3"
  local log_file="$ROOT/.agent/logs/security-violations.jsonl"
  mkdir -p "$ROOT/.agent/logs" 2>/dev/null || return 0
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${AGENT_SESSION_ID:-main}"
  local repro="false"
  case "${AGENT_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  printf '{"ts":"%s","guard":"%s","hook":"context-mode-guard.sh","tool":"%s","reason":%s,"session_id":"%s","decision":"%s","reproduce_test":%s,"schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$TOOL_NAME" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$decision" "$repro" \
    >> "$log_file" 2>/dev/null || true
  [[ -x "$ROOT/core/infra/agent-session.sh" ]] && \
    "$ROOT/core/infra/agent-session.sh" broadcast blocked \
      "[security] context-mode-guard.sh: $reason" >/dev/null 2>&1 || true
}

# Decision: §2 Secret = deny; R4 production-data / deploy = ask (user confirms)
case "$REASON" in
  *production-db*|*production-deploy*) GUARD=production-data; DECISION="ask" ;;
  *edge-function-deploy*) GUARD=deploy; DECISION="ask" ;;
  *) GUARD=secrets; DECISION="deny" ;;
esac
log_violation "$GUARD" "$REASON" "$DECISION"

DENY_MSG="Context-Mode sandbox guard BLOCK: $REASON
  tool_name = $TOOL_NAME
  target    = ${TARGET_PREVIEW}${TRUNC_MARKER}

Context-Mode 'permissive' sandbox would otherwise bypass R4 mutex / secrets policy.
Use the dedicated path:
  - For shared resources: core/infra/agent-session.sh claim <resource> + direct Bash
  - For secrets inspection: length inventory only (awk -F=), never source/cat

See rules/policy/security-guards.md and docs/hook-protocol.md."

python3 - "$DENY_MSG" "$DECISION" <<'PY'
import json, sys
reason, decision = sys.argv[1], sys.argv[2]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
