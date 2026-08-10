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
  loop-write-guard-test.sh loop-ledger-test.sh
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
  # hermetic: GRADE_HERMETIC=1 gates the seams (C3) and skips the INTEGRITY phase,
  # so scoring logic is tested with stubs in a tmp dir (no git repo).
  local d="$1"; shift
  OUT="$(GRADE_HERMETIC=1 GRADE_TESTS_DIR="$d" GRADE_RUBRIC="$RUBRIC" GRADE_SKIP_GITLEAKS=1 bash "$GRADE" "$@" 2>&1)"
  RC=$?
}

echo "=== (a) clean tree: GATE pass + all guards green -> harness_score 10.0 ==="
D="$(mktemp -d "$TMP_ROOT/aXXXX")"; seed_pass_dir "$D"
run_grade "$D"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 10\.0$'; check "baseline-score-10.0" $?
printf '%s\n' "$OUT" | grep -qE '^mode:review-false-clean N/A'; check "process-mode-is-NA" $?
printf '%s\n' "$OUT" | grep -qE '^mode:vacuous-parity N/A .*GATE floor'; check "gate-covered-mode-is-NA" $?
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
echo "=== (c) one guard red -> that mode FAIL, score drops to 9.0 ==="
D="$(mktemp -d "$TMP_ROOT/cXXXX")"; seed_pass_dir "$D"; make_fail "$D/completion-verify-test.sh"
run_grade "$D"
printf '%s\n' "$OUT" | grep -qE '^mode:silent-drop FAIL .*re-opened'; check "regressed-mode-FAIL" $?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 9\.0$'; check "one-regression-score-9.0" $?

echo
echo "=== (d) missing guard battery -> fail-closed FAIL + 0.5 OER penalty (8.5) ==="
D="$(mktemp -d "$TMP_ROOT/dXXXX")"; seed_pass_dir "$D"; rm -f "$D/evals-test.sh"
run_grade "$D"
printf '%s\n' "$OUT" | grep -qE '^mode:loose-coercion FAIL .*missing .*fail-closed'; check "missing-guard-fail-closed" $?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 8\.5$'; check "missing-guard-oer-penalty" $?

echo
echo "=== (e) unparseable rubric -> fail-closed harness_score 0 ==="
D="$(mktemp -d "$TMP_ROOT/eXXXX")"; seed_pass_dir "$D"
BAD="$TMP_ROOT/bad.yaml"; printf '%s\n' 'not: [a valid, failure_modes' '  - broken' > "$BAD"
OUT="$(GRADE_TESTS_DIR="$D" GRADE_RUBRIC="$BAD" GRADE_SKIP_GITLEAKS=1 bash "$GRADE" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "bad-rubric-score-0" $?
printf '%s\n' "$OUT" | grep -qiE 'fail-closed'; check "bad-rubric-fail-closed-msg" $?

