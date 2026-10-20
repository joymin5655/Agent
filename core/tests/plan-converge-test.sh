#!/usr/bin/env bash
# plan-converge-test.sh — core/infra/plan-converge.sh turns a verdict's gaps into
# one lint-clean `## Wave N: converge k`, stops on converged / cap / no progress /
# --spec-change, and never touches spec.md or a plan it did not extend.
#
# Each case gets a FRESH fixture (mktemp -d). Fixtures carry the Decisions,
# Must not and Edge cases sections so they lint clean with or without the
# stricter plan-lint rules.
#
# Usage: bash core/tests/plan-converge-test.sh
# shellcheck disable=SC2016
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONVERGE="$REPO_ROOT/core/infra/plan-converge.sh"
LINT="$REPO_ROOT/core/infra/plan-lint.sh"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

new_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  mkdir -p "$fx/demo"
  cat > "$fx/demo/plan.md" <<'PLAN'
# demo — plan

## Wave 1: build
- Write the widget → verify: `bash core/tests/widget-test.sh`
- Document it → verify: `grep -q widget README.md`
PLAN
  cat > "$fx/demo/spec.md" <<'SPEC'
# demo — spec

## Decisions
- none (fixture)

## Must not
- none — fixture

## Edge cases
- none — fixture

## Success criteria
- `widget-test.sh` passes.
SPEC
  printf '%s' "$fx/demo"
}

# verdict <file> <verdict> <refutation>... — write a verdict-schema JSON
verdict() {
  local f="$1" v="$2"; shift 2
  python3 -I - "$f" "$v" "$@" <<'PY'
import json, sys
json.dump({"verdict": sys.argv[2], "score": 0.5, "target": "demo", "dimensions": {},
           "refutations": sys.argv[3:], "schema_version": "1.0.0"}, open(sys.argv[1], "w"))
PY
}

run() {  # run <args...> -> sets RC / OUT
  OUT=$(bash "$CONVERGE" "$@" 2>&1); RC=$?
}
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
steps_in() { awk '/^## Wave [0-9]+: converge/ {f=1; next} /^## / {f=0} f && /^- fix:/' "$1/plan.md" | wc -l | tr -d ' '; }

V="$TMP_ROOT/v.json"

echo "=== two refutations -> one wave, two steps, lint clean ==="
D=$(new_fixture)
verdict "$V" REFUTED "file widget.sh missing" "test widget-test.sh failed"
SPEC_SUM=$(sum "$D/spec.md")
run "$D" --from "$V"
check "exit-3" 3 "$RC"
check "wave-header" 1 "$(grep -c '^## Wave 2: converge 1$' "$D/plan.md")"
check "two-steps" 2 "$(steps_in "$D")"
check "verify-targets-new-wave" 2 "$(grep -c 'completion-gate.sh demo 2`$' "$D/plan.md")"
bash "$LINT" "$D" >/dev/null 2>&1; check "lint-clean" 0 "$?"
check "spec-untouched" "$SPEC_SUM" "$(sum "$D/spec.md")"

echo "=== same verdict again -> no progress ==="
BEFORE=$(sum "$D/plan.md")
run "$D" --from "$V"
check "exit-6" 6 "$RC"
check "plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== a changed gap set advances; the fourth round hits the cap ==="
verdict "$V" REFUTED "assertion A failed"
run "$D" --from "$V"; check "round-2-exit-3" 3 "$RC"
check "round-2-header" 1 "$(grep -c '^## Wave 3: converge 2$' "$D/plan.md")"
verdict "$V" REFUTED "assertion B failed"
run "$D" --from "$V"; check "round-3-exit-3" 3 "$RC"
verdict "$V" REFUTED "assertion C failed"
BEFORE=$(sum "$D/plan.md")
run "$D" --from "$V"
check "round-4-exit-5" 5 "$RC"
check "cap-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"
check "spec-untouched-all-runs" "$SPEC_SUM" "$(sum "$D/spec.md")"

echo "=== a superset of the previous gaps is no progress ==="
D=$(new_fixture)
verdict "$V" REFUTED "gap one"
run "$D" --from "$V"; check "first-round-exit-3" 3 "$RC"
verdict "$V" REFUTED "gap one" "gap two"
run "$D" --from "$V"; check "superset-exit-6" 6 "$RC"
verdict "$V" REFUTED "gap two"
run "$D" --from "$V"; check "different-gap-advances" 3 "$RC"

