#!/usr/bin/env bash
# council-lanes-test.sh — run the external-lane dispatch block of
# skills/council-review/SKILL.md (the lines between `# council-lanes:begin` and
# `# council-lanes:end`) against a stand-in call-worker.sh and check, per case, how
# often each lane is called, with or without AGENT_WORKER_YES=1, and that no two calls
# write the same capture file.
#
# call-worker-test.sh covers the dispatcher itself; this covers the skill's own calls, so a
# block that drops the Gemini lane or calls codex twice fails here. Two mutated copies of the
# block (Gemini calls removed, a second codex call added) must fail the same checks.
# No paid call is made: CLAUDE_PLUGIN_ROOT points at a fake root whose call-worker.sh and
# review-evidence.py are stubs.
#
# Usage: bash core/tests/council-lanes-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/council-review/SKILL.md"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT
ok()  { PASS=$((PASS + 1)); echo "  ok   [$1]"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL [$1] ${2:-}"; }

# --- the block -----------------------------------------------------------------------------
BLOCK="$WORK/block.sh"
n_begin="$(grep -c '^# council-lanes:begin$' "$SKILL" || true)"
n_end="$(grep -c '^# council-lanes:end$' "$SKILL" || true)"
if [[ "$n_begin" != 1 || "$n_end" != 1 ]]; then
    bad "markers" "want one begin and one end marker in $SKILL, got begin=$n_begin end=$n_end"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi
sed -n '/^# council-lanes:begin$/,/^# council-lanes:end$/p' "$SKILL" > "$BLOCK"
ok "markers — one begin and one end marker; block extracted ($(wc -l < "$BLOCK" | tr -d ' ') lines)"

# --- fake plugin root ------------------------------------------------------------------------
FAKE="$WORK/root"
mkdir -p "$FAKE/core/infra"
# Stand-in dispatcher: logs "<role> yes=<0|1> av=<AGENT_AUTHOR_VENDOR>", prints a token unique
# to this call (its pid) as the capture path, and exits like call-worker would: with no policy
# and no YES 3; with YES 0; otherwise FAKE_RC_CODEX / FAKE_RC_GEMINI.
cat > "$FAKE/core/infra/call-worker.sh" <<'EOF'
#!/usr/bin/env bash
role="${1:-}"
cat >/dev/null
yes=0; [[ "${AGENT_WORKER_YES:-}" == 1 ]] && yes=1
printf '%s yes=%s av=%s\n' "$role" "$yes" "${AGENT_AUTHOR_VENDOR:-}" >> "$FAKE_LOG"
echo "token:$role:$$"
[[ "$yes" == 1 ]] && exit 0
[[ -n "${AGENT_WORKER_POLICY_CMD:-}" ]] || exit 3
case "$role" in
    second-opinion-review) exit "${FAKE_RC_CODEX:-0}" ;;
    third-opinion-review)  exit "${FAKE_RC_GEMINI:-0}" ;;
esac
exit 0
EOF
chmod +x "$FAKE/core/infra/call-worker.sh"
cat > "$FAKE/core/infra/review-evidence.py" <<'EOF'
import os
import sys

if sys.argv[1:] == ["author-vendor"]:
    rc = int(os.environ.get("FAKE_AV_RC", "0"))
    if rc:
        sys.stderr.write("fake: author-vendor failed\n")
        sys.exit(rc)
    print("anthropic")
    sys.exit(0)
if sys.argv[1:2] == ["key"]:
    print("")
    sys.exit(0)
sys.exit(2)
EOF

