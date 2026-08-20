#!/usr/bin/env bash
# worker-setup-skill-test.sh — static contract checks on skills/worker-setup/SKILL.md.
#
# This is a pure text-shape battery: frontmatter completeness, plugin-cache-safe
# dispatch (no bare `bash core/infra/...` invocation), vendor coverage, and the
# no-model-ids hygiene rule shared with core/tests/backends-schema-test.sh. It
# never executes the skill or any worker CLI — zero paid calls.
#
# Usage: bash core/tests/worker-setup-skill-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/worker-setup/SKILL.md"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

[[ -f "$SKILL" ]] || { echo "SKIP: $SKILL not found"; exit 2; }

echo "=== frontmatter ==="
FM="$(awk '/^---$/{c++; if (c==2) exit} c==1' "$SKILL")"
grep -q '^name: worker-setup$' <<< "$FM";        check "frontmatter-has-name" $?
grep -q '^description:' <<< "$FM";               check "frontmatter-has-description" $?
grep -q '^when_to_use:' <<< "$FM";                check "frontmatter-has-when-to-use" $?
grep -q '^tools:' <<< "$FM";                      check "frontmatter-has-tools" $?
grep -q 'NOT ' <<< "$FM";                         check "description-has-negative-trigger" $?

echo
echo "=== plugin-cache-safe dispatch ==="
# no bare cwd-relative invocation of a harness script
grep -qE '(^|[^"$/A-Za-z0-9_])bash core/infra/' "$SKILL"
[[ $? -ne 0 ]]; check "no-bare-core-infra-invocation" $?
grep -q 'CLAUDE_PLUGIN_ROOT' "$SKILL";            check "resolves-via-claude-plugin-root" $?

echo
echo "=== vendor coverage ==="
grep -qi 'codex' "$SKILL";       check "mentions-codex" $?
grep -qi 'antigravity' "$SKILL"; check "mentions-antigravity" $?
grep -qi 'grok' "$SKILL";        check "mentions-grok" $?
grep -qi 'kiro' "$SKILL";        check "mentions-kiro" $?

echo
echo "=== no model IDs (tier policy lives in vendor profiles, not here) ==="
grep -Eq '(gpt|claude|sonnet|opus|haiku|fable|gemini|grok)-[0-9]' "$SKILL"
[[ $? -ne 0 ]]; check "no-model-ids" $?

echo
echo "=== does not collect or echo credentials ==="
grep -q 'KIRO_API_KEY' "$SKILL";  check "mentions-kiro-api-key" $?
grep -qi 'never echo\|never.*store\|instruct.*not collect\|instruct, don.t collect' "$SKILL"
check "states-credential-non-collection-policy" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
