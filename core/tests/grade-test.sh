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
echo "=== (f) TARGET-boundary: off-target diff -> harness_score 0 (uses a scratch git repo) ==="
G="$TMP_ROOT/gitrepo"; mkdir -p "$G"
(
  cd "$G" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p core/tests evals agents
  # seed the batteries + a rubric copy so grade.sh runs inside this repo
  for b in "${ALL_BATTERIES[@]}"; do printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "core/tests/$b"; done
  cp "$RUBRIC" evals/failure-modes.yaml
  cp "$GRADE" core/tests/grade.sh
  echo base > agents/reviewer.md && git add -A && git commit -qm base
  echo change > agents/reviewer.md          # on-target edit
  echo drift > core/tests/sneaky.sh          # OFF-target edit
  git add -A && git commit -qm candidate
)
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --target '^agents/' 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "off-target-score-0" $?
printf '%s\n' "$OUT" | grep -qE 'TARGET-VIOLATION.*core/tests/sneaky.sh'; check "off-target-named" $?
# on-target-only edit passes the boundary (score is emitted from the checklist)
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --target '^(agents|core)/' 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 11\.0$'; check "on-target-passes-boundary" $?

echo
echo "=== (g) DRIFT GATE: every rubric mode has a guard-map arm; every mapped battery exists ==="
# (g1) every mode id in the real rubric resolves to a case arm in grade.sh (no @unknown@)
D="$(mktemp -d "$TMP_ROOT/gXXXX")"; seed_pass_dir "$D"
run_grade "$D"
! printf '%s\n' "$OUT" | grep -qE 'no guard mapped'; check "no-unmapped-mode" $?
unmapped=0
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  grep -qE "^[[:space:]]*${id}\)" "$GRADE" || { echo "    unmapped: $id"; unmapped=$((unmapped + 1)); }
done < <(GRADE_RUBRIC="$RUBRIC" bash "$GRADE" --list-modes)
[[ $unmapped -eq 0 ]]; check "every-mode-has-case-arm" $?
# (g2) every battery named in guard_for exists in the REAL core/tests dir
missing=0
while IFS= read -r b; do
  [[ -f "$REAL_TESTS/$b" ]] || { echo "    missing real battery: $b"; missing=$((missing + 1)); }
done < <(grep -oE 'echo "[a-z0-9-]+\.sh"' "$GRADE" | sed 's/echo "//; s/"//')
[[ $missing -eq 0 ]]; check "every-mapped-battery-exists" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
