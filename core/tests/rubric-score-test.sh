#!/usr/bin/env bash
# rubric-score-test.sh — hermetic battery for the project-rubric scorer (core/infra/
# rubric-score.py) and the per-commit advisory hook (core/hooks/rubric-commit-judge.sh).
#
# Core cases use JSON rubrics so they run with no PyYAML dependency (CI-safe); one
# case exercises the YAML path only when PyYAML is importable. Asserts the shared
# verdict schema (docs/scoring-convention.md) and refute-by-default semantics:
#   - a checkable dimension whose grader_check fails => REFUTED, named
#   - a rubric with no checkable dimension => REFUTED "nothing to score"
#   - a missing / malformed rubric => REFUTED, never a crash
#   - CONFIRMED only when >=1 dimension was checked and none refuted
# The hook smoke test proves it appends a verdict line on `git commit` and is inert
# on a non-commit command — advisory, never blocking.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCORER="$REPO_ROOT/core/infra/rubric-score.py"
HOOK="$REPO_ROOT/core/hooks/rubric-commit-judge.sh"

PASS=0; FAIL=0
check() { # <name> <cond-rc>
  if [[ "$2" -eq 0 ]]; then echo "  ok   [$1]"; PASS=$((PASS + 1))
  else echo "  FAIL [$1]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
fresh() { mktemp -d "$TMP_ROOT/tXXXXXX"; }

# run <rubric-file> [extra args] -> sets OUT (stdout json) and RC (exit code)
OUT=""; RC=0
run() { OUT="$(python3 "$SCORER" --rubric "$1" "${@:2}" 2>/dev/null)"; RC=$?; }
# field <key> — read a top-level key from $OUT
field() { printf '%s' "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin).get(sys.argv[1]))' "$1" 2>/dev/null; }
# refut_has <substr> — exit 0 iff any refutation contains <substr>
refut_has() { printf '%s' "$OUT" | python3 -c 'import sys,json
d=json.load(sys.stdin); sub=sys.argv[1]
sys.exit(0 if any(sub in r for r in d.get("refutations",[])) else 1)' "$1"; }

echo "=== (a) all grader_checks pass -> CONFIRMED, score 1.0 ==="
T=$(fresh)
cat > "$T/r.json" <<'JSON'
{"target":"demo","dimensions":[
  {"id":"correctness","grader_check":"true","weight":2},
  {"id":"coverage","grader_check":"true","weight":1}]}
JSON
run "$T/r.json"
[[ "$(field verdict)" == "CONFIRMED" ]]; check "a-confirmed" $?
[[ "$(field score)" == "1.0" ]]; check "a-score-1.0" $?
[[ "$RC" -eq 0 ]]; check "a-exit-0" $?

echo "=== (b) a failing grader_check -> REFUTED + names the dim ==="
T=$(fresh)
cat > "$T/r.json" <<'JSON'
{"target":"demo","dimensions":[
  {"id":"correctness","grader_check":"true"},
  {"id":"coverage","grader_check":"false"}]}
JSON
run "$T/r.json"
[[ "$(field verdict)" == "REFUTED" ]]; check "b-refuted" $?
refut_has "coverage"; check "b-names-failing-dim" $?
[[ "$RC" -eq 1 ]]; check "b-exit-1" $?

echo "=== (c) only a semantic-only dim (null check) -> REFUTED 'nothing to score' ==="
T=$(fresh)
cat > "$T/r.json" <<'JSON'
{"target":"demo","dimensions":[{"id":"clarity","grader_check":null}]}
JSON
run "$T/r.json"
[[ "$(field verdict)" == "REFUTED" ]]; check "c-refuted" $?
refut_has "nothing to score"; check "c-nothing-to-score" $?

echo "=== (d) missing rubric file -> REFUTED 'no rubric file' ==="
run "$TMP_ROOT/does-not-exist.yml"
[[ "$(field verdict)" == "REFUTED" ]]; check "d-refuted" $?
refut_has "no rubric file"; check "d-no-rubric-file" $?

echo "=== (e) malformed rubric (dimensions not a list) -> REFUTED 'unscorable' ==="
T=$(fresh)
printf '%s\n' '{"dimensions": "nope"}' > "$T/r.json"
run "$T/r.json"
[[ "$(field verdict)" == "REFUTED" ]]; check "e-refuted" $?
refut_has "unscorable"; check "e-unscorable" $?

echo "=== (f) weighting: pass(3) + fail(1) -> score 0.75, REFUTED ==="
T=$(fresh)
cat > "$T/r.json" <<'JSON'
{"dimensions":[
  {"id":"big","grader_check":"true","weight":3},
  {"id":"small","grader_check":"false","weight":1}]}
JSON
run "$T/r.json"
[[ "$(field score)" == "0.75" ]]; check "f-weighted-score" $?
[[ "$(field verdict)" == "REFUTED" ]]; check "f-refuted" $?

echo "=== (g) YAML path (only when PyYAML importable) ==="
if python3 -c 'import yaml' 2>/dev/null; then
  T=$(fresh)
  cat > "$T/r.yml" <<'YAML'
target: demo
dimensions:
  - id: correctness
    grader_check: "true"
YAML
  run "$T/r.yml"
  [[ "$(field verdict)" == "CONFIRMED" ]]; check "g-yaml-confirmed" $?
else
  echo "  skip [g-yaml] — PyYAML not importable"
fi

echo "=== (h) hook in PERSONAL tier: grader_check runs (sentinel) + verdict logged; non-commit inert ==="
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  EV='{"event":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
  G=$(fresh)
  ( cd "$G" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$G/.agent"
  printf '{"dimensions":[{"id":"exec","grader_check":"touch %s/ran.sentinel"}]}\n' "$G" > "$G/.agent/rubric.yml"
  TL="$G/trust.list"; printf 'path %s\n' "$G" > "$TL"   # grant personal tier to this path
  ( cd "$G" && printf '%s' "$EV" | AGENT_TRUST_FILE="$TL" bash "$HOOK" ) >/dev/null 2>&1
  [[ -f "$G/ran.sentinel" ]]; check "h-personal-grader-ran" $?
  [[ -f "$G/.agent/logs/rubric-score.jsonl" ]]; check "h-personal-log" $?
  before=$(wc -l < "$G/.agent/logs/rubric-score.jsonl" 2>/dev/null | tr -d ' ')
  NONCOMMIT='{"event":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
  ( cd "$G" && printf '%s' "$NONCOMMIT" | AGENT_TRUST_FILE="$TL" bash "$HOOK" ) >/dev/null 2>&1
  after=$(wc -l < "$G/.agent/logs/rubric-score.jsonl" 2>/dev/null | tr -d ' ')
  [[ "$before" == "$after" ]]; check "h-noncommit-inert" $?

  echo "=== (m) TRUST GATE — collab tier: grader_check must NOT execute (silent-RCE guard) ==="
  C=$(fresh)
  ( cd "$C" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$C/.agent"
  printf '{"dimensions":[{"id":"exec","grader_check":"touch %s/PWNED"}]}\n' "$C" > "$C/.agent/rubric.yml"
  ETL="$C/empty.list"; : > "$ETL"   # empty trust list -> fail-closed to collab
  ( cd "$C" && printf '%s' "$EV" | AGENT_TRUST_FILE="$ETL" bash "$HOOK" ) >/dev/null 2>&1
  [[ ! -f "$C/PWNED" ]]; check "m-collab-no-exec" $?
  grep -q 'not auto-run' "$C/.agent/logs/rubric-score.jsonl" 2>/dev/null; check "m-collab-skip-noted" $?
else
  echo "  skip [h/m-hook] — git or jq not available"
fi

echo "=== (i) hook file is executable — adapters/*/adapter.sh FAIL-OPENS (exit 0) on a non-x hook, ==="
echo "===     so a lost +x bit silently disables the whole feature; bash \$HOOK can't catch it ==="
[[ -x "$HOOK" ]]; check "i-hook-executable" $?

echo "=== (j) duplicate dimension id -> both kept in the verdict (no silent overwrite) ==="
T=$(fresh)
cat > "$T/r.json" <<'JSON'
{"dimensions":[
  {"id":"correctness","grader_check":"true","weight":3},
  {"id":"correctness","grader_check":"false","weight":1}]}
JSON
run "$T/r.json"
ndims() { printf '%s' "$OUT" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("dimensions",{})))' 2>/dev/null; }
[[ "$(ndims)" == "2" ]]; check "j-both-dims-kept" $?
[[ "$(field score)" == "0.75" ]]; check "j-score-correct" $?

echo "=== (j2) synthesized 'id#n' must not clobber a literal later id -> all 3 kept ==="
T=$(fresh)
cat > "$T/r.json" <<'JSON'
{"dimensions":[
  {"id":"x#2","grader_check":"true"},
  {"id":"x","grader_check":"true"},
  {"id":"x","grader_check":"false"}]}
JSON
run "$T/r.json"
[[ "$(ndims)" == "3" ]]; check "j2-no-synth-collision" $?

echo "=== (k) weight <= 0 coerces to 1.0 (documented) -> still counts toward score ==="
T=$(fresh)
printf '%s\n' '{"dimensions":[{"id":"x","grader_check":"true","weight":0}]}' > "$T/r.json"
run "$T/r.json"
[[ "$(field verdict)" == "CONFIRMED" ]]; check "k-weight0-confirmed" $?
[[ "$(field score)" == "1.0" ]]; check "k-weight0-score" $?

echo "=== (l) aggregate total-budget cap stops further checks (refute the remainder) ==="
T=$(fresh)
cat > "$T/r.json" <<'JSON'
{"dimensions":[{"id":"slow","grader_check":"sleep 2"},{"id":"after","grader_check":"true"}]}
JSON
OUT="$(AGENT_RUBRIC_TOTAL_TIMEOUT=1 python3 "$SCORER" --rubric "$T/r.json" 2>/dev/null)"
refut_has "total budget"; check "l-budget-cap" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
