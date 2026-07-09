#!/usr/bin/env bash
# Gemini CLI adapter — translates Gemini tool-call envelopes into the
# canonical hook event protocol, invokes a core hook, and returns the
# decision JSON.
#
# Gemini CLI exposes a settings.json `tools` block that lets the user
# point shell-style tools at external executables. This adapter is the
# executable that goes there — it normalises Gemini's call shape into the
# canonical event JSON and pipes through the framework's gate hooks.
#
# Usage:
#   adapter.sh <hook-name>                   # stdin = canonical or gemini JSON
#   adapter.sh <hook-name> --tool <name> --command '<cmd>'   # synthetic mode
#
# Input (canonical):
#   {"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"..."},...}
#
# Input (gemini-style — translated):
#   {"name":"run_shell_command","args":{"command":"..."}}
#   {"name":"write_file","args":{"file_path":"...","content":"..."}}
#
# Output: canonical decision JSON.

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
out = {"event": os.environ["_EVENT"], "ai": "gemini", "tool_name": os.environ["_TOOL"], "tool_input": {}}
if os.environ.get("_CMD"):     out["tool_input"]["command"]   = os.environ["_CMD"]
if os.environ.get("_FILE"):    out["tool_input"]["file_path"] = os.environ["_FILE"]
if os.environ.get("_CONTENT"): out["tool_input"]["content"]   = os.environ["_CONTENT"]
print(json.dumps(out))
')
    printf '%s\n' "$INPUT_JSON" | "$HOOK_PATH"
    exit $?
fi

if [[ -x "$TRANSLATOR" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$TRANSLATOR" | "$HOOK_PATH"
    exit $?
fi

exec "$HOOK_PATH"
