#!/usr/bin/env bash
# grade-test.sh — battery for core/tests/grade.sh (P2-2 + L-1 impl).
#
# grade.sh is a loop-time tool that re-runs the real batteries; running it for real
# would cost minutes and couple this test to every battery's behavior. Instead we
# drive it HERMETICALLY: GRADE_TESTS_DIR points at a fixture dir of battery STUBS
# (each exit 0 or exit 1) and GRADE_RUBRIC points at the REAL failure-modes.yaml, so
# we test grade.sh's own logic — GATE floor, per-mode checklist, fail-closed scoring,
# and the mode->guard map — deterministically and offline.
#
# Usage: bash core/tests/grade-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADE="$REPO_ROOT/core/tests/grade.sh"
REAL_TESTS="$REPO_ROOT/core/tests"
RUBRIC="$REPO_ROOT/evals/failure-modes.yaml"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Every battery grade.sh may invoke (GATE set + every guard_for target).
ALL_BATTERIES=(
  sanitize-audit.sh adapter-parity.sh hook-config-test.sh post-commit-autosync-test.sh
  completion-verify-test.sh verify-all-test.sh supply-chain-scan-test.sh
  pre-tool-guard-test.sh spec-gate-test.sh llm-judge-test.sh reference-judge-test.sh
  evals-test.sh doc-reality.sh
)

