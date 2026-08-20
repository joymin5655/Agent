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
# --require-evidence / --diff-base (P1 grounded-completion-gate) contract:
#   (r1) no flags                     -> output identical to pre-flag behavior (regression)
#   (r2) --require-evidence + code diff + tests=0 -> REFUTED, `evidence` dim fails
#   (r3) same + tests=1 passing       -> CONFIRMED, `evidence` dim passes
#   (r4) doc-only diff                -> no evidence refutation
#   (r5) --diff-base, +@pytest.mark.skip -> REFUTED (trajectory)
#   (r6) --diff-base, +it.only(       -> REFUTED (trajectory)
#   (r7) pre-existing (context) skip line -> NOT detected (only `+` lines scanned)
#   (r8) changed code file outside claim's files/scope -> REFUTED; lockfile exempt
#   (r9) nested dist/build dirs (e.g. src/dist/real.py) NOT exempt; root-only dist/ still is
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
echo "=== (l) a present-but-non-list section -> REFUTED (not silently dropped) ==="
# files all pass, but `tests` is a string, not a list. It must REFUTE the whole
# claim (a malformed section can't be dropped so the rest CONFIRMs).
cat > "$PROJ/claim-badsection.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "tests": "false" } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-badsection.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "non-list-section-refuted" $?
refutes_contain "must be a list"; check "non-list-section-explains" $?

