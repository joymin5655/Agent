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
echo "=== (g4) SURFACE DRIFT: the 5 hand-maintained guarded-surface definitions must agree ==="
# The enforcement surface (core/tests/, evals/, loop-write-guard.py, pre-tool-guard.sh,
# loop-ledger.sh, hooks.json, adapter.sh, gitleaks.toml) is declared FIVE separate times:
#   1. grade.sh's INTEGRITY `surface_list` (git ls-files pathspec, ~line 226)
#   2. grade.sh's INTEGRITY `guarded_surface_re` (per-file regex, ~line 274)
#   3. loop-write-guard.py's _guarded_dirs()
#   4. loop-write-guard.py's _guarded_files()
#   5. loop-write-guard.py's GUARDED_TOKENS — the BASH write path's copy, and the
#      only one gating `sed -i`/redirect writes. A file present in 1-4 but absent
#      from 5 escalates on Write/Edit yet is freely rewritable from Bash.
# A hand-edit to one without the others silently reopens the L-2 tamper path the
# C4/C8 fixes closed. Extract each LIVE (never hand-mirror the lists here — that would
# just be another copy to drift) and assert all 5 cover the same surface.

# extractor 1: grade.sh's surface_list pathspec array (the awk range spans its
# multi-line backslash-continued literal).
extract_grade_pathspec() {
  awk '/surface_list="\$\(git -C/,/2>\/dev\/null\)"/' "$1" | grep -oE "'[^']+'" | tr -d "'"
}
# extractor 2: grade.sh's guarded_surface_re alternation.
extract_grade_regex() {
  sed -n "s/^[[:space:]]*guarded_surface_re='\^(\(.*\))'\$/\1/p" "$1" | tr '|' '\n'
}
# extractor 3+4: loop-write-guard.py's _guarded_dirs/_guarded_files, called LIVE via
# a throwaway import (never regex-scraped Python) so a refactor of the functions'
# internals can't fool a source-text scrape.
extract_lwg() {
  python3 - "$HOOK" "$1" <<'PY'
import importlib.util, os, sys
hook_path, root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("lwg", hook_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
prefix = mod._real(root) + os.sep
def rel(p):
    return p[len(prefix):] if p.startswith(prefix) else p
for d in mod._guarded_dirs(root):
    print("DIR:" + rel(d))
for f in sorted(mod._guarded_files(root)):
    print("FILE:" + rel(f))
PY
}
# extractor 5: the BASH write path's token list, also called live.
extract_lwg_tokens() {
  python3 - "$HOOK" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lwg", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for t in sorted(mod.GUARDED_TOKENS):
    print(t)
PY
}
# canon_from_pathspec/canon_from_regex — normalize each source's tokens to DIR:<x> /
# FILE:<x> lines matching extract_lwg's output shape.
canon_from_pathspec() {
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    if [[ "$tok" == */\* ]]; then printf 'DIR:%s\n' "${tok%/\*}"
    else printf 'FILE:%s\n' "$tok"; fi
  done
}
canon_from_regex() {
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    tok="${tok//\\./.}"
    if [[ "$tok" == */ ]]; then printf 'DIR:%s\n' "${tok%/}"
    else printf 'FILE:%s\n' "${tok%\$}"; fi
  done
}

HOOK="$REPO_ROOT/core/hooks/loop-write-guard.py"
SET1="$(extract_grade_pathspec "$GRADE" | canon_from_pathspec | sort -u)"
SET2="$(extract_grade_regex "$GRADE" | canon_from_regex | sort -u)"
SET3="$(extract_lwg "$TMP_ROOT" | sort -u)"

[[ -n "$SET1" ]]; check "surface-list-extracted" $?
[[ -n "$SET2" ]]; check "guarded-regex-extracted" $?
[[ -n "$SET3" ]]; check "loop-write-guard-extracted" $?

if [[ "$SET1" == "$SET2" ]]; then
  check "surface-list-matches-guarded-regex" 0
else
  echo "    drift: surface_list vs guarded_surface_re"; diff <(echo "$SET1") <(echo "$SET2") | sed 's/^/      /'
  check "surface-list-matches-guarded-regex" 1
fi
if [[ "$SET1" == "$SET3" ]]; then
  check "surface-list-matches-loop-write-guard" 0
else
  echo "    drift: surface_list vs loop-write-guard.py"; diff <(echo "$SET1") <(echo "$SET3") | sed 's/^/      /'
  check "surface-list-matches-loop-write-guard" 1
fi

# 5th definition: every entry of the shared surface must also appear as a Bash
# token, or the Bash write path leaves it unguarded. Containment (not equality):
# the token list legitimately carries two ledger-only extras that the Write/Edit
# path reaches through its own append-only check.
SET5="$(extract_lwg_tokens)"
[[ -n "$SET5" ]]; check "bash-guarded-tokens-extracted" $?
# uncovered_by_tokens <surface-set> <token-set> — prints each surface entry that
# has no matching Bash token; empty output means full coverage. Shared by the
# live check and its RED mutation below, so the mutation exercises the SAME
# comparison rather than re-asserting its own edit.
uncovered_by_tokens() {
  local surface="$1" tokens="$2" entry tok
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    tok="${entry#DIR:}"; tok="${tok#FILE:}"
    printf '%s\n' "$tokens" | grep -qxF "$tok" || printf '%s\n' "$tok"
  done <<< "$surface"
}
missing_tok="$(uncovered_by_tokens "$SET1" "$SET5")"
if [[ -z "$missing_tok" ]]; then
  check "surface-covered-by-bash-guarded-tokens" 0
else
  echo "    unguarded from Bash: $(printf '%s' "$missing_tok" | tr '\n' ' ')"
  check "surface-covered-by-bash-guarded-tokens" 1
fi

echo
echo "=== (g4-floor) CONTENT FLOOR: a SYNCHRONIZED shrink of all copies must fail ==="
# (g4) above only proves the copies AGREE. Dropping an entry from every copy at
# once — the one edit that keeps them agreeing while unguarding a real scoring
# input — would pass it. This floor names the surface that must always be there.
# Deliberately hand-written: it is the one place a human decision belongs, and it
# is itself inside the guarded surface (core/tests/), so a loop agent editing it
# escalates and scores TARGET-VIOLATION.
FLOOR="DIR:core/tests
DIR:evals
FILE:adapters/claude-code/adapter.sh
FILE:core/hooks/loop-write-guard.py
FILE:core/hooks/pre-tool-guard.sh
FILE:core/infra/loop-ledger.sh
FILE:gitleaks.toml
FILE:hooks/hooks.json"
# floor_gaps <floor> <surface> — prints each required entry the surface lacks.
# Shared with the RED mutation below for the same reason as uncovered_by_tokens.
floor_gaps() {
  local floor="$1" surface="$2" entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    printf '%s\n' "$surface" | grep -qxF "$entry" || printf '%s\n' "$entry"
  done <<< "$floor"
}
missing_floor="$(floor_gaps "$FLOOR" "$SET1")"
if [[ -z "$missing_floor" ]]; then
  check "surface-meets-content-floor" 0
else
  echo "    dropped from the guarded surface: $(printf '%s' "$missing_floor" | tr '\n' ' ')"
  check "surface-meets-content-floor" 1
fi

echo
echo "=== (g4-mutation) RED: an injected drift must be CAUGHT, not silently pass ==="
# Prove the comparison above is sensitive, not vacuously always-equal: inject an
# extra entry into a SCRATCH COPY of grade.sh's guarded_surface_re only (the real
# file and loop-write-guard.py are untouched) and assert the extracted sets now
# disagree.
MUT_GRADE="$TMP_ROOT/grade-mutated.sh"
sed "s#guarded_surface_re='\^(#guarded_surface_re='^(core/tests-drift-injected/|#" "$GRADE" > "$MUT_GRADE"
SET2_MUT="$(extract_grade_regex "$MUT_GRADE" | canon_from_regex | sort -u)"
[[ "$SET1" != "$SET2_MUT" ]]; check "injected-drift-detected" $?
# Same sensitivity proof for the two new comparisons, run through the SAME
# functions the live checks use (never a re-assertion of the edit itself):
# drop gitleaks.toml from a scratch copy of each input and require the shared
# comparison to REPORT that gap.
SET5_MUT="$(printf '%s\n' "$SET5" | grep -vxF 'gitleaks.toml')"
[[ "$(uncovered_by_tokens "$SET1" "$SET5_MUT")" == "gitleaks.toml" ]]
check "bash-token-drop-detected-by-same-comparison" $?
SURFACE_MUT="$(printf '%s\n' "$SET1" | grep -vxF 'FILE:gitleaks.toml')"
[[ "$(floor_gaps "$FLOOR" "$SURFACE_MUT")" == "FILE:gitleaks.toml" ]]
check "synchronized-shrink-detected-by-content-floor" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
