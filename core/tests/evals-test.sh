#!/usr/bin/env bash
# evals-test.sh — verify the eval harness runner (evals/run-evals.py) actually
# grades: it passes the real labeled dataset, CATCHES a mislabeled case in both
# directions (so the comparison is load-bearing, not vacuous), enforces Pass^k,
# gates on a baseline coverage regression, and refuses a malformed/duplicate/
# under-specified dataset or a missing verifier — never a silent pass.
#
# Mirrors the other core/tests batteries: isolated tmp inputs, a check() tally,
# grep on stable output markers + exit code.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/evals/run-evals.py"
DATASET="$REPO_ROOT/evals/datasets/completion-verify.jsonl"
BASELINE="$REPO_ROOT/evals/baseline.json"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT=""; RC=0
run() { OUT="$(python3 "$RUNNER" "$@" 2>&1)"; RC=$?; }

# baselines with different coverage floors (accuracy bar is always correct==total)
printf '%s\n' '{"min_cases":1}'  > "$TMP/bl1.json"
printf '%s\n' '{"min_cases":2}'  > "$TMP/bl2.json"
printf '%s\n' '{"min_cases":10}' > "$TMP/bl10.json"

echo "=== (a) the real dataset -> EVALS PASS, exit 0, pass^3 OK ==="
run --dataset "$DATASET" --baseline "$BASELINE"
[[ $RC -eq 0 ]]; check "real-dataset-pass" $?
printf '%s' "$OUT" | grep -q 'EVALS PASS'; check "real-dataset-emits-pass" $?
printf '%s' "$OUT" | grep -q 'pass^3: OK'; check "real-dataset-passk-ok" $?

echo
echo "=== (b) a CONFIRMED case mislabeled REFUTED -> MISMATCH, exit 1 ==="
printf '%s\n' '{"slug":"x","expect":"REFUTED","claim":{"tests":["true"]}}' > "$TMP/ml1.jsonl"
run --dataset "$TMP/ml1.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 1 ]]; check "mislabel-confirmed-fails" $?
printf '%s' "$OUT" | grep -q 'MISMATCH'; check "mislabel-confirmed-detected" $?

echo
echo "=== (c) a REFUTED case mislabeled CONFIRMED -> MISMATCH, exit 1 ==="
printf '%s\n' '{"slug":"y","expect":"CONFIRMED","claim":{"files":["nope.txt"]}}' > "$TMP/ml2.jsonl"
run --dataset "$TMP/ml2.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 1 ]]; check "mislabel-refuted-fails" $?
printf '%s' "$OUT" | grep -q 'MISMATCH'; check "mislabel-refuted-detected" $?

echo
echo "=== (d) a correct dataset below the coverage floor -> REGRESSION, exit 1 (and meeting the floor -> pass) ==="
printf '%s\n' '{"slug":"a","expect":"CONFIRMED","claim":{"tests":["true"]}}' \
              '{"slug":"b","expect":"REFUTED","claim":{"files":["nope.txt"]}}' > "$TMP/tiny.jsonl"
run --dataset "$TMP/tiny.jsonl" --baseline "$TMP/bl10.json"
[[ $RC -eq 1 ]]; check "below-coverage-floor-regresses" $?
printf '%s' "$OUT" | grep -q 'REGRESSION'; check "coverage-regression-named" $?
run --dataset "$TMP/tiny.jsonl" --baseline "$TMP/bl2.json"
[[ $RC -eq 0 ]]; check "tiny-dataset-meets-floor" $?

echo
echo "=== (e) a malformed JSONL line -> dataset defect, exit 1 ==="
printf '%s\n' '{"slug":"ok","expect":"CONFIRMED","claim":{"tests":["true"]}}' \
              'this is not json' > "$TMP/bad.jsonl"
run --dataset "$TMP/bad.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 1 ]]; check "malformed-line-fails" $?
printf '%s' "$OUT" | grep -qi 'defect'; check "malformed-line-named" $?

echo
echo "=== (f) a duplicate slug -> defect, exit 1 ==="
printf '%s\n' '{"slug":"dup","expect":"CONFIRMED","claim":{"tests":["true"]}}' \
              '{"slug":"dup","expect":"REFUTED","claim":{"files":["nope.txt"]}}' > "$TMP/dup.jsonl"
run --dataset "$TMP/dup.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 1 ]]; check "duplicate-slug-fails" $?

echo
echo "=== (g) a case missing its 'expect' label -> defect, exit 1 ==="
printf '%s\n' '{"slug":"z","claim":{"tests":["true"]}}' > "$TMP/noexpect.jsonl"
run --dataset "$TMP/noexpect.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 1 ]]; check "missing-expect-fails" $?

