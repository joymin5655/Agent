#!/usr/bin/env bash
# Sourced by the jq-based hooks (context-mode-guard.sh, r4-mutex-check.sh, r4-file-mutex-check.sh).
#
# jq 1.7 rejects the WHOLE event when a string holds a lone surrogate escape (`\ud800`, legal JSON
# that Claude Code emits for a split emoji or echoed binary), so `set -e` ended those hooks with
# exit 5 and no decision. decode_event_input keeps $INPUT as is when jq accepts it (the normal case:
# one extra jq start, no python), and otherwise rewrites it with each lone surrogate spelled as
# visible `\udXXX` text. If even that fails (not JSON, not an object) the hook does not pass the
# call: it prints a T-1 decision and exits 0.
#
# Usage: decode_event_input <hook-name> <ask|deny>      (INPUT must already hold the event)

decode_event_input() {
  local hook="$1" decision="$2" fixed
  [[ -z "${INPUT//[[:space:]]/}" ]] && return 0
  printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 && return 0
  if fixed=$(printf '%s' "$INPUT" | python3 -I -c '
import json, sys

def spell(node):
    if isinstance(node, str):
        return node.encode("utf-8", "backslashreplace").decode("utf-8")
    if isinstance(node, list):
        return [spell(v) for v in node]
    if isinstance(node, dict):
        return {spell(k): spell(v) for k, v in node.items()}
    return node

event = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
if not isinstance(event, dict):
    sys.exit(3)
sys.stdout.write(json.dumps(spell(event)))
' 2>/dev/null); then
    INPUT="$fixed"
    return 0
  fi
  python3 -I - "$hook" "$decision" <<'PY'
import json
import sys
hook, decision = sys.argv[1:3]
reason = (
    f"Hook input could not be decoded in {hook} (blocked fail-closed).\n"
    "WHY: an undecodable event reads as an empty tool call, and an empty call passes every check; "
    "passing it would let any text the decoder chokes on carry a blocked action through.\n"
    "FIX: send the tool call again as plain JSON text; if the event itself is malformed, report it - "
    "do not reshape the call to dodge this check."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
  exit 0
}
