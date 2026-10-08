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
#   W-8 source-first: ExitPlanMode plan that cites only memory (no file:line /
#   command-output evidence) -> flag withheld + re-verify notice; with evidence,
#   or with no memory citation (incl. "memory leak" prose) -> flag written
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
echo "=== W-8 source-first verification (ExitPlanMode plan text) ==="
# plan_event <plan-text> -> ExitPlanMode event JSON carrying tool_input.plan
plan_event() {
  PLAN="$1" python3 -c 'import json,os;print(json.dumps({"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":os.environ["PLAN"]}}))'
}
run_case "w8-memory-only-withheld" \
  "$(plan_event $'Plan\nPer memory, the retry limit is 3 in config.py. Raise it to 5.')" absent
run_case "w8-memory-korean-only-withheld" \
  "$(plan_event $'계획\n메모리에 따르면 훅은 PreToolUse 에서 돈다. 그대로 수정.')" absent
run_case "w8-memory-with-fileline-written" \
  "$(plan_event $'Plan\nPer memory, retry limit is 3 (verified at core/config.py:42). Raise it.')" written
run_case "w8-memory-with-cmd-output-written" \
  "$(plan_event $'Plan\nFrom memory: tests pass. Re-checked live:\n```\n$ pytest -q\n12 passed\n```')" written
run_case "w8-no-memory-claim-written" \
  "$(plan_event $'Plan\nAdd a retry wrapper around the fetch call.')" written
run_case "w8-memory-leak-prose-written" \
  "$(plan_event $'Plan\nFix the memory leak in the cache layer and cut memory usage.')" written
run_case "w8-no-plan-text-written" \
  '{"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{}}' written

# withheld case must also surface a re-verify notice and clear a stale flag
FLAG_W="$TMP_DIR/flag-w8-notice"
echo stale > "$FLAG_W"
OUT_W="$(plan_event $'Plan\nI recall that the limit is 3.' | AGENT_PLAN_FLAG="$FLAG_W" python3 "$HOOK" 2>/dev/null)"
[[ ! -f "$FLAG_W" ]]
check "w8-stale-flag-cleared" $?
[[ "$OUT_W" == *'"hookEventName": "PostToolUse"'* && "$OUT_W" == *"re-verify"* ]]
check "w8-notice-emitted" $?

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
