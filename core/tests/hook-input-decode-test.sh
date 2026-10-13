#!/usr/bin/env bash
# hook-input-decode-test.sh — AG21: a hook must not turn an undecodable event into an allow.
#
# Claude Code serializes the event with JSON, so a lone surrogate in a command (a split emoji, a
# binary blob echoed back) travels as a `\ud800` escape. Python's json.load accepts it, but printing
# the resulting str raises UnicodeEncodeError; the old `2>/dev/null || echo ""` then blanked the
# command and every Bash guard saw nothing (jq 1.7 rejects the whole event, so the jq-based hooks
# exited 5 — also no decision). This battery pins, per guard:
#   (1) a representative deny/ask command keeps its verdict with a lone surrogate placed before,
#       after or inside it (high alone, low alone, reversed pair), and a valid pair still passes;
#   (2) a benign command carrying a surrogate is still allowed (no false positive);
#   (3) an event the hook cannot decode (truncated JSON, non-object, non-object tool_input) is
#       denied/asked with a WHY:/FIX: reason — never an empty-stdout allow;
#   (4) events that legitimately carry no command (other tools, empty tool_input, empty stdin)
#       keep passing silently.
#
# Events are RAW JSON BYTES with a literal `\ud800` escape (the token @S@ below is swapped in after
# json.dumps so the escape reaches the hook exactly as Claude Code sends it, and each event is
# asserted to contain it).
#
# Usage: bash core/tests/hook-input-decode-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
# shellcheck disable=SC2016  # fixtures are literal command lines; their $ must not expand here
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$REPO_ROOT/core/hooks"
GUARD="$HOOKS/pre-tool-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT
export AGENT_GATE_SINK_DIR="${AGENT_GATE_SINK_DIR:-$WORK/gate-sink}"

# A throwaway project whose config declares vault/** (guard 11b). Not a git repo: the guard resolves
# the project through AGENT_PROJECT_DIR.
PROOT="$WORK/proj"
mkdir -p "$PROOT/.agent"
cat > "$PROOT/.agent/hook-config.yml" <<'YML'
risk_areas:
  secrets:
    paths:
      - 'vault/**'
    decision: deny
YML
export AGENT_PROJECT_DIR="$PROOT"

# event <tool> <command-with-@S@-tokens> [field] -> raw JSON bytes; @S@ becomes the literal escape
# given in $SUR (default \ud800). field defaults to "command".
SUR='\ud800'
event() {
  python3 - "$1" "$2" "${3:-command}" "$SUR" <<'PY'
import json
import sys
tool, text, field, sur = sys.argv[1:5]
raw = json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {field: text}})
sys.stdout.write(raw.replace("@S@", sur))
PY
}

verdict() {  # verdict <hook-output> -> deny|ask|allow|other
  case "$1" in
    *'"permissionDecision": "deny"'*|*'"permissionDecision":"deny"'*) echo deny ;;
    *'"permissionDecision": "ask"'*|*'"permissionDecision":"ask"'*) echo ask ;;
    "") echo allow ;;
    *) echo other ;;
  esac
}

# check <name> <hook-path> <expect> <stdin-bytes> [noteach]
# noteach: the verdict's own wording predates T-1 (context-mode-guard's secrets deny) and is not
# this battery's subject; the decode-failure reasons always get the WHY:/FIX: check.
check() {
  local name="$1" hook="$2" expect="$3" input="$4" teach="${5:-teach}" out rc got
  out=$(printf '%s' "$input" | bash "$hook" 2>/dev/null); rc=$?
  got=$(verdict "$out")
  if [[ $rc -ne 0 ]]; then
    bad "$name" "exit $rc (a hook must exit 0 and decide in stdout)"
  elif [[ "$got" != "$expect" ]]; then
    bad "$name" "expected=$expect got=$got :: $out"
  elif [[ "$expect" != allow && "$teach" == teach && ! ( "$out" == *"WHY:"* && "$out" == *"FIX:"* ) ]]; then
    bad "$name" "reason lacks WHY:/FIX: :: $out"
  else
    ok "$name expected=$expect"
  fi
}

