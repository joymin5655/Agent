#!/usr/bin/env bash
# Codex CLI adapter — translates Codex tool-call envelopes into the canonical
# hook event protocol, invokes a core hook, and returns the decision JSON.
#
# Codex CLI does NOT yet expose a native PreToolUse/PostToolUse hook system
# the way Claude Code does. This adapter therefore offers TWO modes:
#
# Mode 1 — Direct invoke (works today):
#   When codex is configured to call shell wrappers around its built-in tools
#   (bash, write_file, etc.), each wrapper can pipe its call envelope through
#   this adapter before executing the action. See codex-shell-wrap.sh.
#
# Mode 2 — Future-compat event bridge (placeholder):
#   When codex grows native hooks (tracking https://github.com/openai/codex
#   issue queue), this adapter is the entry point — it normalises input from
#   codex's eventual hook format into the canonical event JSON shape.
#
# Usage:
#   adapter.sh <hook-name>                   # stdin = canonical or codex JSON
#   adapter.sh <hook-name> --tool <name> --command '<cmd>'   # synthetic mode
#
# Input (canonical, accepted as-is):
#   {"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"..."},...}
#
# Input (codex-style — translated by this adapter):
#   {"type":"shell_call","arguments":{"command":["bash","-lc","..."]}}
#   {"type":"file_write","path":"...","content":"..."}
#
# Output (canonical):
#   {"hookSpecificOutput":{"hookEventName":"...","permissionDecision":"allow|ask|deny","permissionDecisionReason":"..."}}

set -euo pipefail

HOOK_NAME="${1:-}"
if [[ -z "$HOOK_NAME" ]]; then
    echo "usage: adapter.sh <hook-name> [--tool <name> --command '<cmd>']" >&2
    exit 2
fi
shift

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
HOOK_PATH="$FRAMEWORK_ROOT/core/hooks/$HOOK_NAME"
TRANSLATOR="$ADAPTER_DIR/adapter.py"

if [[ ! -x "$HOOK_PATH" ]]; then
    exit 0
fi

# Synthetic-mode: build canonical event JSON from flag args.
TOOL=""
TOOL_CMD=""
TOOL_FILE=""
TOOL_CONTENT=""
EVENT="PreToolUse"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tool)     TOOL="${2:-}"; shift 2 ;;
        --command)  TOOL_CMD="${2:-}"; shift 2 ;;
        --file)     TOOL_FILE="${2:-}"; shift 2 ;;
        --content)  TOOL_CONTENT="${2:-}"; shift 2 ;;
        --event)    EVENT="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -n "$TOOL" ]]; then
    # Build canonical JSON from the flag args via ENV, not string interpolation, so a
    # command/content containing a quote, newline, or ''' cannot break out of the
    # python literal. The old interpolated form both mis-parsed quoted commands
    # (breaking cross-adapter parity) and was a guard-bypass vector (a crafted command
    # could inject python and force an allow).
    INPUT_JSON=$(_EVENT="$EVENT" _TOOL="$TOOL" _CMD="$TOOL_CMD" _FILE="$TOOL_FILE" _CONTENT="$TOOL_CONTENT" \
        python3 -c '
import json, os
out = {"event": os.environ["_EVENT"], "ai": "codex", "tool_name": os.environ["_TOOL"], "tool_input": {}}
if os.environ.get("_CMD"):     out["tool_input"]["command"]   = os.environ["_CMD"]
if os.environ.get("_FILE"):    out["tool_input"]["file_path"] = os.environ["_FILE"]
if os.environ.get("_CONTENT"): out["tool_input"]["content"]   = os.environ["_CONTENT"]
print(json.dumps(out))
')
    printf '%s\n' "$INPUT_JSON" | "$HOOK_PATH"
    exit $?
fi

# Stdin mode — translate if needed, then pipe to core hook.
if [[ -x "$TRANSLATOR" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$TRANSLATOR" | "$HOOK_PATH"
    exit $?
fi

# Fallback — assume stdin already canonical.
exec "$HOOK_PATH"
