#!/usr/bin/env bash
# loop-run-test.sh — battery for core/infra/loop-run.sh (P2-1 + P2-4 + O-2).
#
# Hermetic: builds a throwaway git repo fixture under mktemp, copies in the
# three infra scripts loop-run.sh depends on (supervisor-goal.sh, loop-ledger.sh,
# and its sql/ migration), and drives loop-run.sh's real CLI against it. The
# grader itself is stubbed via LOOP_RUN_GRADE_CMD (a shell command string) so
# this battery tests loop-run.sh's own mechanics — keep/discard, timeout,
# circuit-breaker, cap, resume — without paying for a real grade.sh run.
#
# Requires sqlite3 + jq (supervisor-goal.sh's own hard dependency). Absence
# exits 2 = INAPPLICABLE, which verify-all.sh's discovered-check SKIP lane
# tallies as skipped and prints with its reason. Exiting 0 would be reported as
# PASS with this SKIP line discarded (the runner echoes output on FAIL only) —
# a battery that never ran must never be indistinguishable from one that passed.
#
# Usage: bash core/tests/loop-run-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v sqlite3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: loop-run-test.sh requires sqlite3 + jq (supervisor-goal.sh dependency); not installed"
  exit 2
fi

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/core/infra/sql" "$REPO/core/tests"
cp "$REPO_ROOT/core/infra/loop-run.sh" "$REPO/core/infra/loop-run.sh"
cp "$REPO_ROOT/core/infra/supervisor-goal.sh" "$REPO/core/infra/supervisor-goal.sh"
cp "$REPO_ROOT/core/infra/loop-ledger.sh" "$REPO/core/infra/loop-ledger.sh"
cp "$REPO_ROOT/core/infra/sql/001_supervisor_goals.sql" "$REPO/core/infra/sql/001_supervisor_goals.sql"
chmod +x "$REPO/core/infra/"*.sh

(
  cd "$REPO" || exit 1
  git init -q
  git config user.email "loop-run-test@example.com"
  git config user.name "loop-run-test"
  echo "fixture" > README.md
  git add -A
  git commit -q -m init
)
BASE_REF="$(git -C "$REPO" rev-parse HEAD)"
LR="$REPO/core/infra/loop-run.sh"

run_lr() {  # run_lr <args...> -> sets OUT, RC (cwd = fixture repo)
  OUT="$(cd "$REPO" && bash "$LR" "$@" 2>&1)"; RC=$?
}
ledger_rows() {  # ledger_rows -> data row count (excludes header), 0 if absent
  local f="$REPO/.agent/loop/results.tsv"
  [[ -f "$f" ]] && { echo $(( $(wc -l < "$f" | tr -d ' ') - 1 )); } || echo 0
}

echo "=== (a) init: state file + active flag + goal row ==="
run_lr init improve-test --target 'agents/.*' --base "$BASE_REF" --cap 3 --timeout-s 5
check "init-exit-0" $([[ $RC -eq 0 ]]; echo $?)
[[ -f "$REPO/.agent/loop/state/improve-test.json" ]]; check "state-file-created" $?
[[ -f "$REPO/.agent/loop/active" ]]; check "active-flag-created" $?
run_lr status improve-test
printf '%s' "$OUT" | grep -q '"total_waves":3'; check "goal-row-cap-3" $?

echo
echo "=== (b) attempt: improved -> keep, worse -> discard, improved again -> keep ==="
LOOP_RUN_GRADE_CMD='printf "harness_score: 5.0\n"' run_lr attempt improve-test --desc "first try"
printf '%s' "$OUT" | grep -q 'status=keep'; check "attempt1-keep" $?
printf '%s' "$OUT" | grep -qx 'LOOP: continue'; check "attempt1-verdict-continue" $?
[[ "$(ledger_rows)" -eq 1 ]]; check "attempt1-one-ledger-row" $?

LOOP_RUN_GRADE_CMD='printf "harness_score: 3.0\n"' run_lr attempt improve-test --desc "worse try"
printf '%s' "$OUT" | grep -q 'status=discard'; check "attempt2-discard-worse" $?
[[ "$(ledger_rows)" -eq 2 ]]; check "attempt2-two-ledger-rows" $?

LOOP_RUN_GRADE_CMD='printf "harness_score: 8.0\n"' run_lr attempt improve-test --desc "better try"
printf '%s' "$OUT" | grep -q 'status=keep'; check "attempt3-keep-improved" $?
printf '%s' "$OUT" | grep -qx 'LOOP: stop(cap)'; check "attempt3-cap-reached-stop" $?
[[ ! -f "$REPO/.agent/loop/active" ]]; check "cap-removes-active-flag" $?

run_lr attempt improve-test --desc "should be refused"
[[ $RC -ne 0 ]]; check "attempt-beyond-cap-refused" $?
[[ "$(ledger_rows)" -eq 3 ]]; check "no-ledger-row-past-cap" $?

echo
echo "=== (c) timeout: sleeping stub is killed at LOOP_RUN_TIMEOUT_S ==="
run_lr init timeout-test --target '.*' --base "$BASE_REF" --cap 5
START="$(date +%s)"
LOOP_RUN_GRADE_CMD='sleep 30' LOOP_RUN_TIMEOUT_S=1 run_lr attempt timeout-test --desc "sleeper"
END="$(date +%s)"
printf '%s' "$OUT" | grep -q 'status=timeout'; check "timeout-status" $?
[[ $((END - START)) -lt 10 ]]; check "timeout-killed-fast" $?
grep -q $'\ttimeout\t' "$REPO/.agent/loop/results.tsv"; check "timeout-in-ledger" $?

