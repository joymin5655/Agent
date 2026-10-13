#!/usr/bin/env bash
# hook-input-decode-residual-test.sh — AG22: what AG21's decode fix left open.
#
#   F1  a JSON object whose tool_input is a string/array made the jq hooks end in `set -e` (exit 5,
#       no decision = pass). They now fail closed (context-mode-guard deny, r4 hooks ask).
#   F2  without python3 the guard's decode fails, but emit_deny also needed python3, so the deny never
#       reached stdout (empty stdout + exit 0 = allow). emit_deny/emit_ask now fall back to printf.
#   F3  a lone surrogate inside a double-quoted commit message left a `\udXXX` backslash behind and the
#       message stripper (which skips quotes holding a backslash) no longer removed the message, so
#       "git reset --hard" quoted in a message was scanned as a command.
#   F4  no jq: the three jq hooks still pass (exit 0). Pinned here so a change is a decision.
#
# Usage: bash core/tests/hook-input-decode-residual-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$REPO_ROOT/core/hooks"
GUARD="$HOOKS/pre-tool-guard.sh"
CTX="$HOOKS/context-mode-guard.sh"
R4="$HOOKS/r4-mutex-check.sh"
R4F="$HOOKS/r4-file-mutex-check.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT
export AGENT_GATE_SINK_DIR="$WORK/gate-sink"
export AGENT_PROJECT_DIR="$WORK/proj"
mkdir -p "$AGENT_PROJECT_DIR"

verdict() {
  case "$1" in
    *'"permissionDecision": "deny"'*|*'"permissionDecision":"deny"'*) echo deny ;;
    *'"permissionDecision": "ask"'*|*'"permissionDecision":"ask"'*) echo ask ;;
    "") echo allow ;;
    *) echo other ;;
  esac
}

# valid_json <text>: the decision must parse as JSON (checked with python3 from the real PATH).
valid_json() { printf '%s' "$1" | /usr/bin/env python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }

# check <name> <hook> <expect> <stdin> [PATH-override] — T-1 (WHY:/FIX:) and JSON validity for non-allow
check() {
  local name="$1" hook="$2" expect="$3" input="$4" path="${5:-$PATH}" out rc got
  out=$(printf '%s' "$input" | PATH="$path" bash "$hook" 2>/dev/null); rc=$?
  got=$(verdict "$out")
  if [[ $rc -ne 0 ]]; then
    bad "$name" "exit $rc (a hook must exit 0 and decide in stdout)"
  elif [[ "$got" != "$expect" ]]; then
    bad "$name" "expected=$expect got=$got :: $out"
  elif [[ "$expect" != allow ]] && ! valid_json "$out"; then
    bad "$name" "decision is not valid JSON :: $out"
  elif [[ "$expect" != allow && ! ( "$out" == *"WHY:"* && "$out" == *"FIX:"* ) ]]; then
    bad "$name" "reason lacks WHY:/FIX: :: $out"
  else
    ok "$name expected=$expect"
  fi
}

# A PATH without python3 / without jq: symlink every other tool the hooks need into a private dir.
shadow_path() {  # shadow_path <dir> <excluded-command>...
  local dir="$1" ex p name skip d
  shift
  mkdir -p "$dir"
  for d in /usr/bin /bin /usr/local/bin; do
    [[ -d "$d" ]] || continue
    for p in "$d"/*; do
      name="${p##*/}"; skip=0
      for ex in "$@"; do [[ "$name" == "$ex"* && ( "$name" == "$ex" || "$ex" == python3 && "$name" == python3.* ) ]] && skip=1; done
      [[ $skip -eq 0 && ! -e "$dir/$name" ]] && ln -s "$p" "$dir/$name" 2>/dev/null
    done
  done
}

