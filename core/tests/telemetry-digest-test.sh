#!/usr/bin/env bash
# telemetry-digest-test.sh — verify core/infra/telemetry-digest.sh (P1-5).
#
# Feeds synthetic supervisor.jsonl fixtures (never the real .agent/logs/supervisor.jsonl)
# to the digest script via a positional path arg and asserts the rendered report.
# Covers: (a) missing log file, (b) action/specialist stats + rule candidates on a
# known sample, (c) a malformed line does not crash the digest or drop valid entries,
# (d) an empty log file.
#
# Usage: bash core/tests/telemetry-digest-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/telemetry-digest.sh"

PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then
    echo "  ok   [$name]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name]"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== (a) missing log file -> exit 0, zeroed digest line ==="
OUT_A="$(bash "$SCRIPT" "$TMP_DIR/no-such-file.jsonl" 2>&1)"
RC_A=$?
[[ $RC_A -eq 0 ]]
check "exit-0-missing-log" $?
[[ "$OUT_A" == *"digest: 0 events, 0 specialists, 0 rule candidate(s)"* ]]
check "zeroed-digest-line" $?

echo
echo "=== (b) known sample -> action/specialist stats + rule candidates ==="
# 9 valid events: code-reviewer is asked once and dispatched (should NOT be flagged);
# phantom-agent matches then logs ghost (GHOST candidate); never-dispatched is
# ask-intent'd 3x with 0 dispatches (NO-ACCEPT candidate, threshold=3 default);
# security-reviewer is ask-security'd only once (below threshold, NOT flagged).
SAMPLE="$TMP_DIR/sample.jsonl"
cat > "$SAMPLE" <<'EOF'
{"ts":"2026-07-05T00:00:00Z","event":"UserPromptSubmit","tool_name":"","session_id":"s1","action":"match","specialist":"code-reviewer","keyword":"review this diff"}
{"ts":"2026-07-05T00:00:01Z","event":"PreToolUse","tool_name":"Write","session_id":"s1","action":"ask-intent","specialist":"code-reviewer"}
{"ts":"2026-07-05T00:00:02Z","event":"PostToolUse","tool_name":"Task","session_id":"s1","action":"dispatched","specialist":"code-reviewer"}
{"ts":"2026-07-05T00:01:00Z","event":"UserPromptSubmit","tool_name":"","session_id":"s2","action":"match","specialist":"phantom-agent","keyword":"foo bar"}
{"ts":"2026-07-05T00:01:01Z","event":"UserPromptSubmit","tool_name":"","session_id":"s2","action":"ghost","specialist":"phantom-agent","keyword":"foo bar"}
{"ts":"2026-07-05T00:02:00Z","event":"PreToolUse","tool_name":"Write","session_id":"s3","action":"ask-intent","specialist":"never-dispatched"}
{"ts":"2026-07-05T00:03:00Z","event":"PreToolUse","tool_name":"Edit","session_id":"s4","action":"ask-intent","specialist":"never-dispatched"}
{"ts":"2026-07-05T00:04:00Z","event":"PreToolUse","tool_name":"Write","session_id":"s5","action":"ask-intent","specialist":"never-dispatched"}
{"ts":"2026-07-05T00:05:00Z","event":"PreToolUse","tool_name":"Write","session_id":"s6","action":"ask-security","specialist":"security-reviewer"}
EOF

OUT_B="$(bash "$SCRIPT" "$SAMPLE" 2>&1)"
RC_B=$?
[[ $RC_B -eq 0 ]]
check "exit-0-sample" $?
[[ "$OUT_B" == *"match: 2"* ]]
check "action-count-match" $?
[[ "$OUT_B" == *"ask-intent: 4"* ]]
check "action-count-ask-intent" $?
[[ "$OUT_B" == *"ask-security: 1"* ]]
check "action-count-ask-security" $?
[[ "$OUT_B" == *"dispatched: 1"* ]]
check "action-count-dispatched" $?
[[ "$OUT_B" == *"ghost: 1"* ]]
check "action-count-ghost" $?
[[ "$OUT_B" == *"[GHOST]"* && "$OUT_B" == *"phantom-agent"* ]]
check "rule-candidate-ghost" $?
[[ "$OUT_B" == *"[NO-ACCEPT]"* && "$OUT_B" == *"never-dispatched"* ]]
check "rule-candidate-no-accept" $?
if [[ "$OUT_B" == *"[NO-ACCEPT] specialist code-reviewer"* || "$OUT_B" == *"[GHOST] specialist code-reviewer"* ]]; then
  check "code-reviewer-not-flagged" 1
else
  check "code-reviewer-not-flagged" 0
fi
if [[ "$OUT_B" == *"[NO-ACCEPT] specialist security-reviewer"* ]]; then
  check "security-reviewer-below-threshold-not-flagged" 1
else
  check "security-reviewer-below-threshold-not-flagged" 0
fi
[[ "$OUT_B" == *"digest: 9 events, 4 specialists, 2 rule candidate(s)"* ]]
check "summary-line-exact" $?
if [[ $RC_B -ne 0 || "$FAIL" -gt 0 ]]; then
  : # keep going — individual checks already reported which one failed
fi

echo
echo "=== (c) malformed line does not crash the digest or drop valid entries ==="
MALFORMED="$TMP_DIR/malformed.jsonl"
cat "$SAMPLE" > "$MALFORMED"
echo '{ this is not valid json ]' >> "$MALFORMED"
OUT_C="$(bash "$SCRIPT" "$MALFORMED" 2>&1)"
RC_C=$?
[[ $RC_C -eq 0 ]]
check "exit-0-malformed-line" $?
[[ "$OUT_C" == *"digest: 9 events, 4 specialists, 2 rule candidate(s)"* ]]
check "malformed-line-does-not-drop-valid-entries" $?

echo
echo "=== (d) empty log file -> zeroed digest line ==="
EMPTY="$TMP_DIR/empty.jsonl"
: > "$EMPTY"
OUT_D="$(bash "$SCRIPT" "$EMPTY" 2>&1)"
RC_D=$?
[[ $RC_D -eq 0 ]]
check "exit-0-empty-log" $?
[[ "$OUT_D" == *"digest: 0 events, 0 specialists, 0 rule candidate(s)"* ]]
check "zeroed-digest-line-empty-file" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
