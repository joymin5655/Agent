#!/usr/bin/env bash
# lane-report-lint-test.sh — deterministic lint over the cross-vendor lane
# report template and its wiring into the delegation contract and supervise
# skill. Grep-based on purpose: the contract these docs form is structural
# (required headings, required cross-references), so drift is machine-checkable.
#
# Usage: bash core/tests/lane-report-lint-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT="$REPO_ROOT/skills/supervise/templates/lane-report.md"
CONTRACT="$REPO_ROOT/skills/supervise/templates/delegation-contract.md"
SKILL="$REPO_ROOT/skills/supervise/SKILL.md"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

echo "=== lane-report template: all six sections present ==="
[[ -f "$REPORT" ]]; check "template-exists" $?
for heading in STATUS OBJECTIVE CHANGES VERIFIED "LANE SAID" GAPS; do
  grep -q "^## $heading$" "$REPORT"
  check "heading-$(echo "$heading" | tr ' ' '-')" $?
done

echo
echo "=== lane-report core rules ==="
grep -q "complete.*|.*partial.*|.*unavailable.*|.*timeout" "$REPORT"
check "status-vocabulary" $?
grep -qi "claim ≠ evidence" "$REPORT";        check "claim-not-evidence-rule" $?
grep -qi "unique temp file" "$REPORT";        check "unique-temp-spec-rule" $?
grep -qi "silent" "$REPORT";                  check "no-silent-fallback-rule" $?

echo
echo "=== delegation contract references the lane report ==="
grep -q "lane-report.md" "$CONTRACT";         check "contract-references-report" $?
grep -q "Cross-vendor lane dispatch" "$CONTRACT"; check "contract-lane-section" $?
grep -qi "Interfaces" "$CONTRACT";            check "contract-names-interfaces" $?
grep -qi "re-runs\?" "$CONTRACT";             check "contract-caller-reruns" $?

echo
echo "=== supervise skill: race lanes stay inside the invariants ==="
grep -q "race: true" "$SKILL";                check "skill-race-annotation" $?
grep -qi "patch-only" "$SKILL";               check "skill-race-patch-only" $?
grep -qi "only tree writer" "$SKILL";         check "skill-one-writer-preserved" $?
grep -q "lane-report.md" "$SKILL";            check "skill-references-report" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
