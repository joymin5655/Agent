#!/usr/bin/env bash
# codex-shell-wrap.sh — Intercepts Codex's shell tool calls and gates them via
# the framework's pre-tool-guard + r4-mutex + secret-content-scan hooks.
#
# Install:
#   1. Copy or symlink this script onto PATH as 'codex-bash' (e.g., ~/bin/codex-bash).
#   2. In ~/.codex/config.toml, point the shell tool's executable at codex-bash:
#        [tools.shell]
#        command = "codex-bash"
#   3. Codex's existing shell tool args ($@) are passed through unchanged.
#
# Behavior:
#   - Wraps each invocation as a synthetic PreToolUse event.
#   - Pipes through pre-tool-guard.sh → r4-mutex-check.sh.
#   - If either hook emits {"permissionDecision":"deny"}, the command is BLOCKED
#     (exit 100). User sees the reason on stderr.
#   - If decision is "ask", BLOCKS by default — codex re-prompts the user.
#   - On allow / no-decision, executes the original bash -c "<cmd>".

set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
ADAPTER="$ADAPTER_DIR/adapter.sh"

# Reconstruct command — codex passes ["bash", "-lc", "<cmd>"] or similar.
if [[ "${1:-}" == "-lc" || "${1:-}" == "-c" ]]; then
    REAL_CMD="${2:-}"
else
    REAL_CMD="$*"
fi

if [[ -z "$REAL_CMD" ]]; then
    exit 0
fi

# Run gate hooks in order. First deny wins.
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
            echo "[codex-shell-wrap] BLOCKED by $hook ($VERDICT): $REASON" >&2
            exit 100
        fi
    fi
done

# Allow — execute original command.
exec bash -lc "$REAL_CMD"