echo "=== CONFIRMED -> exit 0, nothing appended ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
verdict "$V" CONFIRMED
run "$D" --from "$V"
check "converged-exit-0" 0 "$RC"
check "converged-says-so" 1 "$(grep -c '^Converged' <<<"$OUT")"
check "converged-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== CONFIRMED with an uncovered-decision advisory still converges on it ==="
python3 -I - "$V" <<'PY'
import json, sys
json.dump({"verdict": "CONFIRMED", "score": 1.0, "target": "demo", "dimensions": {},
           "refutations": [], "advisories": ["decision D2 not covered by claim (dryrun)",
           "`decisions` must be a list of {id, evidence} (dryrun, ignored)"],
           "schema_version": "1.0.0"}, open(sys.argv[1], "w"))
PY
run "$D" --from "$V"
check "advisory-exit-3" 3 "$RC"
check "advisory-one-step" 1 "$(steps_in "$D")"
check "unrelated-advisory-ignored" 0 "$(grep -c 'must be a list' "$D/plan.md")"

echo "=== --spec-change -> exit 7, plan unchanged ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
verdict "$V" REFUTED "needs a new decision"
run "$D" --from "$V" --spec-change
check "spec-change-exit-7" 7 "$RC"
check "spec-change-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== bad input -> exit 2, plan unchanged ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
printf '{not json' > "$V"
run "$D" --from "$V"; check "malformed-json-exit-2" 2 "$RC"
run "$D" --from "$TMP_ROOT/missing.json"; check "missing-verdict-exit-2" 2 "$RC"
printf '{"verdict":"BOGUS"}' > "$V"
run "$D" --from "$V"; check "unknown-verdict-exit-2" 2 "$RC"
printf '{"verdict":"REFUTED","refutations":"oops"}' > "$V"
run "$D" --from "$V"; check "refutations-not-list-exit-2" 2 "$RC"
verdict "$V" REFUTED
run "$D" --from "$V"; check "refuted-without-gaps-exit-2" 2 "$RC"
run "$TMP_ROOT/nodir" --from "$V"; check "missing-plan-exit-2" 2 "$RC"
run "$D"; check "no-from-exit-2" 2 "$RC"
check "bad-input-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== backticks and newlines flatten into one lint-clean step ==="
D=$(new_fixture)
verdict "$V" REFUTED $'test `foo.sh` failed\nline two\twith tab' 'path `a/b` -> not a verify: marker'
run "$D" --from "$V"
check "flatten-exit-3" 3 "$RC"
check "flatten-two-steps" 2 "$(steps_in "$D")"
check "gap-is-one-line" 1 "$(grep -c "^- fix: test 'foo.sh' failed line two with tab → verify:" "$D/plan.md")"
bash "$LINT" "$D" >/dev/null 2>&1; check "flatten-lint-clean" 0 "$?"

echo "=== a wave that fails lint is rolled back (exit 4) ==="
D=$(new_fixture)
printf '\n## Not a wave header\n' >> "$D/plan.md"
bash "$LINT" "$D" >/dev/null 2>&1; check "fixture-is-lint-dirty" 1 "$?"
BEFORE=$(sum "$D/plan.md")
verdict "$V" REFUTED "some gap"
run "$D" --from "$V"
check "lint-fail-exit-4" 4 "$RC"
check "lint-fail-restored" "$BEFORE" "$(sum "$D/plan.md")"
check "no-temp-files-left" 0 "$(find "$D" -name '.plan.md.*' -o -name '*.restore.*' | wc -l | tr -d ' ')"

echo "=== slug argument resolves under .agent/plans ==="
D=$(new_fixture); ROOT=$(dirname "$D")
mkdir -p "$ROOT/.agent/plans"
cp -R "$D" "$ROOT/.agent/plans/demo"
verdict "$V" REFUTED "slug resolved"
OUT=$(cd "$ROOT" && bash "$CONVERGE" demo --from "$V" 2>&1); RC=$?
check "slug-exit-3" 3 "$RC"
check "slug-wave-appended" 1 "$(grep -c '^## Wave 2: converge 1$' "$ROOT/.agent/plans/demo/plan.md")"

echo "=== a planned wave merely named 'converge …' is not a converge round ==="
D=$(new_fixture)
printf '\n## Wave 2: converge loop\n- Build the loop → verify: `bash core/tests/loop-test.sh`\n' >> "$D/plan.md"
verdict "$V" REFUTED "loop gap"
run "$D" --from "$V"
check "named-wave-exit-3" 3 "$RC"
check "named-wave-round-1" 1 "$(grep -c '^## Wave 3: converge 1$' "$D/plan.md")"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