# populate <dir> with every battery as a passing stub
seed_pass_dir() {
  local d="$1" b
  for b in "${ALL_BATTERIES[@]}"; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$d/$b"
  done
}
make_fail() { printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$1"; }

run_grade() {  # <tests_dir> [extra args...] -> stdout+stderr, sets RC
  local d="$1"; shift
  OUT="$(GRADE_TESTS_DIR="$d" GRADE_RUBRIC="$RUBRIC" GRADE_SKIP_GITLEAKS=1 bash "$GRADE" "$@" 2>&1)"
  RC=$?
}

echo "=== (a) clean tree: GATE pass + all guards green -> harness_score 11.0 ==="
D="$(mktemp -d "$TMP_ROOT/aXXXX")"; seed_pass_dir "$D"
run_grade "$D"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 11\.0$'; check "baseline-score-11.0" $?
printf '%s\n' "$OUT" | grep -qE '^mode:review-false-clean N/A'; check "process-mode-is-NA" $?
printf '%s\n' "$OUT" | grep -qE '^mode:silent-drop PASS'; check "silent-drop-PASS-when-green" $?
# exactly one harness_score line, and it is the LAST line (output contract)
[[ "$(printf '%s\n' "$OUT" | grep -c '^harness_score:')" -eq 1 ]]; check "exactly-one-score-line" $?
[[ "$(printf '%s\n' "$OUT" | tail -n1)" == harness_score:* ]]; check "score-is-last-line" $?

echo
echo "=== (b) GATE fail -> harness_score 0, no mode checklist emitted ==="
D="$(mktemp -d "$TMP_ROOT/bXXXX")"; seed_pass_dir "$D"; make_fail "$D/sanitize-audit.sh"
run_grade "$D"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "gate-fail-score-0" $?
printf '%s\n' "$OUT" | grep -qE 'GATE: FAIL'; check "gate-fail-message" $?
! printf '%s\n' "$OUT" | grep -qE '^mode:'; check "gate-fail-skips-checklist" $?

echo
echo "=== (c) one guard red -> that mode FAIL, score drops to 10.0 ==="
D="$(mktemp -d "$TMP_ROOT/cXXXX")"; seed_pass_dir "$D"; make_fail "$D/completion-verify-test.sh"
run_grade "$D"
printf '%s\n' "$OUT" | grep -qE '^mode:silent-drop FAIL .*re-opened'; check "regressed-mode-FAIL" $?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 10\.0$'; check "one-regression-score-10.0" $?

echo
echo "=== (d) missing guard battery -> fail-closed FAIL + 0.5 OER penalty (9.5) ==="
D="$(mktemp -d "$TMP_ROOT/dXXXX")"; seed_pass_dir "$D"; rm -f "$D/evals-test.sh"
run_grade "$D"
printf '%s\n' "$OUT" | grep -qE '^mode:loose-coercion FAIL .*missing .*fail-closed'; check "missing-guard-fail-closed" $?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 9\.5$'; check "missing-guard-oer-penalty" $?

echo
echo "=== (e) unparseable rubric -> fail-closed harness_score 0 ==="
D="$(mktemp -d "$TMP_ROOT/eXXXX")"; seed_pass_dir "$D"
BAD="$TMP_ROOT/bad.yaml"; printf '%s\n' 'not: [a valid, failure_modes' '  - broken' > "$BAD"
OUT="$(GRADE_TESTS_DIR="$D" GRADE_RUBRIC="$BAD" GRADE_SKIP_GITLEAKS=1 bash "$GRADE" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "bad-rubric-score-0" $?
printf '%s\n' "$OUT" | grep -qiE 'fail-closed'; check "bad-rubric-fail-closed-msg" $?

echo
echo "=== (f) TARGET-boundary in a scratch git repo (clean tree, --base, full-path) ==="
G="$TMP_ROOT/gitrepo"; mkdir -p "$G"
(
  cd "$G" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p core/tests evals agents
  for b in "${ALL_BATTERIES[@]}"; do printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "core/tests/$b"; done
  cp "$RUBRIC" evals/failure-modes.yaml
  cp "$GRADE" core/tests/grade.sh
  echo base > agents/reviewer.md && git add -A && git commit -qm base
  echo change > agents/reviewer.md          # on-target edit
  echo drift > core/tests/sneaky.sh          # OFF-target edit
  git add -A && git commit -qm candidate     # tree is CLEAN after commit
)
BASE="$(cd "$G" && git rev-parse HEAD~1)"
# off-target committed file -> discard 0, named
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "off-target-score-0" $?
printf '%s\n' "$OUT" | grep -qE 'TARGET-VIOLATION.*core/tests/sneaky.sh'; check "off-target-named" $?
# a full-path regex covering both dirs passes the boundary -> real checklist score
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE" --target '(agents|core)/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 11\.0$'; check "on-target-passes-boundary" $?
# unanchored bypass is closed: a substring-y regex must NOT classify core/tests as on-target
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE" --target 'agents' 2>&1)"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "unanchored-target-not-fooled" $?

echo
echo "=== (f2) TARGET fail-closed: --target without --base, dirty tree, and bad base ==="
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'requires --base'; check "target-without-base-fails-closed" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "target-without-base-score-0" $?
# dirty tree: leave an uncommitted edit, then grade with --target -> refuse
( cd "$G" && echo dirty >> core/tests/sneaky.sh )
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE" --target '(agents|core)/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'working tree is dirty'; check "dirty-tree-refused" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "dirty-tree-score-0" $?
( cd "$G" && git checkout -q -- core/tests/sneaky.sh )   # clean up
# git error (bogus base) fails closed, not open
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base deadbeefbogus --target '(agents|core)/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'cannot verify boundary'; check "bad-base-fails-closed" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "bad-base-score-0" $?

echo
echo "=== (h) unknown flag fails closed (no silent check-disable) ==="
D="$(mktemp -d "$TMP_ROOT/hXXXX")"; seed_pass_dir "$D"
run_grade "$D" --taget 'agents/.*'   # typo
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "unknown-flag-score-0" $?

echo
echo "=== (i) duplicate rubric id is graded ONCE, not double-counted ==="
DUP="$TMP_ROOT/dup.yaml"
{ echo 'schema_version: "1.0.0"'; echo 'failure_modes:'
  echo '  - {id: stale-ssot, name: a, description: a, caught_in: a, detection_signal: a, grader_check: a}'
  echo '  - {id: stale-ssot, name: b, description: b, caught_in: b, detection_signal: b, grader_check: b}'
} > "$DUP"
D="$(mktemp -d "$TMP_ROOT/iXXXX")"; seed_pass_dir "$D"
OUT="$(GRADE_TESTS_DIR="$D" GRADE_RUBRIC="$DUP" GRADE_SKIP_GITLEAKS=1 bash "$GRADE" 2>&1)"
[[ "$(printf '%s\n' "$OUT" | grep -c '^mode:stale-ssot ')" -eq 1 ]]; check "duplicate-id-graded-once" $?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 1\.0$'; check "duplicate-id-score-1.0" $?

echo
echo "=== (g) DRIFT GATE: every rubric mode has a guard-map arm; every mapped battery exists ==="
D="$(mktemp -d "$TMP_ROOT/gXXXX")"; seed_pass_dir "$D"
run_grade "$D"
! printf '%s\n' "$OUT" | grep -qE 'no guard mapped'; check "no-unmapped-mode" $?
unmapped=0
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  grep -qE "^[[:space:]]*${id}\)" "$GRADE" || { echo "    unmapped: $id"; unmapped=$((unmapped + 1)); }
done < <(GRADE_RUBRIC="$RUBRIC" bash "$GRADE" --list-modes)
[[ $unmapped -eq 0 ]]; check "every-mode-has-case-arm" $?
missing=0
while IFS= read -r b; do
  [[ -f "$REAL_TESTS/$b" ]] || { echo "    missing real battery: $b"; missing=$((missing + 1)); }
done < <(grep -oE 'echo "[a-z0-9-]+\.sh"' "$GRADE" | sed 's/echo "//; s/"//')
[[ $missing -eq 0 ]]; check "every-mapped-battery-exists" $?

echo
echo "=== (g2) MAPPING CORRECTNESS: fail each code mode's battery -> exactly that mode red ==="
# Prove the map is not just present but CORRECT: swapping two mappings (both targets
# still exist, both arms still present) would pass (g) but must fail here.
# Pairs mirror grade.sh's guard_for (the test's copy IS the drift tripwire).
MAP_MODES=(silent-drop vacuous-green vacuous-parity glob-scope-miss bypass-flag unanchored-skip infra-as-verdict lexical-containment injection-breakout loose-coercion stale-ssot)
MAP_BATT=(completion-verify-test.sh verify-all-test.sh adapter-parity.sh supply-chain-scan-test.sh pre-tool-guard-test.sh spec-gate-test.sh llm-judge-test.sh reference-judge-test.sh pre-tool-guard-test.sh evals-test.sh doc-reality.sh)
mapfail=0
idx=0
n=${#MAP_MODES[@]}
while [[ $idx -lt $n ]]; do
  mode="${MAP_MODES[$idx]}"; batt="${MAP_BATT[$idx]}"; idx=$((idx + 1))
  D="$(mktemp -d "$TMP_ROOT/mXXXX")"; seed_pass_dir "$D"; make_fail "$D/$batt"
  run_grade "$D"
  # the mode(s) mapped to $batt must be FAIL; verify OUR mode is among them
  if ! printf '%s\n' "$OUT" | grep -qE "^mode:${mode} FAIL"; then
    echo "    map wrong: failing $batt did not flip $mode"; mapfail=$((mapfail + 1))
  fi
done
[[ $mapfail -eq 0 ]]; check "every-mode-maps-to-correct-battery" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