echo
echo "=== (f) INTEGRITY in a scratch git repo (unconditional; clean tree, --base, full-path) ==="
G="$TMP_ROOT/gitrepo"; mkdir -p "$G"
(
  cd "$G" && git init -q && git config user.email t@t && git config user.name t
  mkdir -p core/tests evals agents
  for b in "${ALL_BATTERIES[@]}"; do printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "core/tests/$b"; done
  cp "$RUBRIC" evals/failure-modes.yaml
  cp "$GRADE" core/tests/grade.sh
  echo base > agents/reviewer.md && git add -A && git commit -qm base
  echo change > agents/reviewer.md && git add -A && git commit -qm on-target  # agents-only candidate
)
BASE="$(cd "$G" && git rev-parse HEAD~1)"
# on-target-only candidate under a SAFE target -> real checklist score 10.0
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 10\.0$'; check "on-target-passes-boundary" $?
# planted __pycache__ under the executed surface is GITIGNORED — invisible to the
# clean-tree check — yet python would load a crafted .pyc instead of the verified
# source. The INTEGRITY phase purges it BEFORE any battery executes.
( cd "$G" && printf '__pycache__/\n*.pyc\n' > .gitignore && git add .gitignore && git commit -qm gitignore
  mkdir -p core/hooks/__pycache__ && echo poison > core/hooks/__pycache__/hook_config.cpython-312.pyc )
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base HEAD --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 10\.0$'; check "ignored-pycache-does-not-block" $?
[[ ! -d "$G/core/hooks/__pycache__" ]]; check "planted-pycache-purged" $?
# add an OFF-target commit; the same safe target must discard and name it
( cd "$G" && echo drift > core/tests/sneaky.sh && git add -A && git commit -qm off-target )
BASE2="$(cd "$G" && git rev-parse HEAD~1)"
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE2" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "off-target-score-0" $?
printf '%s\n' "$OUT" | grep -qE 'TARGET-VIOLATION.*core/tests/sneaky.sh'; check "off-target-named" $?
# C4: a target that ADMITS the grader/verifier surface fails closed (even on a clean, on-target diff)
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE2" --target '(agents|core)/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'admits the grader/verifier surface'; check "target-admits-surface-refused" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "target-admits-surface-score-0" $?
# unanchored bypass closed: substring-y 'agents' must NOT classify agents/reviewer.md as on-target
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE" --target 'agents' 2>&1)"
printf '%s\n' "$OUT" | grep -qE '^harness_score: 0$'; check "unanchored-target-not-fooled" $?
# C4 RESIDUAL (round-3): a target admitting a BATTERY but not grade.sh itself must
# still be refused — every file under core/tests/ is executed as scoring code. The
# old 6-named-file list let 'core/tests/sneaky\.sh' through; the ls-files enumeration
# now catches it (sneaky.sh is tracked under the surface).
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE2" --target 'core/tests/sneaky\.sh' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'admits the grader/verifier surface'; check "target-admits-battery-refused" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "target-admits-battery-score-0" $?
# round-4: gitleaks.toml is GATE scoring input — a target admitting it (weaken the
# allowlist) must be refused. Track a gitleaks.toml in the scratch repo, then target it.
( cd "$G" && echo '[allowlist]' > gitleaks.toml && git add gitleaks.toml && git commit -qm gitleaks-cfg )
BASEG="$(cd "$G" && git rev-parse HEAD~1)"
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASEG" --target 'gitleaks\.toml' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'admits the grader/verifier surface'; check "target-admits-gitleaks-refused" $?
# nested surface path (evals/datasets/…) — git pathspec '*' is recursive, so an
# evals-subdir target is enumerated and refused too (insurance vs a future glob edit).
( cd "$G" && mkdir -p evals/datasets && echo x > evals/datasets/d.jsonl && git add -A && git commit -qm nested-eval )
BASEN="$(cd "$G" && git rev-parse HEAD~1)"
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASEN" --target 'evals/datasets/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'admits the grader/verifier surface'; check "target-admits-nested-eval-refused" $?
# a surface file that lands in the actual DIFF is refused even if a (hypothetically
# mis-scoped) target matched it — the authoritative per-file check (Layer 2). Here a
# committed edit to core/tests/grade.sh is caught as a surface violation, not merely
# off-target, with the dedicated message.
( cd "$G" && printf '\n# tamper\n' >> core/tests/grade.sh && git add -A && git commit -qm surface-edit )
BASE3="$(cd "$G" && git rev-parse HEAD~1)"
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE3" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'changed grader/verifier surface file'; check "surface-file-in-diff-refused" $?
( cd "$G" && git reset -q --hard HEAD~1 )   # drop the tamper commit; restore grade.sh
# git failure inside INTEGRITY fails CLOSED, not open (round-3 LOW): a git stub that
# errors must not let the phase proceed. A PATH-first fake git returning 1 trips the
# first INTEGRITY git call (surface enumeration).
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$FAKEBIN/git"; chmod +x "$FAKEBIN/git"
OUT="$(cd "$G" && PATH="$FAKEBIN:$PATH" GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qiE 'fail-closed'; check "git-error-fails-closed" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "git-error-score-0" $?

echo
echo "=== (f2) INTEGRITY fail-closed: no boundary (C1), assume-unchanged (C2), dirty, untracked, bad base ==="
# C1: a real grading run with NO --base/--target cannot enforce pillar 3 -> fail closed.
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'requires --base .* and --target'; check "bare-grading-fails-closed" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "bare-grading-score-0" $?
# --target without --base -> fail closed
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'requires --base'; check "target-without-base-fails-closed" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "target-without-base-score-0" $?
# C2: assume-unchanged bit hides a modified battery from BOTH status and diff -> fail closed
( cd "$G" && printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > core/tests/verify-all-test.sh
  git update-index --assume-unchanged core/tests/verify-all-test.sh )
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE2" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'assume-unchanged/skip-worktree'; check "assume-unchanged-refused" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "assume-unchanged-score-0" $?
( cd "$G" && git update-index --no-assume-unchanged core/tests/verify-all-test.sh
  git checkout -q -- core/tests/verify-all-test.sh )   # clean up
