#!/usr/bin/env bash
# Codex CLI adapter — translates Codex tool-call envelopes into the canonical
# hook event protocol, invokes a core hook, and returns the decision JSON.
#
# Two input modes, one entry point:
#
# Native hooks (Codex >= 0.157 — installed by `setup.sh --codex` into
# ~/.codex/hooks.json from hooks.json.template, or shipped by the portable plugin
# as hooks/codex-hooks.json): stdin is Codex's hook event (`hook_event_name`,
# `tool_name`, `tool_input`, ...). adapter.py --run translates it (apply_patch is
# split per file into canonical Write/Edit events), runs the core hook, and —
# because Codex CONTINUES the tool call on any hook failure or unsupported `ask`
# — turns every PreToolUse failure and canonical `ask` into an explicit deny
# (docs/ai-adapters.md § Codex decision mapping).
#
# Legacy envelopes / synthetic flags: the pre-native shell-wrapper path
# (legacy/codex-shell-wrap/) and adapter-parity.sh feed canonical JSON, the old
# shell_call/file_write envelopes, or --tool/--command flags. These return the
# core hook's canonical decision unchanged (including `ask`).
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
    [[ -x "$HOOK_PATH" ]] || exit 0
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

# Stdin mode — translate if needed, run the core hook, relay/normalize its result
# (adapter.py also owns the missing-hook decision: deny for a native PreToolUse).
if [[ -x "$TRANSLATOR" ]] && command -v python3 >/dev/null 2>&1; then
    exec python3 "$TRANSLATOR" --run "$HOOK_PATH"
fi

# No python3: the native path cannot be translated or normalized. Codex would run
# the tool if we exited non-zero or passed an `ask` through, so a native
# PreToolUse gets a static deny; anything else keeps the old pass-through.
INPUT="$(cat)"
if [[ "$INPUT" == *'"hook_event_name"'* && "$INPUT" == *'"PreToolUse"'* ]]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[agent/codex] python3 not found; Agent guards cannot run, blocked fail-closed."}}'
    exit 0
fi
[[ -x "$HOOK_PATH" ]] || exit 0
printf '%s' "$INPUT" | "$HOOK_PATH"