# run_block <block-file> [VAR=value...] — one run in a fresh case dir ($CASE)
CASE="$WORK/case"
run_block() {
    local block="$1"; shift
    rm -rf "$CASE"; mkdir -p "$CASE/cap"
    : > "$CASE/calls.log"
    echo "codex prompt" > "$CASE/p-codex"; echo "gemini prompt" > "$CASE/p-gemini"
    cp "$block" "$CASE/run.sh"
    printf '\nprintf "%%s %%s\\n" "$rc_codex" "$rc_gemini" > "%s/rc"\n' "$CASE" >> "$CASE/run.sh"
    ( cd "$CASE" && env -u AGENT_WORKER_POLICY_CMD -u AGENT_WORKER_YES -u AGENT_AUTHOR_VENDOR \
        -u APPROVED_CODEX -u APPROVED_GEMINI -u FAKE_RC_CODEX -u FAKE_RC_GEMINI -u FAKE_AV_RC \
        CLAUDE_PLUGIN_ROOT="$FAKE" CAP_DIR="$CASE/cap" FAKE_LOG="$CASE/calls.log" \
        PROMPT_CODEX="$CASE/p-codex" PROMPT_GEMINI="$CASE/p-gemini" DIFF_SEL=--head \
        "$@" bash "$CASE/run.sh" ) >"$CASE/out" 2>"$CASE/err"
}
calls() { grep -c "^$1 " "$CASE/calls.log" || true; }
yesflags() { grep "^$1 " "$CASE/calls.log" | sed -E 's/^[^ ]+ yes=([01]).*/\1/' | tr '\n' ' ' | sed 's/ $//'; }

