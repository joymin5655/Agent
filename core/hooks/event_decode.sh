#!/usr/bin/env bash
# Sourced by the jq-based hooks (context-mode-guard.sh, r4-mutex-check.sh, r4-file-mutex-check.sh).
#
# jq 1.7 rejects the WHOLE event when a string holds a lone surrogate escape (`\ud800`, legal JSON
# that Claude Code emits for a split emoji or echoed binary), so `set -e` ended those hooks with
# exit 5 and no decision. decode_event_input keeps $INPUT as is when jq accepts it (the normal case:
# one extra jq start, no python), and otherwise rewrites it with each lone surrogate spelled as
# visible `\udXXX` text. If even that fails (not JSON, not an object, `tool_input` neither absent/null
# nor an object, python3 missing) the hook does not pass the call: it prints a T-1 decision and exits 0.
# AG22: a `tool_input` that is a string/array made `.tool_input.x` raise in jq (exit 5, no decision).
#
# hook_emit_decision is shared with pre-tool-guard.sh. It prefers python3 (json.dumps) and falls back
# to printf when python3 is absent or broken, so a deny never depends on the interpreter whose absence
# it is reporting (empty stdout + exit 0 would read as allow).
#
# Usage: decode_event_input <hook-name> <ask|deny>      (INPUT must already hold the event)

# _hook_json_escape <text> -> JSON string body on stdout (no surrounding quotes). Pure bash + tr, so
# it works on bash 3.2 without python3; any control character left after \n \r \t becomes a space and
# every non-ASCII byte becomes ?, so invalid UTF-8 in a reason can never make the JSON invalid.
_hook_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s" | LC_ALL=C tr '\001-\010\013\014\016-\037\177' ' ' | LC_ALL=C tr '\200-\377' '?'
}

# hook_emit_decision <deny|ask> <reason> -> the PreToolUse decision JSON (one line) on stdout.
hook_emit_decision() {
  local decision="$1" reason="$2" out=""
  if command -v python3 >/dev/null 2>&1; then
    out=$(python3 -I -c '
import json
import sys
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": sys.argv[1],
        "permissionDecisionReason": sys.argv[2],
    }
}, ensure_ascii=False))
' "$decision" "$reason" 2>/dev/null) || out=""
  fi
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  else
    printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "%s", "permissionDecisionReason": "%s"}}\n' \
      "$decision" "$(_hook_json_escape "$reason")"
  fi
}

# hook_input_is_blank <text>: true when the text holds nothing but whitespace (or is empty).
# AG22: `[[ -z "${INPUT//[[:space:]]/}" ]]` is super-linear on a big multibyte event (a 64 KB Write took
# half a minute; bash 3.2 is slower still). The regex stops at the first non-blank character. Only a
# definite "no match" (status 1) counts as blank. The match runs byte-wise (LC_ALL=C): in a UTF-8 locale
# a regex over invalid bytes reports "no match", which would read a binary-only event as blank and
# pass it. The one difference from the old substitution: text made only of non-ASCII spaces (U+3000)
# is "not blank" now, so it goes on to the decoder and is refused instead of passed.
hook_input_is_blank() {
  local rc=0 LC_ALL=C
  # `if`, `&&` or `||` around the call keeps `set -e` from ending a hook on the non-zero status here
  [[ $1 =~ [^[:space:]] ]]
  rc=$?
  [[ $rc -eq 1 ]]
}

# hook_flatten_lines <text>: the text with backslash-newline joined and every other newline turned
# into a blank, printed without a trailing newline. Same result as ${v//\\$'\n'/} then ${v//$'\n'/ },
# which is super-linear in the line count. Single-line text (the usual command) costs no process.
hook_flatten_lines() {
  local out
  if [[ $1 != *$'\n'* ]]; then
    printf '%s' "$1"
    return 0
  fi
  if out=$(printf '%s' "$1" | python3 -I -c '
import sys
sys.stdout.buffer.write(sys.stdin.buffer.read().replace(b"\\\n", b"").replace(b"\n", b" "))
' 2>/dev/null); then
    printf '%s' "$out"
    return 0
  fi
  # python3 missing or broken: the slow substitution is the exact same transformation
  out=${1//\\$'\n'/}
  printf '%s' "${out//$'\n'/ }"
}

decode_event_input() {
  local hook="$1" decision="$2" fixed
  hook_input_is_blank "$INPUT" && return 0
  printf '%s' "$INPUT" | jq -e 'type == "object" and ((.tool_input | type) as $t | $t == "object" or $t == "null")' \
    >/dev/null 2>&1 && return 0
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
if not isinstance(event, dict) or not isinstance(event.get("tool_input"), (dict, type(None))):
    sys.exit(3)
sys.stdout.write(json.dumps(spell(event)))
' 2>/dev/null); then
    INPUT="$fixed"
    return 0
  fi
  hook_emit_decision "$decision" "Hook input could not be decoded in $hook (blocked fail-closed).
WHY: an undecodable event reads as an empty tool call, and an empty call passes every check; passing it would let any text the decoder chokes on carry a blocked action through.
FIX: send the tool call again as plain JSON text; if the event itself is malformed, report it - do not reshape the call to dodge this check."
  exit 0
}
