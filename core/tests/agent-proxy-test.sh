#!/usr/bin/env bash
# agent-proxy-test.sh — verify core/hooks/agent-proxy.sh deny judgement.
#
# The deny decision must come from parsed JSON (hookSpecificOutput.permissionDecision
# or top-level permissionDecision), not a text grep: whitespace/newlines around the
# colon must not let a denied command run. Unparseable output keeps the historical
# fail-open behaviour (command runs).
#
# Covers: one-line / pretty-printed / space-before-colon / top-level deny => blocked;
# "ask" / "allow" / empty / non-JSON output => command runs.
#
# Usage: bash core/tests/agent-proxy-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/hooks/agent-proxy.sh"

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

TMP_DIR="$(mktemp -d)" || exit 1
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

PROJ="$TMP_DIR/proj"
mkdir -p "$PROJ/.claude/hooks"
git -C "$PROJ" init -q
# Stub hook: prints whatever is in $PROJ/stub-out.
cat > "$PROJ/.claude/hooks/pre-tool-guard.sh" <<'STUB'
#!/usr/bin/env bash
cat "$(dirname "$0")/../../stub-out"
STUB
chmod +x "$PROJ/.claude/hooks/pre-tool-guard.sh"
MARK="$TMP_DIR/ran"

# run_case <stub-output> -> sets RC; MARK exists iff the command ran
run_case() {
  rm -f "$MARK"
  printf '%s' "$1" > "$PROJ/stub-out"
  (cd "$PROJ" && bash "$SCRIPT" "touch $MARK") >/dev/null 2>&1
  RC=$?
}
expect_blocked() {
  run_case "$2"
  [[ $RC -eq 1 && ! -e "$MARK" ]]; check "$1" $?
}
expect_runs() {
  run_case "$2"
  [[ $RC -eq 0 && -e "$MARK" ]]; check "$1" $?
}

expect_blocked "one-line deny blocks" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"no"}}'
expect_blocked "pretty-printed deny blocks" \
  $'{\n  "hookSpecificOutput": {\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "no"\n  }\n}'
expect_blocked "space before colon / newline after colon blocks" \
  $'{"hookSpecificOutput": {"permissionDecision" :\n "deny"}}'
expect_blocked "top-level permissionDecision deny blocks" \
  '{"permissionDecision":"deny","permissionDecisionReason":"no"}'
expect_runs "ask passes" \
  '{"hookSpecificOutput":{"permissionDecision":"ask"}}'
expect_runs "allow passes" \
  '{"hookSpecificOutput":{"permissionDecision":"allow"}}'
expect_runs "empty output passes" ''
expect_runs "non-JSON output passes (fail-open, unchanged)" 'permissionDecision: deny'

echo "agent-proxy-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