# --- (1)+(2) pre-tool-guard.sh: verdict survives a lone surrogate anywhere in the command ----------
declare -a BASES=(
  'secrets-builtin|cat secrets/prod.env|deny'
  'secrets-11b|cat vault/k|deny'
  'rm-rf-root|rm -rf /|deny'
  'force-push-main|git push origin --force main|deny'
  'reset-hard|git reset --hard HEAD~1|deny'
  'drop-table|psql -c "DROP TABLE users"|ask'
  'benign|ls -la && echo hello|allow'
)
for spec in "${BASES[@]}"; do
  IFS='|' read -r name cmd expect <<<"$spec"
  for variant in none before after inside; do
    case "$variant" in
      none)   text="$cmd" ;;
      before) text="echo '@S@' && $cmd" ;;
      after)  text="$cmd; printf '@S@'" ;;
      inside) text="$cmd @S@ && ls" ;;
    esac
    ev=$(event Bash "$text")
    if [[ "$variant" != none && "$ev" != *'\ud800'* ]]; then
      bad "guard/$name/$variant" "fixture lost the literal \\ud800 escape"
      continue
    fi
    check "guard/$name/$variant" "$GUARD" "$expect" "$ev"
  done
done

for sur in '\udfff' '\udc00\ud800' '😀'; do   # lone low, reversed pair, VALID pair
  SUR="$sur"
  check "guard/secrets-11b/surrogate=$sur" "$GUARD" deny "$(event Bash "echo '@S@' && cat vault/k")"
done
SUR='\ud800'

# --- (3) an undecodable event never becomes an allow -------------------------------------------------
check "guard/truncated-json"        "$GUARD" deny '{"tool_name":"Bash","tool_input":{"command":"cat vault/k"'
check "guard/not-an-object"         "$GUARD" deny '[]'
check "guard/tool-input-not-object" "$GUARD" deny '{"tool_name":"Bash","tool_input":"cat vault/k"}'
check "guard/not-json-text"         "$GUARD" deny 'cat vault/k'
check "guard/invalid-utf8-bytes"    "$GUARD" deny "$(printf '{"tool_name":"Bash","tool_input":{"command":"cat vault/k \xff"}}')"

# --- (4) events that carry no command keep passing ----------------------------------------------------
check "guard/other-tool"          "$GUARD" allow '{"tool_name":"Read","tool_input":{"file_path":"a.txt"}}'
check "guard/bash-without-command" "$GUARD" allow '{"tool_name":"Bash","tool_input":{}}'
check "guard/no-tool-input"       "$GUARD" allow '{"tool_name":"Bash"}'
check "guard/null-tool-input"     "$GUARD" allow '{"tool_name":"Bash","tool_input":null}'
check "guard/empty-stdin"         "$GUARD" allow ''

# --- same extraction pattern in the jq-based hooks (jq 1.7 refuses the whole event) -------------------
if command -v jq >/dev/null 2>&1; then
  CTX="$HOOKS/context-mode-guard.sh"
  R4="$HOOKS/r4-mutex-check.sh"
  R4F="$HOOKS/r4-file-mutex-check.sh"
  ctx_ev() { python3 - "$1" <<'PY'
import json
import sys
raw = json.dumps({"tool_name": "mcp__plugin_context-mode_context-mode__ctx_execute",
                  "tool_input": {"code": sys.argv[1]}})
sys.stdout.write(raw.replace("@S@", "\\ud800"))
PY
  }
  check "ctx-guard/secrets"                 "$CTX" deny  "$(ctx_ev 'cat secrets/k')" noteach
  check "ctx-guard/secrets+surrogate-before" "$CTX" deny  "$(ctx_ev "echo '@S@'; cat secrets/k")" noteach
  check "ctx-guard/secrets+surrogate-after"  "$CTX" deny  "$(ctx_ev "cat secrets/k; echo '@S@'")" noteach
  check "ctx-guard/benign+surrogate"        "$CTX" allow "$(ctx_ev "echo '@S@'")"
  check "ctx-guard/truncated-json"          "$CTX" deny  '{"tool_name":"mcp__x__ctx_execute","tool_input":{"code":"cat secrets/k"'
  check "ctx-guard/other-tool"              "$CTX" allow '{"tool_name":"Read","tool_input":{"file_path":"a"}}'

  check "r4-mutex/benign+surrogate"         "$R4"  allow "$(event Bash "echo '@S@'")"
  check "r4-mutex/truncated-json"           "$R4"  ask   '{"tool_name":"Bash","tool_input":{"command":"ls"'
  check "r4-mutex/empty-stdin"              "$R4"  allow ''

  check "r4-file/benign+surrogate"          "$R4F" allow "$(event Write 'src/a@S@b.py' file_path)"
  check "r4-file/other-tool+surrogate"      "$R4F" allow "$(event Bash "echo '@S@'")"
  check "r4-file/truncated-json"            "$R4F" ask   '{"tool_name":"Write","tool_input":{"file_path":"src/a.py"'
  check "r4-file/empty-stdin"               "$R4F" allow ''
else
  echo "  skip jq-based hooks (jq not installed)"
fi

echo
echo "hook-input-decode-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
