#!/usr/bin/env bash
# loop-skill-test.sh — drift gate binding skills/harness-loop + skills/loop's
# PROSE to the actual loop-run.sh mechanics (P2-1 + O-2).
#
# A SKILL.md is instructions an agent follows; nothing forces it to stay in
# sync with the code it describes once written. This battery is that force:
#   - skills/harness-loop/SKILL.md must contain the §5.2 procedure's 9 steps,
#     numbered IN ORDER, and every load-bearing token the procedure depends
#     on (--base/--target, the harness_score grep contract, the ledger,
#     git reset --hard, the branch convention, the cap/timeout/breaker
#     numbers).
#   - skills/loop/SKILL.md must contain the O-2 protocol's core promises
#     (fresh context per iteration, exactly one task per iteration, resume
#     after a restart, human approval before merge).
# RED fixtures mutate a copy of each file (reorder/remove a step, drop a
# token) and assert the checker actually fails on the mutation — a check that
# can never go red is not a check.
#
# Usage: bash core/tests/loop-skill-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HL="$REPO_ROOT/skills/harness-loop/SKILL.md"
LOOP="$REPO_ROOT/skills/loop/SKILL.md"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- checker functions (used against both the real files and RED fixtures) ---

# steps_in_order <file> -> 0 iff numbered list items "1. **" .. "9. **" appear,
# each strictly after the previous, in that exact sequence (no gap/reorder).
steps_in_order() {
  local f="$1"
  local nums; nums="$(grep -oE '^[0-9]+\. \*\*' "$f" 2>/dev/null | grep -oE '^[0-9]+')"
  [[ "$nums" == "$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9')" ]]
}

# has_tokens <file> <token...> -> 0 iff every token is a literal substring
# somewhere in the file.
has_tokens() {
  local f="$1"; shift
  local tok
  for tok in "$@"; do
    grep -qF -- "$tok" "$f" 2>/dev/null || return 1
  done
  return 0
}

HL_TOKENS=(
  "--base" "--target" "grep '^harness_score:'" "results.tsv" "loop-ledger"
  "git reset --hard" "harness-loop/<tag>" "cap 5" "600" "10-minute" "circuit-breaker"
)
LOOP_TOKENS=(
  "fresh context" "exactly one task" "Resume after a restart" "human approval"
)

echo "=== (a) skills/harness-loop/SKILL.md exists and carries the human-only-edited marker ==="
[[ -f "$HL" ]]; check "harness-loop-skill-exists" $?
grep -qi "HUMAN-ONLY-EDITED" "$HL"; check "harness-loop-marked-human-only" $?

echo
echo "=== (b) harness-loop: 9 steps present, numbered in order ==="
steps_in_order "$HL"; check "harness-loop-9-steps-in-order" $?

echo
echo "=== (c) harness-loop: every load-bearing token present ==="
has_tokens "$HL" "${HL_TOKENS[@]}"; check "harness-loop-load-bearing-tokens" $?

echo
echo "=== (d) skills/loop/SKILL.md exists and carries the O-2 protocol tokens ==="
[[ -f "$LOOP" ]]; check "loop-skill-exists" $?
has_tokens "$LOOP" "${LOOP_TOKENS[@]}"; check "loop-protocol-tokens" $?

echo
echo "=== RED: reordered steps must fail steps_in_order ==="
BAD_ORDER="$TMP_ROOT/bad-order.md"
# Relabel step 2's leading digit to 9: the body text stays put, but
# steps_in_order only reads the leading digit sequence, so this reliably
# breaks it without needing a full reorder of the file's content.
python3 - "$HL" "$BAD_ORDER" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
text = text.replace("2. **Edit TARGET only.**", "9. **Edit TARGET only.**", 1)
open(dst, "w", encoding="utf-8").write(text)
PY
steps_in_order "$BAD_ORDER"
[[ $? -ne 0 ]]; check "red-reordered-step-fails" $?

echo
echo "=== RED: a removed step must fail steps_in_order ==="
REMOVED_STEP="$TMP_ROOT/removed-step.md"
python3 - "$HL" "$REMOVED_STEP" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines(keepends=True)
out = [l for l in lines if not l.startswith("5. **")]
open(dst, "w", encoding="utf-8").writelines(out)
PY
steps_in_order "$REMOVED_STEP"
[[ $? -ne 0 ]]; check "red-removed-step-fails" $?

echo
echo "=== RED: a dropped load-bearing token must fail has_tokens ==="
DROPPED_TOKEN="$TMP_ROOT/dropped-token.md"
sed 's/circuit-breaker/circuit breaker thing/g' "$HL" > "$DROPPED_TOKEN"
has_tokens "$DROPPED_TOKEN" "${HL_TOKENS[@]}"
[[ $? -ne 0 ]]; check "red-dropped-token-fails" $?

echo
echo "=== RED: clean copies still pass (mutation harness isn't just always-red) ==="
CLEAN_COPY="$TMP_ROOT/clean.md"
cp "$HL" "$CLEAN_COPY"
steps_in_order "$CLEAN_COPY"; check "clean-copy-still-passes-order" $?
has_tokens "$CLEAN_COPY" "${HL_TOKENS[@]}"; check "clean-copy-still-passes-tokens" $?

echo
echo "=== (e) registry-drift.sh negative-trigger check (T-3) is satisfied by both skills ==="
grep -A5 '^description:' "$HL" | head -1 | grep -q 'NOT '; check "harness-loop-has-negative-trigger" $?
grep -A5 '^description:' "$LOOP" | head -1 | grep -q 'NOT '; check "loop-has-negative-trigger" $?

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