echo
echo "=== (h) a missing verifier -> EVALS FAIL, exit 1 (never a false pass) ==="
run --dataset "$DATASET" --baseline "$BASELINE" --verifier "$TMP/nope.py"
[[ $RC -eq 1 ]]; check "missing-verifier-fails" $?

echo
echo "=== (i) a fixture-based case graded correctly through the runner (hermetic root) ==="
printf '%s\n' '{"slug":"fx","expect":"CONFIRMED","fixture":{"m.txt":"NEEDLE"},"claim":{"files":[{"path":"m.txt","contains":"NEEDLE"}]}}' > "$TMP/fx.jsonl"
run --dataset "$TMP/fx.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 0 ]]; check "fixture-case-confirmed" $?

echo
echo "=== (j) --quiet emits only the final verdict line ==="
run --dataset "$DATASET" --baseline "$BASELINE" --quiet
printf '%s' "$OUT" | grep -q 'EVALS PASS'; check "quiet-emits-final" $?
[[ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ]]; check "quiet-single-line" $?

echo
echo "=== (l) an unsafe (absolute) fixture key -> dataset defect, exit 1, and nothing leaks outside the sandbox ==="
rm -f "$TMP/leak.txt"
printf '{"slug":"abs","expect":"REFUTED","fixture":{"%s":"X"},"claim":{"files":["nope.txt"]}}\n' "$TMP/leak.txt" > "$TMP/abs.jsonl"
run --dataset "$TMP/abs.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 1 ]]; check "unsafe-absolute-fixture-fails" $?
printf '%s' "$OUT" | grep -qi 'unsafe fixture'; check "unsafe-absolute-fixture-named" $?
[[ ! -e "$TMP/leak.txt" ]]; check "unsafe-absolute-fixture-no-leak" $?

echo
echo "=== (l2) an unsafe (..) fixture key -> dataset defect, exit 1 ==="
printf '%s\n' '{"slug":"dd","expect":"REFUTED","fixture":{"../ESCAPE.txt":"X"},"claim":{"files":["nope.txt"]}}' > "$TMP/dd.jsonl"
run --dataset "$TMP/dd.jsonl" --baseline "$TMP/bl1.json"
[[ $RC -eq 1 ]]; check "unsafe-dotdot-fixture-fails" $?

echo
echo "=== (m) a malformed baseline -> EVALS FAIL, exit 1 (fail-closed coverage gate) ==="
printf '%s\n' 'this is not json' > "$TMP/badbl.json"
run --dataset "$DATASET" --baseline "$TMP/badbl.json"
[[ $RC -eq 1 ]]; check "malformed-baseline-fails-closed" $?
printf '%s' "$OUT" | grep -qi 'baseline'; check "malformed-baseline-named" $?

echo
echo "=== (m2) a non-integer min_cases (float) -> EVALS FAIL, not silently truncated ==="
# {"min_cases": 12.9} is valid JSON but not an integer floor; int() would coerce it
# to 12 and silently pass. The strict type-check must fail closed instead.
printf '%s\n' '{"min_cases": 12.9}' > "$TMP/floatbl.json"
run --dataset "$DATASET" --baseline "$TMP/floatbl.json"
[[ $RC -eq 1 ]]; check "float-min_cases-fails-closed" $?
printf '%s' "$OUT" | grep -qi 'not an integer'; check "float-min_cases-named" $?

echo
echo "=== (k) a nondeterministic grader (verdict flips across runs) -> Pass^k divergence, exit 1 ==="
# a fake verifier that alternates CONFIRMED/REFUTED on successive invocations via a
# counter file next to itself — so run 1 and run 2 disagree on the same case.
cat > "$TMP/flip-verifier.py" <<'PYEOF'
import os, json
ctr = os.path.abspath(__file__) + ".ctr"
try:
    n = int(open(ctr).read().strip())
except Exception:
    n = 0
n += 1
with open(ctr, "w") as f:
    f.write(str(n))
print(json.dumps({"verdict": "CONFIRMED" if n % 2 else "REFUTED"}))
PYEOF
printf '%s\n' '{"slug":"flip","expect":"CONFIRMED","claim":{"tests":["true"]}}' > "$TMP/flip.jsonl"
run --dataset "$TMP/flip.jsonl" --baseline "$TMP/bl1.json" --verifier "$TMP/flip-verifier.py"
[[ $RC -eq 1 ]]; check "passk-divergence-fails" $?
printf '%s' "$OUT" | grep -qi 'nondeterministic'; check "passk-divergence-detected" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