echo
echo "=== (d) circuit breaker: 2 consecutive GATE-fail (score 0.0) stubs stop the loop ==="
run_lr init breaker-test --target '.*' --base "$BASE_REF" --cap 5
LOOP_RUN_GRADE_CMD='printf "harness_score: 0.0\n"' run_lr attempt breaker-test --desc "gate fail 1"
printf '%s' "$OUT" | grep -qx 'LOOP: continue'; check "breaker-attempt1-continues" $?
LOOP_RUN_GRADE_CMD='printf "harness_score: 0.0\n"' run_lr attempt breaker-test --desc "gate fail 2"
printf '%s' "$OUT" | grep -qx 'LOOP: stop(circuit-breaker)'; check "breaker-trips-on-2nd" $?
run_lr status breaker-test
printf '%s' "$OUT" | grep -q '"status":"aborted"'; check "breaker-goal-aborted" $?
[[ ! -f "$REPO/.agent/loop/active" ]]; check "breaker-removes-active-flag" $?
run_lr attempt breaker-test --desc "3rd should be refused"
[[ $RC -ne 0 ]]; check "breaker-3rd-attempt-refused" $?

echo
echo "=== (e) cap: 5 forced non-improving (but non-zero) scores run out the full cap ==="
run_lr init cap-test --target '.*' --base "$BASE_REF" --cap 5
for i in 1 2 3 4 5; do
  LOOP_RUN_GRADE_CMD='printf "harness_score: 4.0\n"' run_lr attempt cap-test --desc "forced $i"
done
printf '%s' "$OUT" | grep -qx 'LOOP: stop(cap)'; check "cap-stop-on-5th" $?
# results.tsv is a single shared ledger across every scenario in this battery
# (matching production: one loop is active at a time), so count THIS
# scenario's rows by its distinguishing description rather than the file total.
[[ "$(grep -c $'\tforced [0-9]$' "$REPO/.agent/loop/results.tsv")" -eq 5 ]]; check "cap-five-ledger-rows" $?
run_lr status cap-test
printf '%s' "$OUT" | grep -q '"status":"complete"'; check "cap-goal-complete" $?

echo
echo "=== (f) resume: a fresh invocation continues attempt numbering from persisted state ==="
run_lr init resume-test --target '.*' --base "$BASE_REF" --cap 5
LOOP_RUN_GRADE_CMD='printf "harness_score: 5.0\n"' run_lr attempt resume-test --desc "attempt one"
[[ -f "$REPO/.agent/loop/run-resume-test-1.log" ]]; check "resume-attempt1-log" $?
# simulate a restart: a brand-new loop-run.sh invocation (no shared shell state)
run_lr status resume-test
printf '%s' "$OUT" | grep -q '"current_wave":2'; check "resume-status-shows-wave-2" $?
LOOP_RUN_GRADE_CMD='printf "harness_score: 6.0\n"' run_lr attempt resume-test --desc "attempt two after restart"
[[ -f "$REPO/.agent/loop/run-resume-test-2.log" ]]; check "resume-attempt2-numbered-correctly" $?
printf '%s' "$OUT" | grep -q 'n=2 '; check "resume-attempt2-n-is-2" $?

echo
echo "=== (g) explicit stop before cap/breaker ==="
run_lr init stop-test --target '.*' --base "$BASE_REF" --cap 5
LOOP_RUN_GRADE_CMD='printf "harness_score: 5.0\n"' run_lr attempt stop-test --desc "one attempt"
run_lr stop stop-test
[[ $RC -eq 0 ]]; check "explicit-stop-exit-0" $?
[[ ! -f "$REPO/.agent/loop/active" ]]; check "explicit-stop-removes-flag" $?
run_lr status stop-test
printf '%s' "$OUT" | grep -q '"status": "stopped"'; check "explicit-stop-state-stopped" $?

echo
echo "=== RED: missing state / unknown slug ==="
run_lr status this-slug-was-never-init-ed
[[ $RC -ne 0 ]]; check "red-unknown-slug-status-refused" $?
run_lr attempt this-slug-was-never-init-ed --desc "x"
[[ $RC -ne 0 ]]; check "red-unknown-slug-attempt-refused" $?

echo
echo "=== RED: --desc over 80 chars is refused, no ledger row ==="
run_lr init desc-test --target '.*' --base "$BASE_REF" --cap 5
BEFORE="$(ledger_rows)"
LONG_DESC="$(python3 -c "print('x' * 81)")"
LOOP_RUN_GRADE_CMD='printf "harness_score: 5.0\n"' run_lr attempt desc-test --desc "$LONG_DESC"
[[ $RC -ne 0 ]]; check "red-long-desc-refused" $?
[[ "$(ledger_rows)" -eq "$BEFORE" ]]; check "red-long-desc-no-ledger-row" $?

echo
echo "=== RED: duplicate init on the same slug is refused ==="
run_lr init improve-test --target 'agents/.*' --base "$BASE_REF" --cap 3
[[ $RC -ne 0 ]]; check "red-duplicate-init-refused" $?

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
