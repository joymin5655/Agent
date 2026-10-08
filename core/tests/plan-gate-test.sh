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

# plan_event_sid <session_id> <plan-text>
plan_event_sid() {
  SID="$1" PLAN="$2" python3 -c 'import json,os;print(json.dumps({"event":"PostToolUse","session_id":os.environ["SID"],"tool_name":"ExitPlanMode","tool_input":{"plan":os.environ["PLAN"]}}))'
}
MEM_ONLY=$'Plan\nI recall that the limit is 3.'
OK_PLAN=$'Plan\nPer memory, limit is 3 (checked core/config.py:42).'

# negative evidence fixtures: a memory citation + look-alike "evidence" -> withheld
for fx in 'host example.com:443' 'url https://example.com:8080/x' 'ver v1.2:3'; do
  name="w8-badevidence-$(printf '%s' "$fx" | tr -c 'A-Za-z0-9' '-')"
  run_case "$name" "$(plan_event "$(printf 'Plan\nPer memory it works. %s' "$fx")")" absent
done
run_case "w8-bare-dollar-no-fence-withheld" \
  "$(plan_event $'Plan\nPer memory it works.\n$ pytest -q\n12 passed')" absent
run_case "w8-fence-dollar-no-output-withheld" \
  "$(plan_event $'Plan\nPer memory it works.\n```\n$ pytest -q\n```')" absent
run_case "w8-fence-dollar-output-written" \
  "$(plan_event $'Plan\nPer memory it works.\n```\n$ pytest -q\n12 passed\n```')" written
run_case "w8-slash-path-line-written" \
  "$(plan_event 'Plan: per memory X. See docs/a/notes:12')" written

# memory false-positive fixtures -> flag written
for fx in 'Read from memory instead of disk.' 'Tune based on memory pressure.' \
          'Allocate from memory pool.' 'We shall recall the handler later; I remember nothing.'; do
  name="w8-memfp-$(printf '%s' "$fx" | tr -c 'A-Za-z0-9' '-' | cut -c1-30)"
  run_case "$name" "$(plan_event "$(printf 'Plan\n%s' "$fx")")" written
done

# non-dict tool_input / non-dict event -> no crash, exit 0
for ev in '{"tool_name":"ExitPlanMode","tool_input":"oops"}' '{"tool_name":"Agent","tool_input":[1]}' '[1,2]' 'null'; do
  printf '%s' "$ev" | AGENT_PLAN_FLAG="$TMP_DIR/flag-nd" python3 "$HOOK" >/dev/null 2>&1
  check "nondict-no-crash-$(printf '%s' "$ev" | cut -c1-24 | tr -c 'A-Za-z0-9' '-')" $?
done

# session scoping: B's withhold keeps A's flag; same-session withhold clears own
FLAG_S="$TMP_DIR/flag-sess"
rm -f "$FLAG_S" "$FLAG_S.withheld"
plan_event_sid sessA "$OK_PLAN" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
OUT_B="$(plan_event_sid sessB "$MEM_ONLY" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK")"
[[ -f "$FLAG_S" && "$OUT_B" == *"another session"* ]]
check "w8-other-session-flag-preserved-and-honest-notice" $?
plan_event_sid sessA "$MEM_ONLY" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ ! -f "$FLAG_S" ]]
check "w8-own-session-flag-cleared" $?

# Agent path stays shut for the withholding session, open for others, reopened by a good plan
agent_ev() { printf '{"event":"PostToolUse","session_id":"%s","tool_name":"Agent","tool_input":{"subagent_type":"Plan"}}' "$1"; }
agent_ev sessA | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ ! -f "$FLAG_S" ]]
check "w8-agent-path-blocked-same-session" $?
agent_ev sessC | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ -f "$FLAG_S" ]]
check "w8-agent-path-open-other-session" $?
rm -f "$FLAG_S"
plan_event_sid sessA "$OK_PLAN" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
rm -f "$FLAG_S"
agent_ev sessA | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ -f "$FLAG_S" ]]
check "w8-agent-path-reopened-after-good-plan" $?

# flag content carries session id; consumers only test existence
plan_event_sid sessZ "$OK_PLAN" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
grep -q "session=sessZ" "$FLAG_S"
check "w8-flag-records-session" $?

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
