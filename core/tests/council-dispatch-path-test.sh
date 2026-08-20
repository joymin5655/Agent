#!/usr/bin/env bash
# council-dispatch-path-test.sh — verify skills/council-review/SKILL.md
# resolves core/infra/call-worker.sh from the plugin cache or the checkout,
# never from a bare cwd-relative path.
#
# Why this matters: a plugin install runs from CLAUDE_PLUGIN_ROOT, not the
# repo root a bare `bash core/infra/call-worker.sh` assumed — that path
# silently no-ops on a plugin install (docs/claude-plugin-install-lifecycle.md
# §7 item 1). This is a static check on the shipped SKILL.md text; it does not
# execute any dispatch (zero paid calls).
#
# Usage: bash core/tests/council-dispatch-path-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/council-review/SKILL.md"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

[[ -f "$SKILL" ]] || { echo "SKIP: $SKILL not found"; exit 2; }

# (a) no bare `bash core/infra/call-worker.sh` invocation left behind.
grep -qE '(^|[^"$/A-Za-z0-9_])bash core/infra/call-worker\.sh' "$SKILL"
[[ $? -ne 0 ]]; check "no-bare-call-worker-invocation" $?

# (b) the dispatch resolves via CLAUDE_PLUGIN_ROOT.
grep -q 'CLAUDE_PLUGIN_ROOT' "$SKILL"
check "resolves-via-claude-plugin-root" $?

# (c) a missing resolved path is guarded rather than trusted blind.
grep -qE '\[\[ -f "\$CW" \]\]' "$SKILL"
check "guards-missing-dispatcher-path" $?

# (d) the same defect class reaching the council surface through ANY other
# skill: `/wrap` step 1d also shells into council-threshold.sh, and a bare
# `bash core/...` there resolves against $PWD — the user's project on a
# plugin install, not the harness. Scoped to the two council dispatch
# scripts this test owns; the wider "skills shell into bare core/ paths" gap
# (7 files as of 2026-08-21) is tracked in
# docs/claude-plugin-install-lifecycle.md §7, not asserted here.
OFFENDERS="$(grep -rlE '(^|[^"$/A-Za-z0-9_])bash core/(infra|hooks)/(council-threshold\.sh|call-worker\.sh|council-escalation-gate\.py)' "$REPO_ROOT"/skills/*/SKILL.md 2>/dev/null || true)"
if [[ -z "$OFFENDERS" ]]; then
  check "no-skill-shells-into-bare-council-dispatch-path" 0
else
  echo "  offenders: $OFFENDERS"
  check "no-skill-shells-into-bare-council-dispatch-path" 1
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
