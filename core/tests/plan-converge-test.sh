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
run "$D" --from "$V" --wave 1
check "exit-3" 3 "$RC"
check "wave-header" 1 "$(grep -c '^## Wave 2: converge 1$' "$D/plan.md")"
check "two-steps" 2 "$(steps_in "$D")"
check "verify-targets-new-wave" 2 "$(grep -c 'completion-gate.sh demo 2`$' "$D/plan.md")"
bash "$LINT" "$D" >/dev/null 2>&1; check "lint-clean" 0 "$?"
check "spec-untouched" "$SPEC_SUM" "$(sum "$D/spec.md")"

echo "=== same verdict again -> no progress ==="
BEFORE=$(sum "$D/plan.md")
run "$D" --from "$V" --wave 2
check "exit-6" 6 "$RC"
check "plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== a changed gap set advances; the fourth round hits the cap ==="
verdict "$V" REFUTED "assertion A failed"
run "$D" --from "$V" --wave 2; check "round-2-exit-3" 3 "$RC"
check "round-2-header" 1 "$(grep -c '^## Wave 3: converge 2$' "$D/plan.md")"
verdict "$V" REFUTED "assertion B failed"
run "$D" --from "$V" --wave 3; check "round-3-exit-3" 3 "$RC"
verdict "$V" REFUTED "assertion C failed"
BEFORE=$(sum "$D/plan.md")
run "$D" --from "$V" --wave 4
check "round-4-exit-5" 5 "$RC"
check "cap-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"
check "spec-untouched-all-runs" "$SPEC_SUM" "$(sum "$D/spec.md")"

echo "=== a superset of the previous gaps is no progress ==="
D=$(new_fixture)
verdict "$V" REFUTED "gap one"
run "$D" --from "$V" --wave 1; check "first-round-exit-3" 3 "$RC"
verdict "$V" REFUTED "gap one" "gap two"
run "$D" --from "$V" --wave 2; check "superset-exit-6" 6 "$RC"
verdict "$V" REFUTED "gap two"
run "$D" --from "$V" --wave 2; check "different-gap-advances" 3 "$RC"

echo "=== CONFIRMED -> exit 0, nothing appended ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
verdict "$V" CONFIRMED
run "$D" --from "$V" --wave 1
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
run "$D" --from "$V" --wave 1
check "advisory-exit-3" 3 "$RC"
check "advisory-one-step" 1 "$(steps_in "$D")"
check "unrelated-advisory-ignored" 0 "$(grep -c 'must be a list' "$D/plan.md")"

echo "=== --spec-change -> exit 7, plan unchanged ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
verdict "$V" REFUTED "needs a new decision"
run "$D" --from "$V" --wave 1 --spec-change
check "spec-change-exit-7" 7 "$RC"
check "spec-change-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== bad input -> exit 2, plan unchanged ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
printf '{not json' > "$V"
run "$D" --from "$V" --wave 1; check "malformed-json-exit-2" 2 "$RC"
run "$D" --from "$TMP_ROOT/missing.json"; check "missing-verdict-exit-2" 2 "$RC"
printf '{"verdict":"BOGUS"}' > "$V"
run "$D" --from "$V" --wave 1; check "unknown-verdict-exit-2" 2 "$RC"
printf '{"verdict":"REFUTED","refutations":"oops"}' > "$V"
run "$D" --from "$V" --wave 1; check "refutations-not-list-exit-2" 2 "$RC"
verdict "$V" REFUTED
run "$D" --from "$V" --wave 1; check "refuted-without-gaps-exit-2" 2 "$RC"
run "$TMP_ROOT/nodir" --from "$V" --wave 1; check "missing-plan-exit-2" 2 "$RC"
run "$D"; check "no-from-exit-2" 2 "$RC"
verdict "$V" REFUTED "x"
run "$D" --from "$V"; check "no-wave-exit-2" 2 "$RC"
run "$D" --from "$V" --wave 7; check "unknown-wave-exit-2" 2 "$RC"
run "$D" --from "$V" --wave abc; check "bad-wave-exit-2" 2 "$RC"
check "bad-input-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== backticks and newlines flatten into one lint-clean step ==="
D=$(new_fixture)
verdict "$V" REFUTED $'test `foo.sh` failed\nline two\twith tab' 'path `a/b` -> not a verify: marker'
run "$D" --from "$V" --wave 1
check "flatten-exit-3" 3 "$RC"
check "flatten-two-steps" 2 "$(steps_in "$D")"
check "gap-is-one-line" 1 "$(grep -c "^- fix: test 'foo.sh' failed line two with tab → verify:" "$D/plan.md")"
bash "$LINT" "$D" >/dev/null 2>&1; check "flatten-lint-clean" 0 "$?"