# --- F1: non-object tool_input ------------------------------------------------------------------------
CTXN='mcp__context-mode__ctx_execute'
if command -v jq >/dev/null 2>&1; then
  check "F1/ctx-guard/tool_input-string" "$CTX" deny "{\"tool_name\":\"$CTXN\",\"tool_input\":\"cat secrets/x\"}"
  check "F1/ctx-guard/tool_input-array"  "$CTX" deny "{\"tool_name\":\"$CTXN\",\"tool_input\":[\"cat secrets/x\"]}"
  check "F1/r4-mutex/tool_input-string"  "$R4"  ask  '{"tool_name":"Bash","tool_input":"git commit"}'
  check "F1/r4-file/tool_input-string"   "$R4F" ask  '{"tool_name":"Write","tool_input":"x"}'
  check "F1/r4-file/tool_input-number"   "$R4F" ask  '{"tool_name":"Write","tool_input":7}'
  check "F1/r4-file/tool_input-false"    "$R4F" ask  '{"tool_name":"Write","tool_input":false}'
  # unchanged: absent / null / empty-object tool_input is "no command", not a failure
  check "F1/ctx-guard/no-tool_input"     "$CTX" allow "{\"tool_name\":\"$CTXN\"}"
  check "F1/ctx-guard/null-tool_input"   "$CTX" allow "{\"tool_name\":\"$CTXN\",\"tool_input\":null}"
  check "F1/r4-mutex/empty-object"       "$R4"  allow '{"tool_name":"Bash","tool_input":{}}'
  check "F1/r4-file/null-tool_input"     "$R4F" allow '{"tool_name":"Write","tool_input":null}'
fi

# --- F3: surrogate inside a quoted commit message ------------------------------------------------------
sur_event() {  # sur_event <command-with-@S@> -> raw JSON with a literal \ud800 escape
  python3 - "$1" <<'PY'
import json
import sys
sys.stdout.write(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}).replace("@S@", "\\ud800"))
PY
}
check "F3/commit-msg-mentions-reset+surrogate" "$GUARD" allow "$(sur_event 'git commit -m "fix git reset --hard @S@"')"
check "F3/commit-msg-surrogate-mid"            "$GUARD" allow "$(sur_event 'git commit -m "a @S@ rm -rf / b"')"
check "F3/commit-msg+live-reset-after"         "$GUARD" deny  "$(sur_event 'git commit -m "x @S@" && git reset --hard')"
check "F3/escaped-quote-not-a-message"         "$GUARD" deny  "$(sur_event 'echo -m "a\" ; git reset --hard ; \"@S@"')"
check "F3/other-backslash-keeps-scan"         "$GUARD" deny  "$(sur_event 'git commit -m "fix \\n git reset --hard @S@"')"
check "F3/subst-in-message-stays-scanned"      "$GUARD" deny  "$(sur_event 'git commit -m "@S@ $(git reset --hard)"')"

# --- F2: no python3 --------------------------------------------------------------------------------------
NOPY="$WORK/nopy"; shadow_path "$NOPY" python3
check "F2/no-python/rm-rf-root"      "$GUARD" deny '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' "$NOPY"
check "F2/no-python/secrets"         "$GUARD" deny '{"tool_name":"Bash","tool_input":{"command":"cat secrets/prod.env"}}' "$NOPY"
check "F2/no-python/force-push-main" "$GUARD" deny '{"tool_name":"Bash","tool_input":{"command":"git push origin --force main"}}' "$NOPY"
check "F2/no-python/benign"          "$GUARD" deny '{"tool_name":"Bash","tool_input":{"command":"ls"}}' "$NOPY"
if command -v jq >/dev/null 2>&1; then
  # the decode of a lone surrogate needs python3; without it the jq hooks must still decide
  check "F2/no-python/ctx-guard+surrogate" "$CTX" deny "{\"tool_name\":\"$CTXN\",\"tool_input\":{\"code\":\"x \\ud800\"}}" "$NOPY"
  check "F2/no-python/r4-mutex+surrogate"  "$R4"  ask  '{"tool_name":"Bash","tool_input":{"command":"x \ud800"}}' "$NOPY"
  check "F2/no-python/ctx-guard/benign"    "$CTX" allow "{\"tool_name\":\"$CTXN\",\"tool_input\":{\"code\":\"echo hi\"}}" "$NOPY"
fi

# the printf fallback must escape what json.dumps would: quote, backslash, newline, tab, other control chars
esc_case() {  # esc_case <name> <reason>
  local out
  out=$(PATH="$NOPY" bash -c 'source "$1"; hook_emit_decision deny "$2"' _ "$HOOKS/event_decode.sh" "$2" 2>/dev/null)
  if valid_json "$out" && [[ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"] == sys.argv[1])' "$3")" == True ]]; then
    ok "F2/fallback-escape/$1"
  else
    bad "F2/fallback-escape/$1" "not valid JSON or reason changed :: $out"
  fi
}
esc_case quotes   'say "hi" now'                 'say "hi" now'
esc_case backslash 'a\b \n c:\d'              'a\b \n c:\d'
esc_case newline  $'line1\nline2\ttab'          $'line1\nline2\ttab'
esc_case ctrl     $'a\001b\033c'                'a b c'
esc_case unicode  '한글 — ok'                     '?????? ??? ok'

