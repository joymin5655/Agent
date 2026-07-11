#!/usr/bin/env bash
# plan-gate-test.sh — verify core/hooks/plan-gate.py (P1-3 — this hook had no test).
#
# plan-gate.py is a PostToolUse hook: on ExitPlanMode, or a plan-class Agent/Task
# dispatch, it writes the approval flag that spec-gate.py later reads. Every case
# points AGENT_PLAN_FLAG at a throwaway file so the live session flag is untouched.
#
# Covers:
#   ExitPlanMode                         -> flag written
#   Agent subagent_type=Plan             -> flag written
#   Agent description keyword (design)   -> flag written
#   Agent description keyword (Korean)   -> flag written
#   Agent non-plan (subagent_type=code)  -> flag NOT written
#   non-plan tool (Write)                -> flag NOT written
#   malformed stdin                      -> no crash, flag NOT written, exit 0
#
# Usage: bash core/tests/plan-gate-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/plan-gate.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_case <name> <event-json> <expect: written|absent>
run_case() {
  local name="$1" event="$2" expect="$3"
  local flag="$TMP_DIR/flag-$name"
  rm -f "$flag"
  printf '%s' "$event" | AGENT_PLAN_FLAG="$flag" python3 "$HOOK" >/dev/null 2>&1
  local rc=$?
  local got="absent"
  [[ -f "$flag" ]] && got="written"
  if [[ $rc -eq 0 && "$got" == "$expect" ]]; then
    echo "  ok   [$name] ($got)"; PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] expected=$expect got=$got rc=$rc"; FAIL=$((FAIL + 1))
  fi
}

echo "=== flag written on plan approval ==="
run_case "exitplanmode-writes" \
  '{"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{}}' written
run_case "agent-plan-subtype-writes" \
  '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Plan"}}' written
run_case "agent-design-keyword-writes" \
  '{"event":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"general-purpose","description":"design the auth architecture"}}' written
run_case "agent-korean-keyword-writes" \
  '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"description":"결제 모듈 설계"}}' written

echo
echo "=== flag NOT written for non-plan events ==="
run_case "agent-nonplan-absent" \
  '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","description":"review this diff"}}' absent
run_case "write-tool-absent" \
  '{"event":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"src/x.ts","content":"x"}}' absent

echo
echo "=== malformed stdin -> no crash, no flag, exit 0 ==="
FLAG_M="$TMP_DIR/flag-malformed"
rm -f "$FLAG_M"
printf 'not json{' | AGENT_PLAN_FLAG="$FLAG_M" python3 "$HOOK" >/dev/null 2>&1
RC_M=$?
[[ $RC_M -eq 0 && ! -f "$FLAG_M" ]]
check "malformed-no-crash-no-flag" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
