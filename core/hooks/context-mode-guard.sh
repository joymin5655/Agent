#!/usr/bin/env bash
# AirLens — PreToolUse Context Mode sandbox guard.
# Blocks `ctx_execute` / `ctx_execute_file` / `ctx_batch_execute` when their
# code/commands attempt R4-protected resources or secrets/* access.
# Wire in .claude/settings.local.json PreToolUse with matcher "*"
# (after r4-mutex-check.sh, after gsd-cwd-guard.sh, before fk-type-precheck.py).

set -e

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "Context Mode guard: jq unavailable — skipped." >&2
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // ""')

# Extract target string (3 dangerous tools — schema confirmed via server.bundle.mjs grep 2026-05-06)
TARGET=""
case "$TOOL_NAME" in
  *context-mode__ctx_execute)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.code // ""')
    ;;
  *context-mode__ctx_execute_file)
    # Both path (file location) and code (processing logic) are attack surfaces
    TARGET=$(printf '%s' "$INPUT" | jq -r '"\(.tool_input.path // "") \(.tool_input.code // "")"')
    ;;
  *context-mode__ctx_batch_execute)
    # commands is array of {label, command} objects per zod schema
    TARGET=$(printf '%s' "$INPUT" | jq -r '[.tool_input.commands[]?.command // ""] | join(" || ")')
    ;;
  *)
    exit 0
    ;;
esac

if [[ -z "$TARGET" ]]; then
  exit 0
fi

# R4 resource patterns — production-db / edge-function-deploy / production-deploy
# Mirror scripts/hooks/r4-mutex-check.sh patterns. Allow read-only ops (list/diff/status).
REASON=""
if echo "$TARGET" | grep -qE '(^|[;&|`(])\s*(npx|pnpm|npm exec)?\s*supabase\s+(db\s+push|migration\s+(up|apply))'; then
  REASON="R4 production-db (supabase db push / migration up|apply)"
elif echo "$TARGET" | grep -qE 'supabase\s+functions\s+deploy'; then
  REASON="R4 edge-function-deploy (supabase functions deploy)"
elif echo "$TARGET" | grep -qE '(wrangler\s+pages\s+deploy|fly\s+deploy|gh\s+workflow\s+run\s+[^ ]*deploy)'; then
  REASON="R4 production-deploy (wrangler/fly/gh workflow deploy)"
# secrets/ direct path reference (matches both bare path and command-prefixed)
elif echo "$TARGET" | grep -qE '(^|[[:space:]/=])secrets/'; then
  REASON="secrets/ path reference"
elif echo "$TARGET" | grep -qE '(\.\s|source\s)[^|;&]*(/\.env(\.|$|\s)|web\.env|models\.env)'; then
  REASON="source *.env (token plaintext exposure risk)"
# Production secret env var name references (echo/printf leak)
elif echo "$TARGET" | grep -qE '\$(SUPABASE_SERVICE_ROLE_KEY|WAQI_TOKEN|OPENAQ_API_KEY|CLOUDFLARE_API_TOKEN)'; then
  REASON="production secret env var reference"
fi

if [[ -z "$REASON" ]]; then
  exit 0
fi

# Truncate target safely — avoid set -e + && short-circuit pitfall
TARGET_PREVIEW=$(printf '%s' "$TARGET" | head -c 200)
TRUNC_MARKER=""
if [[ "${#TARGET}" -gt 200 ]]; then
  TRUNC_MARKER="...(truncated)"
fi

# security-violations.jsonl sink (security-guards.md SOT 정합, schema v2 2026-05-14)
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
log_violation() {
  local guard="$1" reason="$2" decision="$3"
  local log_file="$ROOT/.claude/logs/security-violations.jsonl"
  mkdir -p "$ROOT/.claude/logs" 2>/dev/null || return 0
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${AGENT_SESSION_ID:-main}"
  local repro="false"
  case "${AIRLENS_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  printf '{"ts":"%s","guard":%s,"hook":"context-mode-guard.sh","tool":"%s","reason":%s,"session_id":"%s","decision":"%s","reproduce_test":%s,"schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$TOOL_NAME" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$decision" "$repro" \
    >> "$log_file" 2>/dev/null || true
  # work-feed broadcast (R13 — blocked event, multi-agent visibility)
  [[ -x "$ROOT/scripts/infra/agent-session.sh" ]] && \
    "$ROOT/scripts/infra/agent-session.sh" broadcast blocked \
      "[security] context-mode-guard.sh: $reason" >/dev/null 2>&1 || true
}
# guard 매핑: R4-* = guard 1 or 3, secrets/source/env = guard 2
# decision 분기 (2026-05-18 wobbly-percolating-panda): §2 Secret (guard 2) = deny 유지, §1/§3 (guard 1/3) = ask 완화
case "$REASON" in
  *production-db*|*production-deploy*) GUARD=1; DECISION="ask" ;;
  *edge-function-deploy*) GUARD=3; DECISION="ask" ;;
  *) GUARD=2; DECISION="deny" ;;  # §2 Secret 변경 — deny 유지 (security-guards.md §2)
esac
log_violation "$GUARD" "$REASON" "$DECISION"

DENY_MSG="Context Mode sandbox guard BLOCK: $REASON
  tool_name = $TOOL_NAME
  target    = ${TARGET_PREVIEW}${TRUNC_MARKER}

Context Mode 'permissive' sandbox would otherwise bypass R4 mutex / secrets policy.
Use the dedicated path:
  - For R4 resources: scripts/infra/agent-session.sh claim <resource> + direct Bash invocation
  - For secrets inspection: length inventory only (awk -F= 'NR==FNR{...}'), never source/cat

Decision rule: ~/.claude/plans/snazzy-stargazing-hartmanis.md (context-mode-sandbox-guard, 2026-05-06)
Policy: .claude/rules/external-plugin-policy.md §3 E"

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
