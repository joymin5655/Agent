#!/usr/bin/env bash
# commit-message-strip-test.sh — AG22 r1: the commit-message stripper (W-7) must never hide a live command.
#
# pre-tool-guard.sh drops the text of a commit message before the destructive guards (1-4 and the
# ones after) so that a message which only MENTIONS a destructive command is not blocked. The old
# stripper matched " -m " / " --message=" anywhere in a command, whatever command it belonged to, and its
# double-quote pattern ran across shell quote boundaries up to the next quote character, so a quoted
# " -m " in `echo`/`printf` swallowed real commands that followed (they were then never scanned).
# The stripper now works on shell words: only the value word of a message option of
# git commit/tag/merge/notes/stash is replaced, and only when it is ONE whole quoted string; whatever it
# cannot read with certainty stays in the scanned text.
#
# This battery pins (1) bypass shapes that must still be denied/asked, (2) normal commits whose message
# mentions a destructive command that must still be allowed, (3) a seeded fuzz: a live destructive
# command placed outside every quote must never be hidden, whatever decoys surround it, and (4) the
# fallback of hook_flatten_lines must give the same text as the bash substitution it replaces.
#
# Destructive strings are assembled from parts here on purpose: a command guard in front of the
# author's shell blocks the literals.
#
# Usage: bash core/tests/commit-message-strip-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
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
export AGENT_GATE_SINK_DIR="$WORK/gate-sink"
export AGENT_PROJECT_DIR="$WORK/proj"
mkdir -p "$AGENT_PROJECT_DIR"

RMRF="r""m -rf"
RESET="git re""set --hard"
PUSHF="git push --for""ce origin main"
DROPT="DROP TA""BLE users"

verdict() {
  case "$1" in
    *'"permissionDecision": "deny"'*) echo deny ;;
    *'"permissionDecision": "ask"'*)  echo ask ;;
    "") echo allow ;;
    *) echo other ;;
  esac
}

# run_case <name> <command-with-@S@-for-a-lone-surrogate> <expect>
run_case() {
  local name="$1" cmd="$2" expect="$3" ev out got
  ev=$(python3 - "$cmd" <<'PY'
import json
import sys
sys.stdout.write(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}).replace("@S@", "\\ud800"))
PY
)
  out=$(printf '%s' "$ev" | bash "$GUARD" 2>/dev/null)
  got=$(verdict "$out")
  if [[ "$got" == "$expect" ]]; then ok "$name expected=$expect"; else bad "$name" "expected=$expect got=$got :: ${out:0:160}"; fi
}

# --- (1) bypass shapes: the stripper must not hide what follows a quoted " -m " --------------------------
run_case "bypass/echo-flag-text-rm"        "echo \" -m \" ; $RMRF ~/zz ; echo \"\""                       deny
run_case "bypass/echo-flag-text-force"     "echo \" -m \" ; $PUSHF ; echo \"\""                           deny
run_case "bypass/printf-dq-reset"          "printf '%s' ' -m \"x ' ; $RESET ; echo '\"'"                  deny
run_case "bypass/printf-message-eq-reset"  "printf '%s' ' --message=\"x ' ; $RESET ; echo '\"'"           deny
run_case "bypass/printf-dq-surrogate"      "printf '%s' ' -m \"x @S@' ; $RESET ; echo '\"'"               deny
run_case "bypass/printf-dq-drop"           "printf '%s' ' -m \"x ' ; psql -c \"$DROPT\" ; echo '\"'"      ask
run_case "bypass/non-git-message-option"   "mytool -m \"$RMRF /\""                                         deny
run_case "bypass/non-git-message-eq"       "mytool --message=\"$RESET\""                                   deny
run_case "bypass/git-log-not-a-commit"     "git log -m \"$RMRF /\""                                        deny
run_case "bypass/commit-then-rm"           "git commit -m \"x\" ; $RMRF /"                                 deny
run_case "bypass/commit-then-reset"        "git commit -m \"x\" && $RESET"                                 deny
run_case "bypass/commit-then-force"        "git commit -m 'x' || $PUSHF"                                   deny
run_case "bypass/commit-pipe-rm"           "git commit -m \"x\" | $RMRF /"                                 deny
run_case "bypass/commit-newline-rm"        $'git commit -m "x"\n'"$RMRF /"                                 deny
run_case "bypass/commit-then-drop"         "git commit -m \"x\" ; psql -c \"$DROPT\""                     ask
run_case "bypass/escaped-quote-in-message" "git commit -m \"a\\\" ; $RESET ; echo \\\"b\""                 deny
run_case "bypass/concatenated-word"        "git commit -m \"a\"\"; $RESET ; echo \"\"b\""                 deny
run_case "bypass/unterminated-quote"       "git commit -m \"x ; $RMRF /"                                   deny
run_case "bypass/subst-in-message"         "git commit -m \"\$($RMRF /)\""                                 deny
run_case "bypass/message-value-subst"      "git commit -m \"a \$(date)\" ; $RESET"                         deny
run_case "bypass/message-in-bash-c"        "bash -c 'git commit -m \"x\" ; $RMRF /'"                       deny