echo "=== a plan that already fails lint is reported as exit 9, not touched ==="
D=$(new_fixture)
printf '\n## Not a wave header\n' >> "$D/plan.md"
bash "$LINT" "$D" >/dev/null 2>&1; check "fixture-is-lint-dirty" 1 "$?"
BEFORE=$(sum "$D/plan.md")
verdict "$V" REFUTED "some gap"
run "$D" --from "$V" --wave 1
check "preexisting-lint-failure-exit-9" 9 "$RC"
check "preexisting-lint-failure-untouched" "$BEFORE" "$(sum "$D/plan.md")"
check "no-temp-files-left" 0 "$(find "$D" -name '.plan.md.*' -o -name '*.restore.*' | wc -l | tr -d ' ')"

echo "=== slug argument resolves under .agent/plans ==="
D=$(new_fixture); ROOT=$(dirname "$D")
mkdir -p "$ROOT/.agent/plans"
cp -R "$D" "$ROOT/.agent/plans/demo"
verdict "$V" REFUTED "slug resolved"
OUT=$(cd "$ROOT" && bash "$CONVERGE" demo --from "$V" --wave 1 2>&1); RC=$?
check "slug-exit-3" 3 "$RC"
check "slug-wave-appended" 1 "$(grep -c '^## Wave 2: converge 1$' "$ROOT/.agent/plans/demo/plan.md")"

echo "=== a planned wave merely named 'converge …' is not a converge round ==="
D=$(new_fixture)
printf '\n## Wave 2: converge loop\n- Build the loop → verify: `bash core/tests/loop-test.sh`\n' >> "$D/plan.md"
verdict "$V" REFUTED "loop gap"
run "$D" --from "$V" --wave 1
check "named-wave-exit-3" 3 "$RC"
check "named-wave-round-1" 1 "$(grep -c '^## Wave 3: converge 1$' "$D/plan.md")"

echo "=== planned wave refuted while a converge wave is pending -> fold in (exit 8) ==="
D=$(new_fixture)
printf '\n## Wave 2: docs\n- Write docs → verify: `grep -q docs README.md`\n' >> "$D/plan.md"
verdict "$V" REFUTED "gap one"
run "$D" --from "$V" --wave 1; check "first-append-exit-3" 3 "$RC"
check "converge-is-wave-3" 1 "$(grep -c '^## Wave 3: converge 1$' "$D/plan.md")"
verdict "$V" REFUTED "gap one" "gap from wave two"
run "$D" --from "$V" --wave 2
check "fold-in-exit-8" 8 "$RC"
check "no-new-wave" 0 "$(grep -c '^## Wave 4' "$D/plan.md")"
check "added-step-present" 1 "$(grep -c '^- fix: gap from wave two → verify: `bash core/infra/completion-gate.sh demo 3`$' "$D/plan.md")"
check "duplicate-gap-skipped" 1 "$(grep -c '^- fix: gap one ' "$D/plan.md")"
bash "$LINT" "$D" >/dev/null 2>&1; check "fold-in-lint-clean" 0 "$?"
BEFORE=$(sum "$D/plan.md")
run "$D" --from "$V" --wave 2
check "repeat-exit-8" 8 "$RC"
check "repeat-unchanged" "$BEFORE" "$(sum "$D/plan.md")"
verdict "$V" REFUTED "gap one"
run "$D" --from "$V" --wave 1
check "planned-wave-never-no-progress" 8 "$RC"

