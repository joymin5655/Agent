#!/usr/bin/env bash
# instruction-budget-test.sh — prove core/tests/instruction-budget.sh is
# NON-VACUOUS: a fixture inside every ceiling PASSes (exit 0), and a fixture
# with one oversized SKILL.md / agent / rule FAILs (exit 1) naming that file.
#
# Each case gets a FRESH fixture (mktemp -d) pointed at via
# INSTRUCTION_BUDGET_ROOT, so a mutation never leaks into another case.
#
# Usage: bash core/tests/instruction-budget-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/core/tests/instruction-budget.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# build_fixture — a small in-budget tree; echoes its path.
build_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  mkdir -p "$fx/skills/demo" "$fx/agents" "$fx/rules/policy"
  printf -- '---\nname: demo\n---\n# demo\n' > "$fx/skills/demo/SKILL.md"
  printf -- '---\nname: helper\n---\n# helper\n' > "$fx/agents/helper.md"
  printf '# rule\n' > "$fx/rules/policy/nested.md"
  printf '%s' "$fx"
}

# pad <file> <bytes> — append filler until <file> exceeds <bytes>.
pad() { head -c "$(( $2 + 1 ))" /dev/zero | tr '\0' 'x' >> "$1"; }

GATE_OUT=""; GATE_RC=0
run_gate() { GATE_OUT="$(INSTRUCTION_BUDGET_ROOT="$1" bash "$GATE" 2>&1)"; GATE_RC=$?; }
# rc_is <n> — echo 0 if the last gate exit code was <n>, else 1 (check input).
rc_is() { if [[ $GATE_RC -eq $1 ]]; then echo 0; else echo 1; fi; }

echo "=== (0) in-budget fixture -> PASS ==="
FX=$(build_fixture)
run_gate "$FX"
check "clean-passes" "$(rc_is 0)"
printf '%s\n' "$GATE_OUT" | grep -qF '3 instruction file(s)'; check "clean-counts-all-classes" $?

echo
echo "=== (1) oversized SKILL.md -> FAIL + named ==="
FX=$(build_fixture)
pad "$FX/skills/demo/SKILL.md" 20000
run_gate "$FX"
check "skill-over-fails" "$(rc_is 1)"
printf '%s\n' "$GATE_OUT" | grep -qF 'skills/demo/SKILL.md'; check "skill-over-named" $?

echo
echo "=== (2) oversized agent -> FAIL + named ==="
FX=$(build_fixture)
pad "$FX/agents/helper.md" 8000
run_gate "$FX"
check "agent-over-fails" "$(rc_is 1)"
printf '%s\n' "$GATE_OUT" | grep -qF 'agents/helper.md'; check "agent-over-named" $?

echo
echo "=== (3) oversized nested rule -> FAIL + named (recursive glob) ==="
FX=$(build_fixture)
pad "$FX/rules/policy/nested.md" 12000
run_gate "$FX"
check "rule-over-fails" "$(rc_is 1)"
printf '%s\n' "$GATE_OUT" | grep -qF 'rules/policy/nested.md'; check "rule-over-named" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