# --- (2) normal commits that only MENTION a destructive command stay allowed ------------------------------
run_case "ok/dq-rm"                        "git commit -m \"fix: $RMRF / 문구 설명\""                       allow
run_case "ok/message-eq"                   "git commit --message=\"docs: $RESET mention\""                 allow
run_case "ok/bundled-am-sq"                "git commit -am '$RMRF ~ is blocked'"                           allow
run_case "ok/heredoc"                      $'git commit -m "$(cat <<\'EOF\'\nfix: '"$RESET and $RMRF /"$'\n\nbody\nEOF\n)"' allow
run_case "ok/surrogate-in-message"         "git commit -m \"fix $RESET @S@\""                              allow
run_case "ok/git-C"                        "git -C /tmp/x commit -m \"$RMRF /\""                           allow
run_case "ok/two-messages"                 "git commit -m \"a\" -m \"$RESET\""                             allow
run_case "ok/env-prefix"                   "GIT_AUTHOR_NAME=x git commit -m \"$RESET\""                    allow
run_case "ok/add-and-commit"               "git add . && git commit -m \"$RESET\""                         allow
run_case "ok/tag-message"                  "git tag -a v1 -m \"$RMRF /\""                                  allow
run_case "ok/commit-then-benign"           "git commit -m \"$RESET\" && git log -1"                        allow
run_case "ok/subshell"                     "(cd sub && git commit -m \"$RESET\")"                          allow

# --- (3) seeded fuzz: a live command outside every quote is never hidden ------------------------------------
fuzz_out=$(GUARD="$GUARD" RMRF="$RMRF" RESET="$RESET" PUSHF="$PUSHF" python3 - <<'PY'
import json
import os
import random
import subprocess

guard = os.environ["GUARD"]
live_pool = [os.environ["RMRF"] + " /", os.environ["RESET"], os.environ["PUSHF"]]
decoys = [
    'echo " -m "',
    "printf '%s' ' -m \"x '",
    "echo '--message=\"'",
    ': " -m "',
    "echo ' -am '",
    'echo "--message="',
    'git commit -m "plain message"',
    "git commit -am 'single quoted'",
    'git commit --message="long form"',
    "git tag -a v1 -m 'tag message'",
    'git log -m "x"',
    'mytool -m "decoy"',
    "echo '\"'",
]
seps = [" ; ", " && ", " || ", " | ", "\n", " ; echo done ; "]
rng = random.Random(22)
bad = 0
total = 0
for _ in range(90):
    live = rng.choice(live_pool)
    parts = [rng.choice(decoys) for _ in range(rng.randint(0, 2))]
    parts.insert(rng.randint(0, len(parts)), live)
    parts += [rng.choice(decoys) for _ in range(rng.randint(0, 2))]
    cmd = ""
    for i, part in enumerate(parts):
        cmd += part if i == 0 else rng.choice(seps) + part
    ev = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    out = subprocess.run(["bash", guard], input=ev, capture_output=True, text=True).stdout
    total += 1
    if '"permissionDecision": "deny"' not in out:
        bad += 1
        print("MISS", json.dumps(cmd))
print("TOTAL", total, "MISSED", bad)
PY
)
if [[ "$fuzz_out" == *"MISSED 0" ]]; then
  ok "fuzz/live-command-never-hidden ($(printf '%s' "$fuzz_out" | tail -1))"
else
  bad "fuzz/live-command-never-hidden" "$(printf '%s' "$fuzz_out" | head -5)"
fi

# --- (3b) pathological nesting: no Traceback on stderr, the verdict stays deny ----------------------------
deep=$(python3 -c 'import sys; sys.stdout.write("echo \"$(" * 1500)')
ev=$(python3 - "git commit -m \"x\" ; $RMRF / ; $deep" <<'PY'
import json
import sys
sys.stdout.write(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
PY
)
out=$(printf '%s' "$ev" | bash "$GUARD" 2>"$WORK/deep.err")
if [[ "$(verdict "$out")" == deny && ! -s "$WORK/deep.err" ]]; then
  ok "deep-nesting/deny-without-stderr"
else
  bad "deep-nesting/deny-without-stderr" "verdict=$(verdict "$out") stderr=$(head -c 120 "$WORK/deep.err")"
fi

# --- (4) hook_flatten_lines fallback is equivalent to the substitution (python3 failing) ------------------
# shellcheck source=../hooks/event_decode.sh
source "$HOOKS/event_decode.sh"
old_flat() { local f=${1//\\$'\n'/}; printf '%s' "${f//$'\n'/ }"; }
python3() { return 1; }   # the shell function shadows the interpreter: python is "broken"
for c in $'py\\\nthon3 -c "print(open(\'private.key\').read())"' $'a\\\nb' $'a\\\\\nb' $'x\r\ny' $'한글\n줄\\\n끝' $'one line'; do
  o=$(old_flat "$c"; printf x); n=$(hook_flatten_lines "$c"; printf x)
  label=$(printf '%q' "$c")
  [[ "$o" == "$n" ]] && ok "flatten-fallback/$label" || bad "flatten-fallback/$label" "old=$(printf '%q' "${o%x}") new=$(printf '%q' "${n%x}")"
done
unset -f python3

echo
echo "commit-message-strip-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
