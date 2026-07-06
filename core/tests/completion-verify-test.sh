#!/usr/bin/env bash
# completion-verify-test.sh — verify P3-5: the independent completion-claim
# verifier core, core/infra/completion-verify.py.
#
# A completion CLAIM (`.agent/claims/<slug>.yml|json`, or any path) declares what
# a task asserts it accomplished:
#     claim:
#       summary: "..."
#       files:        # each must exist (optional `contains:` substring)
#         - { path: "core/x.py", contains: "def foo" }
#       tests:        # each command must exit 0
#         - "bash core/tests/x-test.sh"
#       assertions:   # each command must exit 0 (mechanical claim<->artifact check)
#         - "grep -q needle core/x.py"
#
# The verifier re-checks the claim in a SEPARATE context (deterministic layer of
# the builder-validator pattern) and emits a shared-convention verdict JSON:
#     { "verdict": "CONFIRMED"|"REFUTED", "score": 0.0-1.0, "target": "...",
#       "dimensions": { "files": {"passed":N,"total":M}, ... },
#       "refutations": [ "<what failed>", ... ], "schema_version": "1.0.0" }
# Exit 0 iff CONFIRMED; exit 1 otherwise (usable as a CI/wave GATE). Refute-by-
# default: anything unverifiable/malformed/empty resolves to REFUTED, never a
# crash.
#
# Contract covered:
#   (a) consistent claim              -> CONFIRMED, exit 0, score 1.0
#   (b) cites a non-existent file     -> REFUTED, refutation names the path
#   (c) file exists, `contains` absent -> REFUTED
#   (d) a cited test fails             -> REFUTED, refutation names the test
#   (e) a cited assertion fails        -> REFUTED
#   (f) malformed claim               -> REFUTED, fail-safe (no crash)
#   (g) nothing to verify             -> REFUTED (refute-by-default)
#   (h) YAML claim path               -> works (skipped if no PyYAML)
#   (i) process-group-signalling test -> verifier survives, still emits a verdict
#   (j) verdict carries the shared-convention schema keys
#
# Usage: bash core/tests/completion-verify-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$REPO_ROOT/core/infra/completion-verify.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# run_verify <root> <claim-file> — writes verdict JSON to $OUTFILE, echoes exit code.
OUTFILE="$TMP_ROOT/.verdict"
run_verify() {
  local root="$1" claim="$2"
  python3 "$VERIFY" --root "$root" "$claim" > "$OUTFILE" 2>/dev/null
  echo $?
}
verdict_of() { python3 -c 'import sys,json;
d=sys.stdin.read().strip()
print(json.loads(d).get("verdict","(none)") if d else "(empty)")' < "$OUTFILE" 2>/dev/null || echo PARSE_ERR; }
score_of() { python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("score",""))' < "$OUTFILE" 2>/dev/null || echo ""; }
refutes_contain() { grep -qF "$1" "$OUTFILE"; }

# a project root with a couple of real artifacts to cite
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/src"
printf 'def foo():\n    return 42\n' > "$PROJ/src/mod.py"

echo "=== (a) consistent claim -> CONFIRMED, exit 0, score 1.0 ==="
cat > "$PROJ/claim-ok.json" <<'EOF'
{ "claim": {
  "summary": "added foo",
  "files": [ { "path": "src/mod.py", "contains": "def foo" } ],
  "tests": [ "true" ],
  "assertions": [ "grep -q 'return 42' src/mod.py" ]
} }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-ok.json")
[[ $RC -eq 0 ]]; check "consistent-exit-0" $?
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "consistent-confirmed" $?
[[ "$(score_of)" == "1.0" || "$(score_of)" == "1" ]]; check "consistent-score-1" $?

echo
echo "=== (b) cites non-existent file -> REFUTED ==="
cat > "$PROJ/claim-missing.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/ghost.py" } ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-missing.json")
[[ $RC -ne 0 ]]; check "missing-file-exit-nonzero" $?
[[ "$(verdict_of)" == "REFUTED" ]]; check "missing-file-refuted" $?
refutes_contain "ghost.py"; check "missing-file-refutation-names-path" $?

echo
echo "=== (c) file exists but 'contains' substring absent -> REFUTED ==="
cat > "$PROJ/claim-contains.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py", "contains": "class Bar" } ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-contains.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "contains-absent-refuted" $?

echo
echo "=== (d) a cited test fails -> REFUTED ==="
cat > "$PROJ/claim-test.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "tests": [ "false" ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-test.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "failing-test-refuted" $?

echo
echo "=== (e) a cited assertion fails -> REFUTED ==="
cat > "$PROJ/claim-assert.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "assertions": [ "grep -q nonexistent src/mod.py" ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-assert.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "failing-assertion-refuted" $?

echo
echo "=== (f) malformed claim -> REFUTED, fail-safe (no crash) ==="
printf '%s' '{ this is: not json ]' > "$PROJ/claim-bad.json"
RC=$(run_verify "$PROJ" "$PROJ/claim-bad.json")
[[ $RC -ne 0 ]]; check "malformed-exit-nonzero" $?
[[ "$(verdict_of)" == "REFUTED" ]]; check "malformed-refuted-not-crash" $?

echo
echo "=== (g) nothing to verify -> REFUTED (refute-by-default) ==="
cat > "$PROJ/claim-empty.json" <<'EOF'
{ "claim": { "summary": "did stuff, trust me" } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-empty.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "nothing-to-verify-refuted" $?

echo
echo "=== (h) YAML claim path -> works ==="
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "  skip [yaml-path] PyYAML not importable — .yml is optional"
else
  cat > "$PROJ/claim.yml" <<'EOF'
claim:
  summary: yaml ok
  files:
    - path: src/mod.py
      contains: "def foo"
EOF
  RC=$(run_verify "$PROJ" "$PROJ/claim.yml")
  [[ "$(verdict_of)" == "CONFIRMED" ]]; check "yaml-claim-confirmed" $?
fi

echo
echo "=== (i) process-group-signalling test -> verifier survives, emits verdict ==="
cat > "$PROJ/claim-kill.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "tests": [ "kill 0" ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-kill.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "group-signal-verifier-survives" $?

echo
echo "=== (k) over-cap claim -> REFUTED (padding can't hide items past the bound) ==="
# 21 all-passing tests exceeds the 20 cap; without the truncation refutation this
# would falsely CONFIRM, letting a claim hide a failing item past index 20.
python3 -c '
import json, sys
tests = ["true"] * 21
open(sys.argv[1], "w").write(json.dumps({"claim": {"summary": "padded",
  "files": [{"path": "src/mod.py"}], "tests": tests}}))
' "$PROJ/claim-overcap.json"
RC=$(run_verify "$PROJ" "$PROJ/claim-overcap.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "over-cap-refuted" $?
refutes_contain "exceeds"; check "over-cap-refutation-explains" $?

echo
echo "=== (j) verdict carries the shared-convention schema keys ==="
python3 -c '
import sys, json
d = json.load(open(sys.argv[1]))
need = ["verdict", "score", "target", "dimensions", "refutations", "schema_version"]
sys.exit(0 if all(k in d for k in need) else 1)
' "$OUTFILE"
check "schema-keys-present" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