# verdict <codex-calls> <codex-yes> <gemini-calls> <gemini-yes> <rc-line> — empty when the
# last run matches, else what differs. Also: every call's token is in its own capture file,
# and every call carried the author list.
verdict() {
    local want_cc="$1" want_cy="$2" want_gc="$3" want_gy="$4" want_rc="$5" msg="" n tokens uniq
    [[ "$(calls second-opinion-review)" == "$want_cc" ]] || msg+=" codex-calls=$(calls second-opinion-review)/want $want_cc"
    [[ "$(yesflags second-opinion-review)" == "$want_cy" ]] || msg+=" codex-yes=[$(yesflags second-opinion-review)]/want [$want_cy]"
    [[ "$(calls third-opinion-review)" == "$want_gc" ]] || msg+=" gemini-calls=$(calls third-opinion-review)/want $want_gc"
    [[ "$(yesflags third-opinion-review)" == "$want_gy" ]] || msg+=" gemini-yes=[$(yesflags third-opinion-review)]/want [$want_gy]"
    [[ "$(cat "$CASE/rc" 2>/dev/null)" == "$want_rc" ]] || msg+=" rc=[$(cat "$CASE/rc" 2>/dev/null)]/want [$want_rc]"
    n="$(wc -l < "$CASE/calls.log" | tr -d ' ')"
    tokens="$(cat "$CASE"/cap/*.path 2>/dev/null | grep -c '^token:' || true)"
    uniq="$(cat "$CASE"/cap/*.path 2>/dev/null | grep '^token:' | sort -u | wc -l | tr -d ' ')"
    [[ "$tokens" == "$n" && "$uniq" == "$n" ]] \
        || msg+=" captures: $n calls but $tokens tokens ($uniq distinct) in $(ls "$CASE/cap" | tr '\n' ' ')"
    for f in "$CASE"/cap/*.path; do
        [[ -e "$f" ]] || continue
        [[ "$(grep -c '^token:' "$f" || true)" -le 1 ]] || msg+=" $(basename "$f") written by two calls"
    done
    if [[ "$n" -gt 0 ]] && grep -qv ' av=anthropic$' "$CASE/calls.log"; then
        msg+=" a call ran without AGENT_AUTHOR_VENDOR=anthropic"
    fi
    printf '%s' "$msg"
}
expect() {  # expect <name> <verdict-args...>
    local name="$1" msg; shift
    msg="$(verdict "$@")"
    if [[ -z "$msg" ]]; then ok "$name"; else bad "$name" "$msg :: err=$(tr '\n' '|' < "$CASE/err")"; fi
}

POLICY=(AGENT_WORKER_POLICY_CMD="$FAKE/policy")

echo "=== the shipped block ==="
run_block "$BLOCK" "${POLICY[@]}"
expect "policy set, both lanes 0 — each lane once, no YES" 1 0 1 0 "0 0"
run_block "$BLOCK" "${POLICY[@]}" FAKE_RC_CODEX=3 APPROVED_CODEX=1
expect "policy set, codex 3 and approved — codex retried once with YES, gemini once" 2 "0 1" 1 0 "0 0"
run_block "$BLOCK" "${POLICY[@]}" FAKE_RC_CODEX=3
expect "policy set, codex 3 not approved — no retry, codex rc stays 3" 1 0 1 0 "3 0"
run_block "$BLOCK" "${POLICY[@]}" FAKE_RC_GEMINI=127 APPROVED_GEMINI=1
expect "policy set, gemini capped (127) — approval does not retry it" 1 0 1 0 "0 127"
run_block "$BLOCK" APPROVED_CODEX=1 APPROVED_GEMINI=1
expect "no policy, both approved — each lane once, with YES" 1 1 1 1 "0 0"
run_block "$BLOCK" APPROVED_CODEX=1
expect "no policy, only codex approved — gemini never called" 1 1 0 "" "0 skip"
run_block "$BLOCK"
expect "no policy, nothing approved — no external call" 0 "" 0 "" "skip skip"
run_block "$BLOCK" "${POLICY[@]}" APPROVED_CODEX=1 APPROVED_GEMINI=1 FAKE_AV_RC=2
msg="$(verdict 0 "" 0 "" "skip skip")"
if [[ -z "$msg" ]] && grep -q "no external review" "$CASE/err"; then
    ok "author-vendor fails — no external lane is called and the run says why"
else
    bad "author-vendor fails" "$msg :: err=$(tr '\n' '|' < "$CASE/err")"
fi

echo "=== mutated blocks must fail the same checks ==="
# mutant <name> <mutated-block> <verdict-args...> — the mutation must change the block and the
# verdict must find a difference.
mutant() {
    local name="$1" block="$2" msg; shift 2
    if cmp -s "$BLOCK" "$block"; then bad "mutant $name" "the mutation did not change the block"; return; fi
    run_block "$block" "${MUT_ENV[@]}"
    msg="$(verdict "$@")"
    if [[ -n "$msg" ]]; then ok "mutant $name is caught ($msg)"; else bad "mutant $name" "passed the checks"; fi
}
# (1) every Gemini call replaced by a no-op
sed -E 's/lane gemini +third-opinion-review +"\$PROMPT_GEMINI" +[0-9]+( yes)?/:/' "$BLOCK" > "$WORK/m-no-gemini.sh"
MUT_ENV=("${POLICY[@]}")
mutant "no Gemini call (policy set)" "$WORK/m-no-gemini.sh" 1 0 1 0 "0 0"
MUT_ENV=(APPROVED_CODEX=1 APPROVED_GEMINI=1)
mutant "no Gemini call (no policy)" "$WORK/m-no-gemini.sh" 1 1 1 1 "0 0"
# (2) a YES call to codex ahead of the policy call (the shape the first round flagged)
awk '{ if (!done && $0 ~ /lane codex +second-opinion-review +"\$PROMPT_CODEX" +1 &/) {
         print "  lane codex second-opinion-review \"$PROMPT_CODEX\" 1 yes"; done = 1 }
       print }' "$BLOCK" > "$WORK/m-codex-twice.sh"
MUT_ENV=("${POLICY[@]}")
mutant "codex called twice (policy set)" "$WORK/m-codex-twice.sh" 1 0 1 0 "0 0"
# (3) the author-vendor failure ignored again (the old `|| true` shape)
awk '{ if ($0 ~ /^ *NO_EXTERNAL=1$/) print "  NO_EXTERNAL=0"; else print }' "$BLOCK" > "$WORK/m-av-ignored.sh"
MUT_ENV=("${POLICY[@]}" FAKE_AV_RC=2)
mutant "author-vendor failure ignored" "$WORK/m-av-ignored.sh" 0 "" 0 "" "skip skip"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