echo "=== folding into a converge wave that is not last in the file ==="
D=$(new_fixture)
verdict "$V" REFUTED "first gap"
run "$D" --from "$V" --wave 1
printf '\n## Wave 3: later\n- Later work → verify: `grep -q later README.md`\n' >> "$D/plan.md"
verdict "$V" REFUTED "second gap"
run "$D" --from "$V" --wave 1
check "fold-in-middle-exit-8" 8 "$RC"
check "added-before-next-wave" 1 "$(awk '/^## Wave 2: converge/ {f=1; next} /^## / {f=0} f && /second gap/' "$D/plan.md" | wc -l | tr -d ' ')"
bash "$LINT" "$D" >/dev/null 2>&1; check "fold-in-middle-lint-clean" 0 "$?"

echo "=== fence opener mirrors plan-lint: backtick rest containing a backtick is no fence ==="
D=$(new_fixture)
printf '\nprose ``` not a fence `x`\n\n## Wave 5: late\n- Late work → verify: `grep -q late README.md`\n' >> "$D/plan.md"
bash "$LINT" "$D" >/dev/null 2>&1; check "fence-fixture-lint-clean" 0 "$?"
verdict "$V" REFUTED "gap"
run "$D" --from "$V" --wave 1
check "wave-after-pseudo-fence-counted" 1 "$(grep -c '^## Wave 6: converge 1$' "$D/plan.md")"
D=$(new_fixture)
printf '\n````\n## Wave 9: inside a real fence\n````\n' >> "$D/plan.md"
run "$D" --from "$V" --wave 1
check "wave-inside-real-fence-ignored" 1 "$(grep -c '^## Wave 2: converge 1$' "$D/plan.md")"

echo "=== directory name must be a valid slug ==="
mkdir -p "$TMP_ROOT/bad name"; cp "$D/plan.md" "$TMP_ROOT/bad name/plan.md"
run "$TMP_ROOT/bad name" --from "$V" --wave 1
check "invalid-dir-slug-exit-2" 2 "$RC"

echo "=== python crash is mapped to exit 2 ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
STUB="$TMP_ROOT/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/python3"; chmod +x "$STUB/python3"
OUT=$(PATH="$STUB:$PATH" bash "$CONVERGE" "$D" --from "$V" --wave 1 2>&1); RC=$?
check "python-crash-exit-2" 2 "$RC"
check "python-crash-plan-unchanged" "$BEFORE" "$(sum "$D/plan.md")"

echo "=== a written plan that fails lint is restored (exit 4) ==="
D=$(new_fixture); BEFORE=$(sum "$D/plan.md")
FAKE="$TMP_ROOT/fake"; mkdir -p "$FAKE"
cp "$CONVERGE" "$FAKE/plan-converge.sh"
printf '#!/bin/sh\nn=$(cat "%s/n" 2>/dev/null || echo 0)\necho $((n+1)) > "%s/n"\n[ "$n" -ge 1 ] && exit 1\nexit 0\n' "$FAKE" "$FAKE" > "$FAKE/plan-lint.sh"
OUT=$(bash "$FAKE/plan-converge.sh" "$D" --from "$V" --wave 1 2>&1); RC=$?
check "post-lint-failure-exit-4" 4 "$RC"
check "post-lint-failure-restored" "$BEFORE" "$(sum "$D/plan.md")"
check "no-temp-files-left-after-4" 0 "$(find "$D" -name '.plan.md.*' -o -name '*.restore.*' | wc -l | tr -d ' ')"

echo "=== command substitution in a gap is defused ==="
D=$(new_fixture)
verdict "$V" REFUTED 'pytest x failed $(touch PWNED)'
run "$D" --from "$V" --wave 1
check "substitution-exit-3" 3 "$RC"
check "substitution-defused" 1 "$(grep -c -F 'failed $ (touch PWNED)' "$D/plan.md")"
check "no-raw-substitution" 0 "$(grep -c -F '$(' "$D/plan.md")"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