echo
echo "=== (m) files-as-string (a whole section malformed) -> REFUTED ==="
# the review's MAJOR repro: a non-list `files` must not be silently dropped while
# a trivial passing test confirms the claim.
cat > "$PROJ/claim-filesstr.json" <<'EOF'
{ "claim": { "summary": "x", "files": "important.py", "tests": [ "true" ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-filesstr.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "files-as-string-refuted" $?

echo
echo "=== (n) bare-string file entry -> exercises the string-form branch ==="
cat > "$PROJ/claim-barepath.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ "src/mod.py" ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-barepath.json")
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "bare-string-file-confirmed" $?

echo
echo "=== (o) --root defaults to CWD when omitted ==="
( cd "$PROJ" && python3 "$VERIFY" claim-ok.json ) > "$OUTFILE" 2>/dev/null
RCO=$?
[[ $RCO -eq 0 && "$(verdict_of)" == "CONFIRMED" ]]; check "root-defaults-to-cwd" $?

echo
echo "=== (p) non-numeric AGENT_VERIFY_CMD_TIMEOUT -> degrades, no crash ==="
env AGENT_VERIFY_CMD_TIMEOUT=2m python3 "$VERIFY" --root "$PROJ" "$PROJ/claim-ok.json" > "$OUTFILE" 2>/dev/null
RCP=$?
[[ $RCP -eq 0 && "$(verdict_of)" == "CONFIRMED" ]]; check "badtimeout-degrades" $?

echo
echo "=== (q) partial score (0<score<1) on a mixed claim ==="
cat > "$PROJ/claim-partial.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "tests": [ "false" ] } }
EOF
RC=$(run_verify "$PROJ" "$PROJ/claim-partial.json")
[[ "$(verdict_of)" == "REFUTED" ]]; check "partial-refuted" $?
[[ "$(score_of)" == "0.5" ]]; check "partial-score-half" $?

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
echo "=== (r1) no flags -> output identical to pre-flag behavior (regression) ==="
RC=$(run_verify "$PROJ" "$PROJ/claim-ok.json")
[[ $RC -eq 0 ]]; check "noflags-exit-0" $?
[[ "$(verdict_of)" == "CONFIRMED" ]]; check "noflags-confirmed" $?
python3 -c '
import sys, json
d = json.load(open(sys.argv[1]))
sys.exit(0 if "evidence" not in d["dimensions"] and "trajectory" not in d["dimensions"] else 1)
' "$OUTFILE"
check "noflags-no-new-dimensions" $?

# --- git-backed fixture for --require-evidence / --diff-base ---
if ! command -v git >/dev/null 2>&1; then
  echo "  skip [require-evidence/diff-base] git not available"
else
  GPROJ="$TMP_ROOT/gitproj"
  mkdir -p "$GPROJ/src"
  ( cd "$GPROJ" && git init -q && git config user.email t@t.com && git config user.name t )
  printf 'def foo():\n    return 1\n\n# @pytest.mark.skip pre-existing context line — must NOT trigger\n' > "$GPROJ/src/mod.py"
  printf '# doc\n' > "$GPROJ/README.md"
  ( cd "$GPROJ" && git add -A && git commit -qm init )
  BASE="$(cd "$GPROJ" && git rev-parse HEAD)"

  run_verify_flags() { # <root> <claim> <extra flags...>
    local root="$1" claim="$2"; shift 2
    python3 "$VERIFY" --root "$root" "$@" "$claim" > "$OUTFILE" 2>/dev/null
    echo $?
  }

  echo
  echo "=== (r2) --require-evidence: code changed, tests+assertions=0 -> REFUTED ==="
  printf 'def foo():\n    return 2\n\n# @pytest.mark.skip pre-existing context line — must NOT trigger\n' > "$GPROJ/src/mod.py"
  cat > "$GPROJ/claim-ev.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ] } }
EOF
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-ev.json" --require-evidence)
  [[ $RC -ne 0 ]]; check "evidence-code-notests-refuted-exit" $?
  [[ "$(verdict_of)" == "REFUTED" ]]; check "evidence-code-notests-refuted" $?
  refutes_contain "cites no runnable evidence"; check "evidence-refutation-names-reason" $?

  echo
  echo "=== (r3) --require-evidence: same + a passing test -> CONFIRMED ==="
  cat > "$GPROJ/claim-ev2.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "tests": [ "true" ] } }
EOF
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-ev2.json" --require-evidence)
  [[ $RC -eq 0 ]]; check "evidence-with-test-confirmed-exit" $?
  [[ "$(verdict_of)" == "CONFIRMED" ]]; check "evidence-with-test-confirmed" $?

  echo
  echo "=== (r4) --require-evidence: doc-only diff -> no evidence refutation ==="
  ( cd "$GPROJ" && git checkout -q -- src/mod.py )
  printf '# doc changed\n' > "$GPROJ/README.md"
  cat > "$GPROJ/claim-doc.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "README.md" } ] } }
EOF
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-doc.json" --require-evidence)
  [[ "$(verdict_of)" == "CONFIRMED" ]]; check "evidence-doconly-confirmed" $?
  refutes_contain "cites no runnable evidence"; NOT_FOUND=$?
  [[ $NOT_FOUND -ne 0 ]]; check "evidence-doconly-no-refutation" $?
  ( cd "$GPROJ" && git checkout -q -- README.md )

  echo
  echo "=== (r5) --diff-base: added @pytest.mark.skip -> REFUTED (trajectory) ==="
  printf 'def foo():\n    return 1\n\n# @pytest.mark.skip pre-existing context line — must NOT trigger\n\n@pytest.mark.skip\ndef test_new(): pass\n' > "$GPROJ/src/mod.py"
  cat > "$GPROJ/claim-traj.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ] } }
EOF
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-traj.json" --diff-base "$BASE")
  [[ $RC -ne 0 ]]; check "traj-skip-refuted-exit" $?
  [[ "$(verdict_of)" == "REFUTED" ]]; check "traj-skip-refuted" $?
  refutes_contain "pytest skip marker"; check "traj-skip-refutation-names-marker" $?
  ( cd "$GPROJ" && git checkout -q -- src/mod.py )

  echo
  echo "=== (r6) --diff-base: added it.only( -> REFUTED (trajectory) ==="
  printf 'def foo():\n    return 1\n\n# @pytest.mark.skip pre-existing context line — must NOT trigger\n' > "$GPROJ/src/mod.py"
  printf 'it.only("x", () => {})\n' >> "$GPROJ/src/mod.py"
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-traj.json" --diff-base "$BASE")
  [[ "$(verdict_of)" == "REFUTED" ]]; check "traj-itonly-refuted" $?
  refutes_contain "it.only("; check "traj-itonly-refutation-names-marker" $?
  ( cd "$GPROJ" && git checkout -q -- src/mod.py )

  echo
  echo "=== (r7) pre-existing (context) skip line -> NOT detected (only + lines scanned) ==="
  # src/mod.py already carries the pre-existing skip comment from init; a diff
  # that does not touch that line must not refute on it.
  printf 'def foo():\n    return 99\n\n# @pytest.mark.skip pre-existing context line — must NOT trigger\n' > "$GPROJ/src/mod.py"
  cat > "$GPROJ/claim-traj2.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "tests": [ "true" ] } }
EOF
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-traj2.json" --diff-base "$BASE")
  [[ "$(verdict_of)" == "CONFIRMED" ]]; check "traj-context-skip-not-detected" $?
  ( cd "$GPROJ" && git checkout -q -- src/mod.py )

  echo
  echo "=== (r8) changed code file outside claim scope -> REFUTED; lockfile exempt ==="
  printf 'x = 1\n' > "$GPROJ/src/other.py"
  printf '{"lockfileVersion": 1}\n' > "$GPROJ/package-lock.json"
  ( cd "$GPROJ" && git add -A )
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-traj2.json" --diff-base "$BASE")
  [[ "$(verdict_of)" == "REFUTED" ]]; check "traj-outofscope-refuted" $?
  refutes_contain "changed outside claimed scope: src/other.py"; check "traj-outofscope-names-path" $?
  refutes_contain "package-lock.json"; LOCKFILE_NAMED=$?
  [[ $LOCKFILE_NAMED -ne 0 ]]; check "traj-lockfile-exempt" $?
  ( cd "$GPROJ" && git reset -q --hard "$BASE" )

  echo
  echo "=== (r9) NESTED dist/build dirs are NOT exempt (repo-root anchored only) ==="
  # src/dist/real.py is a real source file that happens to sit under a
  # directory named 'dist' — it must NOT ride the build-artifact exemption
  # (review Major finding: the old (^|/)dist/ pattern matched mid-path too).
  # Recreate claim-traj2.json fresh: r8's `git add -A` + `git reset --hard`
  # swept it away (it was an untracked claim file living in the repo dir,
  # staged then reverted along with the rest of that reset).
  cat > "$GPROJ/claim-traj2.json" <<'EOF'
{ "claim": { "summary": "x", "files": [ { "path": "src/mod.py" } ], "tests": [ "true" ] } }
EOF
  mkdir -p "$GPROJ/src/dist" "$GPROJ/dist"
  printf 'y = 1\n' > "$GPROJ/src/dist/real.py"
  printf 'bundled\n' > "$GPROJ/dist/bundle.js"
  ( cd "$GPROJ" && git add -A )
  RC=$(run_verify_flags "$GPROJ" "$GPROJ/claim-traj2.json" --diff-base "$BASE")
  [[ "$(verdict_of)" == "REFUTED" ]]; check "traj-nested-dist-refuted" $?
  refutes_contain "changed outside claimed scope: src/dist/real.py"; check "traj-nested-dist-not-exempt" $?
  refutes_contain "dist/bundle.js"; NESTED_BUNDLE_NAMED=$?
  [[ $NESTED_BUNDLE_NAMED -ne 0 ]]; check "traj-root-dist-still-exempt" $?
  ( cd "$GPROJ" && git reset -q --hard "$BASE" )
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
