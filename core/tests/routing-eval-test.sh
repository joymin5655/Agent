#!/usr/bin/env bash
# routing-eval-test.sh — the deterministic skill-routing eval (evals/routing) passes its
# floors on the repo skills, and is load-bearing: it fails on a lint violation, on an
# impossible floor, and on a collision-threshold breach; the JSON output is parseable.
# shellcheck disable=SC2319  # `[[ ]]; check $?` is the battery idiom (see evals-test.sh)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/evals/routing/run_routing_eval.py"

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

echo "=== (a) repo skills clear the committed floors ==="
run --min-rank1 65 --min-top3 70 --max-negative-violations 4
[[ $RC -eq 0 ]]; check "repo-floors-pass" $?
printf '%s' "$OUT" | grep -q 'ROUTING EVAL PASS'; check "emits-pass" $?

echo "=== (b) an impossible floor fails ==="
run --min-rank1 100
[[ $RC -ne 0 ]]; check "floor-breach-exits-nonzero" $?
printf '%s' "$OUT" | grep -q 'ROUTING EVAL FAIL'; check "emits-fail" $?

echo "=== (c) lint catches a bad skill (name mismatch, no description, >500 lines) ==="
mkdir -p "$TMP/skills/alpha" "$TMP/skills/beta"
printf -- '---\nname: wrong\ndescription: Does alpha things.\n---\n# alpha\n' > "$TMP/skills/alpha/SKILL.md"
{ printf -- '---\nname: beta\n---\n'; for _ in $(seq 1 510); do echo line; done; } > "$TMP/skills/beta/SKILL.md"
printf '%s\n' '{"cases":[]}' > "$TMP/cases.json"
run --skills-dir "$TMP/skills" --cases "$TMP/cases.json"
[[ $RC -ne 0 ]]; check "lint-error-fails" $?
printf '%s' "$OUT" | grep -q "does not match directory"; check "lint-name-mismatch" $?
printf '%s' "$OUT" | grep -q "description missing"; check "lint-missing-description" $?
printf '%s' "$OUT" | grep -q "lines > 500"; check "lint-too-long" $?

echo "=== (d) identical descriptions are flagged as a near-collision ==="
mkdir -p "$TMP/c/one" "$TMP/c/two"
for n in one two; do
  printf -- '---\nname: %s\ndescription: Rotates the deployment credentials for staging clusters nightly.\n---\n# x\n' "$n" > "$TMP/c/$n/SKILL.md"
done
run --skills-dir "$TMP/c" --cases "$TMP/cases.json"
printf '%s' "$OUT" | grep -q 'one <-> two'; check "collision-listed" $?

echo "=== (e) --json is valid and carries the metrics ==="
run --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "rank1_pct" in d and "collisions" in d'; check "json-valid" $?

echo
echo "routing-eval-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