# invalid UTF-8 bytes in the reason must not make the fallback JSON invalid: it is ASCII-only
bad_utf8_out=$(PATH="$NOPY" bash -c 'source "$1"; hook_emit_decision deny "bad $(printf "\377\303") byte and 한글"' _ "$HOOKS/event_decode.sh" 2>/dev/null)
if valid_json "$bad_utf8_out" && ! printf '%s' "$bad_utf8_out" | LC_ALL=C grep -q '[^ -~]'; then
  ok "F2/fallback-escape/invalid-utf8-is-ascii-json"
else
  bad "F2/fallback-escape/invalid-utf8-is-ascii-json" "not valid ASCII JSON :: $bad_utf8_out"
fi

# a non-object tool_input together with a surrogate takes the python path: it must still fail closed
if command -v jq >/dev/null 2>&1; then
  check "F1/ctx-guard/tool_input-string+surrogate" "$CTX" deny "{\"tool_name\":\"$CTXN\",\"tool_input\":\"x \\ud800\"}"
  check "F1/r4-file/tool_input-array+surrogate"    "$R4F" ask  '{"tool_name":"Write","tool_input":["\ud800"]}'
fi

# --- F4: no jq — current behaviour recorded (pass; see PR decision table) --------------------------------
NOJQ="$WORK/nojq"; shadow_path "$NOJQ" jq
check "F4/no-jq/ctx-guard" "$CTX" allow "{\"tool_name\":\"$CTXN\",\"tool_input\":{\"code\":\"cat secrets/x\"}}" "$NOJQ"
check "F4/no-jq/r4-mutex"  "$R4"  allow '{"tool_name":"Bash","tool_input":{"command":"git commit"}}' "$NOJQ"
check "F4/no-jq/r4-file"   "$R4F" allow '{"tool_name":"Write","tool_input":{"file_path":"a.py"}}' "$NOJQ"

# --- RV13 F1: the guard must find event_decode.sh however it is started -------------------------------------
RM_EV='{"tool_name":"Bash","tool_input":{"command":"r''m -rf /"}}'
OK_EV='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
(cd "$HOOKS" && printf '%s' "$RM_EV" | bash pre-tool-guard.sh 2>/dev/null) > "$WORK/rel.out"; rc=$?
[[ $rc -eq 0 && "$(verdict "$(cat "$WORK/rel.out")")" == deny ]] && ok "F1/guard/bare-relative-path deny" || bad "F1/guard/bare-relative-path" "rc=$rc :: $(cat "$WORK/rel.out")"
(cd "$HOOKS" && printf '%s' "$OK_EV" | bash pre-tool-guard.sh 2>/dev/null) > "$WORK/rel.out"
[[ ! -s "$WORK/rel.out" ]] && ok "F1/guard/bare-relative-path benign allow" || bad "F1/guard/bare-relative-path benign" "$(cat "$WORK/rel.out")"
(cd "$HOOKS" && printf '%s' "$RM_EV" | bash ./pre-tool-guard.sh 2>/dev/null) > "$WORK/rel.out"
[[ "$(verdict "$(cat "$WORK/rel.out")")" == deny ]] && ok "F1/guard/dot-slash deny" || bad "F1/guard/dot-slash" "$(cat "$WORK/rel.out")"
mkdir -p "$WORK/link"; ln -s "$GUARD" "$WORK/link/guard-link.sh"
out=$(printf '%s' "$RM_EV" | bash "$WORK/link/guard-link.sh" 2>/dev/null)
[[ "$(verdict "$out")" == deny ]] && ok "F1/guard/symlink deny" || bad "F1/guard/symlink" "$out"
out=$(printf '%s' "$OK_EV" | bash "$WORK/link/guard-link.sh" 2>/dev/null)
[[ -z "$out" ]] && ok "F1/guard/symlink benign allow (resolved to the real directory)" || bad "F1/guard/symlink benign" "$out"
mkdir -p "$WORK/alone"; cp "$GUARD" "$WORK/alone/pre-tool-guard.sh"
for ev in "$RM_EV" "$OK_EV"; do
  out=$(printf '%s' "$ev" | bash "$WORK/alone/pre-tool-guard.sh" 2>/dev/null); rc=$?
  if [[ $rc -eq 0 && "$(verdict "$out")" == deny ]] && valid_json "$out"; then ok "F1/guard/event_decode-missing fail-closed"; else bad "F1/guard/event_decode-missing" "rc=$rc :: $out"; fi
done

echo
echo "hook-input-decode-residual-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