# dirty tree: uncommitted edit -> refuse
( cd "$G" && echo dirty >> core/tests/sneaky.sh )
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE2" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'working tree is dirty'; check "dirty-tree-refused" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "dirty-tree-score-0" $?
( cd "$G" && git checkout -q -- core/tests/sneaky.sh )   # clean up
# UNTRACKED file: invisible to `git diff` but it EXECUTES in the batteries -> refuse
( cd "$G" && echo tamper > core/tests/untracked-helper.sh )
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base "$BASE2" --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'working tree is dirty'; check "untracked-file-refused" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "untracked-file-score-0" $?
( cd "$G" && rm -f core/tests/untracked-helper.sh )   # clean up
# git error (bogus base) fails closed, not open
OUT="$(cd "$G" && GRADE_SKIP_GITLEAKS=1 bash core/tests/grade.sh --base deadbeefbogus --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'cannot verify boundary'; check "bad-base-fails-closed" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "bad-base-score-0" $?

echo
echo "=== (f3) SEAM guard (C3): GRADE_TESTS_DIR/GRADE_RUBRIC honored only with GRADE_HERMETIC=1 ==="
OUT="$(GRADE_TESTS_DIR=/tmp/whatever GRADE_SKIP_GITLEAKS=1 bash "$GRADE" --base x --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'SEAM-GUARD'; check "tests-dir-seam-without-hermetic-refused" $?
printf '%s\n' "$OUT" | tail -n1 | grep -qE '^harness_score: 0$'; check "seam-without-hermetic-score-0" $?
OUT="$(GRADE_RUBRIC=/tmp/whatever.yaml GRADE_SKIP_GITLEAKS=1 bash "$GRADE" --base x --target 'agents/.*' 2>&1)"
printf '%s\n' "$OUT" | grep -qE 'SEAM-GUARD'; check "rubric-seam-without-hermetic-refused" $?

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
OUT="$(GRADE_HERMETIC=1 GRADE_TESTS_DIR="$D" GRADE_RUBRIC="$DUP" GRADE_SKIP_GITLEAKS=1 bash "$GRADE" 2>&1)"
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
# extraction floor: (g)/(g3) share this grep to enumerate mapped batteries — if a
# guard_for refactor breaks the extraction, both checks would pass VACUOUSLY on an
# empty list (the vacuous-green mode this repo names). A clean tree maps >=8
# batteries, so an extraction below that floor is a broken extractor, not a clean map.
mapped_count="$(grep -oE 'echo "[a-z0-9-]+\.sh"' "$GRADE" | wc -l | tr -d ' ')"
[[ "$mapped_count" -ge 8 ]]; check "extraction-floor-8-mapped-batteries" $?
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
MAP_MODES=(silent-drop vacuous-green glob-scope-miss bypass-flag unanchored-skip infra-as-verdict lexical-containment injection-breakout loose-coercion stale-ssot)
MAP_BATT=(completion-verify-test.sh verify-all-test.sh supply-chain-scan-test.sh pre-tool-guard-test.sh spec-gate-test.sh llm-judge-test.sh reference-judge-test.sh pre-tool-guard-test.sh evals-test.sh doc-reality.sh)
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
echo "=== (g3) DRIFT GATE: no GATE battery may appear as a guard_for target ==="
# A guard that is also a GATE battery creates a second, unreachable verdict path
# (the GATE short-circuit runs first) — the 2026-08-09 vacuous-parity decision.
# Extract GATE_SET straight from grade.sh's GATE_BATTERIES array rather than mirror
# it here, so the C8 additions (loop-write-guard-test / loop-ledger-test) can't drift
# out of this drift-gate (round-3 review Major).
GATE_SET="$(sed -n 's/^GATE_BATTERIES=(\(.*\))/\1/p' "$GRADE")"
[[ -n "$GATE_SET" ]]; check "gate-set-extracted-from-grade" $?
gate_in_map=0
while IFS= read -r b; do
  for g in $GATE_SET; do
    [[ "$b" == "$g" ]] && { echo "    GATE battery in guard map: $b"; gate_in_map=$((gate_in_map + 1)); }
  done
done < <(grep -oE 'echo "[a-z0-9-]+\.sh"' "$GRADE" | sed 's/echo "//; s/"//')
[[ $gate_in_map -eq 0 ]]; check "no-gate-battery-in-guard-map" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
