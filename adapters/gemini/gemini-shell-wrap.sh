#!/usr/bin/env bash
# gemini-shell-wrap.sh — Intercepts Gemini CLI's shell tool calls and gates them
# via the framework's pre-tool-guard + r4-mutex + secret-content-scan hooks.
#
# Install:
#   1. Put on PATH as 'gemini-bash' (e.g., ~/bin/gemini-bash).
#   2. In ~/.gemini/settings.json, override the shell tool to invoke this:
#        {"tools": {"shell": {"command": "gemini-bash"}}}
#   3. Gemini's existing shell args ($@) are passed through.
#
# Behavior matches codex-shell-wrap.sh:
#   deny / ask → exit 100 with stderr reason
#   allow      → exec original bash -c "<cmd>"

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
ADAPTER="$ADAPTER_DIR/adapter.sh"

if [[ "${1:-}" == "-lc" || "${1:-}" == "-c" ]]; then
    REAL_CMD="${2:-}"
else
    REAL_CMD="$*"
fi

if [[ -z "$REAL_CMD" ]]; then
    exit 0
fi

for hook in pre-tool-guard.sh r4-mutex-check.sh; do
    HOOK_PATH="$FRAMEWORK_ROOT/core/hooks/$hook"
    [[ ! -x "$HOOK_PATH" ]] && continue

    DECISION=$("$ADAPTER" "$hook" --tool Bash --command "$REAL_CMD" 2>/dev/null || true)

    if [[ -n "$DECISION" ]] && command -v python3 >/dev/null 2>&1; then
        VERDICT=$(echo "$DECISION" | python3 -c "
import json, sys
try:
    obj = json.loads(sys.stdin.read())
    out = obj.get('hookSpecificOutput', {})
    print(out.get('permissionDecision', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")
        REASON=$(echo "$DECISION" | python3 -c "
import json, sys
try:
    obj = json.loads(sys.stdin.read())
    out = obj.get('hookSpecificOutput', {})
    print(out.get('permissionDecisionReason', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

        if [[ "$VERDICT" == "deny" || "$VERDICT" == "ask" ]]; then
            echo "[gemini-shell-wrap] BLOCKED by $hook ($VERDICT): $REASON" >&2
            exit 100
        fi
    fi
done

exec bash -lc "$REAL_CMD"
