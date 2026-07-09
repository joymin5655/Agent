#!/usr/bin/env bash
# reference-judge-test.sh — verify E-1 batch-2: the semantic-track reference judge
# core, evals/judges/reference-judge.py.
#
# The judge is the DETERMINISTIC FLOOR of the semantic eval layer: it catches
# GREEN-BY-CONSTRUCTION tests — a cited test that "passes" but asserts nothing
# real ("tests that are green-by-construction (asserting true, testing nothing)",
# skills/verify-completion/SKILL.md step 2). It consumes a claim of the shape
#     { "summary": "...", "test_sources": ["rel/path/to/x-test.sh", ...] }
# and, for each cited test source, classifies the file MEANINGFUL iff it holds
# >=1 REAL assertion that is NOT trivially-constant. It emits the shared verdict
# schema (docs/scoring-convention.md):
#     { "verdict": "CONFIRMED"|"REFUTED", "score": 0.0-1.0, "target": "...",
#       "dimensions": { "test_meaningfulness": {"passed":P,"total":T} },
#       "refutations": [ "<why>", ... ], "schema_version": "1.0.0" }
# Gate: CONFIRMED iff total>0 AND every source meaningful; else REFUTED. Exit 0
# iff CONFIRMED — usable as a CI/wave GATE. Refute-by-default: anything
# unverifiable/malformed/empty/unsafe resolves to REFUTED, never a crash.
#
# The judge is FIDDLY (line-based bash+python real-vs-trivial heuristics) and is
# biased to false-REFUTED over false-CONFIRMED (a completion gate must NEVER bless
# a green-by-construction test), so this battery pins both directions:
#   trivially-green forms  -> REFUTED   (echo/exit0-only, [[ 1 -eq 1 ]], [[ 1 == 1 ]],
#                                         [ 1 = 1 ], [[ true ]], assert True,
#                                         assertTrue(True), assert False or True,
#                                         assert 1 == 1 / "x" == "x" (py const cmp),
#                                         `:` no-op, empty body)
#   meaningful forms       -> CONFIRMED (bash [[ "$out" == exp ]] || exit 1, grep -q,
#                                         check "..." $?, assert f(x)==3,
#                                         self.assertEqual(a,b), pytest.raises)
#   missing source         -> REFUTED (missing evidence)
#   unsafe ../ / absolute  -> REFUTED + NO read/leak outside root (sentinel canary)
#   symlink escaping root  -> REFUTED (realpath containment refuses it, never read)
#   empty test_sources     -> REFUTED (nothing to judge)
#   bare vs {"claim":{}}   -> both accepted
#   malformed claim        -> REFUTED, fail-safe (no crash)
#   trivial + real in ONE  -> CONFIRMED (a real assertion wins over co-located triviality)
#   partial (1 of 2 real)  -> REFUTED, dims passed=1 total=2
#
# Usage: bash core/tests/reference-judge-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JUDGE="$REPO_ROOT/evals/judges/reference-judge.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# hermetic project root the claim's test_sources resolve against
ROOT="$TMP_ROOT/root"
mkdir -p "$ROOT"

# a sentinel OUTSIDE the root — an unsafe test_source must never read it.
SENTINEL="$TMP_ROOT/outside_secret.txt"
CANARY="CANARY_DO_NOT_READ_$$"
printf '%s\n' "$CANARY" > "$SENTINEL"

