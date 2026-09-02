#!/usr/bin/env bash
# top-edit-advisor-test.sh — verify core/hooks/top-edit-advisor.py.
#
# Accumulation-time counterpart to model-routing-advisor.py: fires
# PostToolUse on Write|Edit|MultiEdit and, only at multiples of THRESHOLD,
# scans the session transcript for the TOP model's own non-sidechain
# Edit/Write/MultiEdit/NotebookEdit calls. Repeats the warning every
# +THRESHOLD measured edits instead of warning once and going silent, and
# never caches a not-TOP verdict (the session model can switch mid-session).
# Never sets permissionDecision, never blocks, always exits 0.
#
# Seams: AGENT_TOP_EDIT_STATE_DIR (fixture state dir), AGENT_TOP_EDIT_THRESHOLD
# (set to 3 here so fixtures stay small).
#
# Usage: bash core/tests/top-edit-advisor-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/top-edit-advisor.py"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
STATE_DIR="$WORK/state"
THRESHOLD=3
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# content_array <n> -> JSON array of n Edit tool_use entries
content_array() {
  local n="$1" arr="" i
  for ((i = 0; i < n; i++)); do
    arr="${arr}${arr:+,}{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{}}"
  done
  echo "[$arr]"
}

# transcript_line <model> <sidechain:true|false> <n_edits>
transcript_line() {
  local model="$1" sidechain="$2" n="$3"
  printf '{"type":"assistant","isSidechain":%s,"message":{"role":"assistant","model":"%s","content":%s}}\n' \
    "$sidechain" "$model" "$(content_array "$n")"
}

# evt <session_id> <transcript_path>
evt() {
  printf '{"event":"PostToolUse","tool_name":"Edit","session_id":"%s","transcript_path":"%s","tool_input":{},"tool_response":{}}' \
    "$1" "$2"
}

# run <stdin_json> -> sets OUT, RC; also appends OUT to the ALL_OUT log so the
# RED check at the end inspects every invocation's stdout, not just the last.
ALL_OUT=""
run() {
  OUT="$(printf '%s' "$1" | env \
    AGENT_TOP_EDIT_STATE_DIR="$STATE_DIR" \
    AGENT_TOP_EDIT_THRESHOLD="$THRESHOLD" \
    python3 "$HOOK" 2>/dev/null)"
  RC=$?
  ALL_OUT="${ALL_OUT}
${OUT}"
}

expect_silent() {
  local name="$1"
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "$name"; else bad "$name" "rc=$RC out='$OUT'"; fi
}

expect_warn() {
  local name="$1"
  if [[ "$RC" -eq 0 && "$OUT" == *'"systemMessage"'* ]]; then ok "$name"; else bad "$name" "rc=$RC out='$OUT'"; fi
}

echo "=== a: threshold multiple + TOP measured >= threshold -> warn on the 3rd call ==="
T_A="$WORK/transcript-a.jsonl"
transcript_line claude-fable-5 false 3 > "$T_A"
SID_A="sess-a"
run "$(evt "$SID_A" "$T_A")"; expect_silent "a1-first-call-silent"
run "$(evt "$SID_A" "$T_A")"; expect_silent "a2-second-call-silent"
run "$(evt "$SID_A" "$T_A")"; expect_warn "a3-third-call-warns"
[[ "$OUT" == *"3 direct edits"* ]] && ok "a4-warn-mentions-count" || bad "a4-warn-mentions-count" "$OUT"

echo
echo "=== b: count below threshold / not a multiple -> silent ==="
T_B="$WORK/transcript-b.jsonl"
transcript_line claude-fable-5 false 3 > "$T_B"
SID_B="sess-b"
run "$(evt "$SID_B" "$T_B")"; expect_silent "b1-count-1-silent"
run "$(evt "$SID_B" "$T_B")"; expect_silent "b2-count-2-silent"

echo
echo "=== c: sidechain-only edits -> silent (inflation guard) ==="
T_C="$WORK/transcript-c.jsonl"
transcript_line claude-fable-5 true 3 > "$T_C"
SID_C="sess-c"
run "$(evt "$SID_C" "$T_C")"
run "$(evt "$SID_C" "$T_C")"
run "$(evt "$SID_C" "$T_C")"; expect_silent "c1-sidechain-only-silent-at-multiple"

echo
echo "=== d: no-cache regression guard — not-TOP model silent, switch to fable warns ==="
T_D="$WORK/transcript-d.jsonl"
transcript_line claude-sonnet-5 false 3 > "$T_D"
SID_D="sess-d"
run "$(evt "$SID_D" "$T_D")"
run "$(evt "$SID_D" "$T_D")"
run "$(evt "$SID_D" "$T_D")"; expect_silent "d1-not-top-model-silent-at-multiple"
transcript_line claude-fable-5 false 3 > "$T_D"
run "$(evt "$SID_D" "$T_D")"; expect_silent "d2-count-4-silent"
run "$(evt "$SID_D" "$T_D")"; expect_silent "d3-count-5-silent"
run "$(evt "$SID_D" "$T_D")"; expect_warn "d4-switched-to-fable-warns-at-count-6"

echo
echo "=== e: re-warn only after >= threshold new measured edits ==="
T_E="$WORK/transcript-e.jsonl"
transcript_line claude-fable-5 false 3 > "$T_E"
SID_E="sess-e"
run "$(evt "$SID_E" "$T_E")"
run "$(evt "$SID_E" "$T_E")"
run "$(evt "$SID_E" "$T_E")"; expect_warn "e1-first-warning-at-3"
transcript_line claude-fable-5 false 4 > "$T_E"
run "$(evt "$SID_E" "$T_E")"
run "$(evt "$SID_E" "$T_E")"
run "$(evt "$SID_E" "$T_E")"; expect_silent "e2-growth-below-threshold-silent-at-6"
transcript_line claude-fable-5 false 6 > "$T_E"
run "$(evt "$SID_E" "$T_E")"
run "$(evt "$SID_E" "$T_E")"
run "$(evt "$SID_E" "$T_E")"; expect_warn "e3-growth-at-threshold-rewarns-at-9"
[[ "$OUT" == *"previous warning at 3"* ]] && ok "e4-rewarn-mentions-previous-count" || bad "e4-rewarn-mentions-previous-count" "$OUT"

echo
echo "=== f: malformed stdin / missing transcript -> silent, rc 0 ==="
run 'not json {['
expect_silent "f1-malformed-stdin-silent-rc0"
run ''
expect_silent "f2-empty-stdin-silent-rc0"
run "$(evt "sess-f" "$WORK/does-not-exist.jsonl")"
expect_silent "f3-missing-transcript-silent-rc0"

echo
echo "=== g: RED — no output ever sets permissionDecision (advisory-only) ==="
if [[ "$ALL_OUT" != *"permissionDecision"* ]]; then
  ok "g1-no-permission-decision-anywhere"
else
  bad "g1-no-permission-decision-anywhere" "$ALL_OUT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
