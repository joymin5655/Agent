#!/usr/bin/env bash
# Claude Code adapter — thin pass-through to a core hook.
#
# Claude Code's native hook protocol (PreToolUse/PostToolUse/SessionStart/Stop/
# UserPromptSubmit) matches the canonical event JSON in docs/hook-protocol.md.
# Adapter therefore just exec's the named core hook with stdin/stdout untouched.
#
# Usage (from ~/.claude/settings.json hooks block):
#   "command": "/path/to/Agent/adapters/claude-code/adapter.sh <hook-name>"
#
# <hook-name> = filename in core/hooks/ (e.g., pre-tool-guard.sh, supervisor.py).
#
# The Claude Code runtime feeds event JSON on stdin and expects either:
#   - empty stdout = silent pass
#   - decision JSON = {"hookSpecificOutput": {"hookEventName": "...", "permissionDecision": "allow|ask|deny", "permissionDecisionReason": "..."}}

set -euo pipefail

HOOK_NAME="${1:-}"
if [[ -z "$HOOK_NAME" ]]; then
    echo "usage: adapter.sh <hook-name>" >&2
    exit 2
fi

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
HOOK_PATH="$FRAMEWORK_ROOT/core/hooks/$HOOK_NAME"

if [[ ! -x "$HOOK_PATH" ]]; then
    # silent pass-through if hook missing — never block Claude Code on infra glitch
    exit 0
fi

# Exec the hook. Stdin/stdout/stderr inherited. Exit code propagated.
exec "$HOOK_PATH"