OUTFILE="$TMP_ROOT/.verdict"
# run_judge <root> <claim-file> — writes verdict JSON to $OUTFILE, echoes exit code.
run_judge() {
  local root="$1" claim="$2"
  python3 "$JUDGE" --root "$root" "$claim" > "$OUTFILE" 2>/dev/null
  echo $?
}
verdict_of() { python3 -c 'import sys,json;
d=sys.stdin.read().strip()
print(json.loads(d).get("verdict","(none)") if d else "(empty)")' < "$OUTFILE" 2>/dev/null || echo PARSE_ERR; }
score_of() { python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("score",""))' < "$OUTFILE" 2>/dev/null || echo ""; }
dim_of() { python3 -c 'import sys,json
d=json.load(open(sys.argv[1])).get("dimensions",{}).get("test_meaningfulness",{})
print(d.get(sys.argv[2],""))' "$OUTFILE" "$1" 2>/dev/null || echo ""; }
refutes_contain() { grep -qF "$1" "$OUTFILE"; }

# mk_claim <name> <source-rel-path...> — writes a wrapped claim citing the sources.
mk_claim() {
  local name="$1"; shift
  python3 -c '
import json, sys
srcs = sys.argv[2:]
open(sys.argv[1], "w").write(json.dumps({"claim": {"summary": "judge me", "test_sources": srcs}}))
' "$ROOT/$name" "$@"
}

echo "=== trivially-green forms -> REFUTED (each asserts nothing real) ==="

# (1) echo + exit 0 only — no assertion at all
cat > "$ROOT/t-echo.sh" <<'EOF'
#!/usr/bin/env bash
echo "running the test"
echo "all good"
exit 0
EOF
mk_claim claim-echo.json t-echo.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-echo.json")
[[ $RC -ne 0 ]]; check "echo-exit0-exit-nonzero" $?
[[ "$(verdict_of)" == "REFUTED" ]]; check "echo-exit0-refuted" $?
refutes_contain "t-echo.sh"; check "echo-exit0-names-file" $?

# (2) [[ 1 -eq 1 ]] — constant numeric comparison
cat > "$ROOT/t-const-eq.sh" <<'EOF'
#!/usr/bin/env bash
[[ 1 -eq 1 ]]
EOF
mk_claim claim-const-eq.json t-const-eq.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-const-eq.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "const-1-eq-1-refuted" $?

# (3) [[ 1 == 1 ]]
cat > "$ROOT/t-const-eqeq.sh" <<'EOF'
#!/usr/bin/env bash
[[ 1 == 1 ]]
EOF
mk_claim claim-const-eqeq.json t-const-eqeq.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-const-eqeq.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "const-1-eqeq-1-refuted" $?

# (4) [ 1 = 1 ]
cat > "$ROOT/t-const-single.sh" <<'EOF'
#!/usr/bin/env bash
[ 1 = 1 ]
EOF
mk_claim claim-const-single.json t-const-single.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-const-single.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "const-1-eq-1-single-bracket-refuted" $?

# (5) [[ true ]]
cat > "$ROOT/t-true.sh" <<'EOF'
#!/usr/bin/env bash
[[ true ]]
EOF
mk_claim claim-true.json t-true.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-true.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "const-true-refuted" $?

# (6) python assert True
cat > "$ROOT/t-assert-true.py" <<'EOF'
def test_it():
    assert True
EOF
mk_claim claim-assert-true.json t-assert-true.py
RC=$(run_judge "$ROOT" "$ROOT/claim-assert-true.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "assert-true-refuted" $?

# (7) assertTrue(True)
cat > "$ROOT/t-assert-true-call.py" <<'EOF'
import unittest
class T(unittest.TestCase):
    def test_it(self):
        self.assertTrue(True)
EOF
mk_claim claim-assert-true-call.json t-assert-true-call.py
RC=$(run_judge "$ROOT" "$ROOT/claim-assert-true-call.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "assertTrue-True-refuted" $?

# (8) assert False or True — always-true constant expression
cat > "$ROOT/t-assert-or-true.py" <<'EOF'
def test_it():
    assert False or True
EOF
mk_claim claim-assert-or-true.json t-assert-or-true.py
RC=$(run_judge "$ROOT" "$ROOT/claim-assert-or-true.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "assert-False-or-True-refuted" $?

# (9) : no-op only
cat > "$ROOT/t-noop.sh" <<'EOF'
#!/usr/bin/env bash
:
EOF
mk_claim claim-noop.json t-noop.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-noop.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "noop-colon-refuted" $?

# (10) empty test body
: > "$ROOT/t-empty.sh"
mk_claim claim-empty.json t-empty.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-empty.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "empty-body-refuted" $?

echo
echo "=== meaningful forms -> CONFIRMED (a real, non-constant assertion exists) ==="

# (11) bash [[ "$out" == "expected" ]] || exit 1
cat > "$ROOT/t-cmp-exit.sh" <<'EOF'
#!/usr/bin/env bash
out="$(some_cmd)"
[[ "$out" == "expected" ]] || exit 1
EOF
mk_claim claim-cmp-exit.json t-cmp-exit.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-cmp-exit.json")
[[ $RC -eq 0 ]]; check "cmp-exit-exit-0" $?
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "cmp-exit-confirmed" $?
[[ "$(score_of)" == "1.0" || "$(score_of)" == "1" ]]; check "cmp-exit-score-1" $?

# (12) bash grep -q pattern file
cat > "$ROOT/t-grep.sh" <<'EOF'
#!/usr/bin/env bash
grep -q "expected pattern" output.txt || exit 1
EOF
mk_claim claim-grep.json t-grep.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-grep.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "grep-q-confirmed" $?

# (13) bash check "..." $?  with a real [[ ]]
cat > "$ROOT/t-check.sh" <<'EOF'
#!/usr/bin/env bash
run_thing
[[ "$result" -eq 42 ]]
check "result is 42" $?
EOF
mk_claim claim-check.json t-check.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-check.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "check-dollar-status-confirmed" $?

# (14) python assert func(x) == 3
cat > "$ROOT/t-assert-expr.py" <<'EOF'
from mod import compute
def test_compute():
    assert compute(2) == 3
EOF
mk_claim claim-assert-expr.json t-assert-expr.py
RC=$(run_judge "$ROOT" "$ROOT/claim-assert-expr.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "assert-expr-confirmed" $?

# (15) python self.assertEqual(a, b)
cat > "$ROOT/t-assert-eq.py" <<'EOF'
import unittest
from mod import compute
class T(unittest.TestCase):
    def test_it(self):
        self.assertEqual(compute(2), 4)
EOF
mk_claim claim-assert-eq.json t-assert-eq.py
RC=$(run_judge "$ROOT" "$ROOT/claim-assert-eq.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "assertEqual-confirmed" $?

# (16) python with pytest.raises(ValueError):
cat > "$ROOT/t-raises.py" <<'EOF'
import pytest
from mod import parse
def test_bad_input():
    with pytest.raises(ValueError):
        parse("nope")
EOF
mk_claim claim-raises.json t-raises.py
RC=$(run_judge "$ROOT" "$ROOT/claim-raises.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "pytest-raises-confirmed" $?

echo
echo "=== evidence / safety / interface ==="

# (17) a missing test_source -> REFUTED (missing evidence)
mk_claim claim-missing.json does-not-exist-test.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-missing.json")
[[ $RC -ne 0 ]]; check "missing-source-exit-nonzero" $?
[[ "$(verdict_of)" == "REFUTED" ]]; check "missing-source-refuted" $?
refutes_contain "does-not-exist-test.sh"; check "missing-source-names-path" $?

# (18) unsafe ../ test_source -> REFUTED + NO read/leak outside root
printf '{"claim":{"summary":"escape","test_sources":["../outside_secret.txt"]}}' > "$ROOT/claim-dotdot.json"
RC=$(run_judge "$ROOT" "$ROOT/claim-dotdot.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "unsafe-dotdot-refuted" $?
! refutes_contain "$CANARY"; check "unsafe-dotdot-no-canary-leak" $?
[[ -f "$SENTINEL" ]]; check "unsafe-dotdot-sentinel-intact" $?

# (19) absolute test_source -> REFUTED + no leak
printf '{"claim":{"summary":"abs","test_sources":["%s"]}}' "$SENTINEL" > "$ROOT/claim-abs.json"
RC=$(run_judge "$ROOT" "$ROOT/claim-abs.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "unsafe-absolute-refuted" $?
! refutes_contain "$CANARY"; check "unsafe-absolute-no-canary-leak" $?

# (20) empty test_sources -> REFUTED (nothing to judge)
printf '{"claim":{"summary":"nothing","test_sources":[]}}' > "$ROOT/claim-none.json"
RC=$(run_judge "$ROOT" "$ROOT/claim-none.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "empty-test_sources-refuted" $?
refutes_contain "no test_sources"; check "empty-test_sources-explains" $?

# (21) BARE claim (no {"claim":{}} wrapper) is accepted
printf '{"summary":"bare form","test_sources":["t-grep.sh"]}' > "$ROOT/claim-bare.json"
RC=$(run_judge "$ROOT" "$ROOT/claim-bare.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "bare-claim-accepted" $?

# (22) WRAPPED {"claim":{}} is accepted (all other cases use it; assert explicitly)
printf '{"claim":{"summary":"wrapped form","test_sources":["t-grep.sh"]}}' > "$ROOT/claim-wrapped.json"
RC=$(run_judge "$ROOT" "$ROOT/claim-wrapped.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "wrapped-claim-accepted" $?

# (23) malformed claim -> REFUTED, fail-safe (no crash)
printf '%s' '{ this is: not json ]' > "$ROOT/claim-bad.json"
RC=$(run_judge "$ROOT" "$ROOT/claim-bad.json")
[[ $RC -ne 0 ]]; check "malformed-exit-nonzero" $?
[[ "$(verdict_of)" == "REFUTED" ]]; check "malformed-refuted-not-crash" $?

# (24) a file with BOTH a trivial AND a real assertion -> CONFIRMED (real wins)
cat > "$ROOT/t-mixed.py" <<'EOF'
def test_it():
    assert True                 # trivial, green-by-construction
    assert compute(2) == 4      # real
EOF
mk_claim claim-mixed.json t-mixed.py
RC=$(run_judge "$ROOT" "$ROOT/claim-mixed.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "trivial-plus-real-confirmed" $?

# (25) partial: one meaningful + one trivial source -> REFUTED, dims passed=1 total=2
mk_claim claim-partial.json t-grep.sh t-const-eq.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-partial.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "partial-refuted" $?
[[ "$(dim_of passed)" == "1" ]]; check "partial-dims-passed-1" $?
[[ "$(dim_of total)" == "2" ]]; check "partial-dims-total-2" $?

# (26) CONFIRMED case reports passed == total
mk_claim claim-full.json t-grep.sh t-cmp-exit.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-full.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "all-meaningful-confirmed" $?
[[ "$(dim_of passed)" == "2" && "$(dim_of total)" == "2" ]]; check "all-meaningful-passed-eq-total" $?

# (27) verdict carries the shared-convention schema keys
python3 -c '
import sys, json
d = json.load(open(sys.argv[1]))
need = ["verdict", "score", "target", "dimensions", "refutations", "schema_version"]
sys.exit(0 if all(k in d for k in need) else 1)
' "$OUTFILE"
check "schema-keys-present" $?

# (28) an assertion-looking line inside an echo/print string must NOT confirm
#      (a printed "assert x == y" is illustrative text, not an executed assertion)
cat > "$ROOT/t-printed-assert.sh" <<'EOF'
#!/usr/bin/env bash
echo "assert result == expected"
printf 'grep -q needle file\n'
exit 0
EOF
mk_claim claim-printed.json t-printed-assert.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-printed.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "printed-assertion-text-refuted" $?

# (29) python literal-vs-literal comparison -> REFUTED. Both operands are constants,
#      so it tests nothing about the code — parity with the bash `[[ 1 -eq 1 ]]` tell.
#      (regression lock: reference-judge round-2 review found _REAL over-matched these.)
cat > "$ROOT/t-const-py-num.py" <<'EOF'
def test_it():
    assert 1 == 1
EOF
mk_claim claim-const-py-num.json t-const-py-num.py
RC=$(run_judge "$ROOT" "$ROOT/claim-const-py-num.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "const-py-numeric-refuted" $?

cat > "$ROOT/t-const-py-str.py" <<'EOF'
def test_it():
    assert "x" == "x"
EOF
mk_claim claim-const-py-str.json t-const-py-str.py
RC=$(run_judge "$ROOT" "$ROOT/claim-const-py-str.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "const-py-string-refuted" $?

cat > "$ROOT/t-const-py-distinct.py" <<'EOF'
def test_it():
    assert 2 == 3
EOF
mk_claim claim-const-py-distinct.json t-const-py-distinct.py
RC=$(run_judge "$ROOT" "$ROOT/claim-const-py-distinct.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "const-py-distinct-refuted" $?

# (30) a SYMLINKED test_source resolving OUTSIDE --root -> REFUTED, path rejected
#      (never read). _safe_rel is lexical; realpath containment must refuse it. The
#      symlink points at an outside file that HOLDS A REAL ASSERTION, so a REFUTED
#      verdict is only reachable by rejection — a read would have CONFIRMED.
OUTSIDE_REAL="$TMP_ROOT/outside_real.sh"
printf '%s\n' '[[ "$x" == "$y" ]] || exit 1' > "$OUTSIDE_REAL"
ln -s "$OUTSIDE_REAL" "$ROOT/t-symlink.sh"
mk_claim claim-symlink.json t-symlink.sh
RC=$(run_judge "$ROOT" "$ROOT/claim-symlink.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "symlink-escape-refuted" $?
refutes_contain "escapes --root"; check "symlink-escape-rejected-not-read" $?

# (31) widened python constant-comparison forms -> REFUTED. The first fix only
#      covered decimal literals with a `,`/`#`/EOL terminator; these genuinely-hollow
#      forms slipped through (round-3 review): non-decimal number syntax (hex,
#      `_` separators, exponent), a trailing `;`, and a chained comparison. 5 checks.
for cexpr in 'assert 1 == 1;' 'assert 0x1F == 31' 'assert 1_000 == 1000' 'assert 1e3 == 1000' 'assert 1 == 1 == 1'; do
  printf 'def test_it():\n    %s\n' "$cexpr" > "$ROOT/t-widen.py"
  mk_claim claim-widen.json t-widen.py
  RC=$(run_judge "$ROOT" "$ROOT/claim-widen.json")
  [[ "$(verdict_of)" == "REFUTED" ]]; check "widened-const-py [$cexpr]" $?
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
