#!/usr/bin/env bash
# model-routing-advisor-test.sh — verify core/hooks/model-routing-advisor.py.
#
# Decision-time counterpart to model-routing-observer.py: fires PreToolUse on
# Task|Agent and emits ONE line of hookSpecificOutput.additionalContext when a
# dispatch is about to leak (no `model` override, not a registry-pinned
# specialist, not "Plan"). Every other case is silent. Never sets
# permissionDecision, never blocks, writes NO log of its own — the observer's
# sink is the sole measured record.
#
# Seams: AGENT_REGISTRY_PATH (fixture registry).
#
# Usage: bash core/tests/model-routing-advisor-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/model-routing-advisor.py"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
REG="$WORK/registry.json"
OBSERVER_SINK="$WORK/model-routing.jsonl"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

cat > "$REG" <<'EOF'
{"agents": [{"id": "code-reviewer", "model": "sonnet"}, {"id": "security-reviewer", "model": "opus"}]}
EOF

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# run <json>  -> sets OUT, RC
run() {
  OUT="$(printf '%s' "$1" | env \
    AGENT_REGISTRY_PATH="$REG" \
    AGENT_MODEL_ROUTING_SINK="$OBSERVER_SINK" \
    python3 "$HOOK" 2>/dev/null)"
  RC=$?
}

# expect_warn <name> <json>  — additionalContext warning emitted, rc 0
expect_warn() {
  local name="$1" json="$2"
  run "$json"
  if [[ "$RC" -eq 0 && "$OUT" == *"model-routing:"* && "$OUT" == *"additionalContext"* ]]; then
    ok "$name"
  else
    bad "$name" "rc=$RC out='$OUT'"
  fi
}

# expect_silent <name> <json>  — no stdout, rc 0
expect_silent() {
  local name="$1" json="$2"
  run "$json"
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then
    ok "$name"
  else
    bad "$name" "rc=$RC out='$OUT'"
  fi
}

evt() { # evt <tool_name> <subagent_type> [model]
  if [[ -n "${3:-}" ]]; then
    printf '{"event":"PreToolUse","tool_name":"%s","tool_input":{"subagent_type":"%s","model":"%s","prompt":"x"}}' "$1" "$2" "$3"
  else
    printf '{"event":"PreToolUse","tool_name":"%s","tool_input":{"subagent_type":"%s","prompt":"x"}}' "$1" "$2"
  fi
}

echo "=== leak case: unpinned dispatch -> advisory ==="
expect_warn "a1-unpinned-general-purpose-warns" "$(evt Task general-purpose)"
expect_warn "a2-unpinned-explore-warns"          "$(evt Agent Explore)"
expect_warn "a3-namespaced-unpinned-warns"       "$(evt Task agent-harness:general-purpose)"

echo
echo "=== silent cases: not a leak ==="
expect_silent "b1-model-override-silent"          "$(evt Task Explore sonnet)"
expect_silent "b2-pinned-specialist-silent"       "$(evt Task code-reviewer)"
expect_silent "b3-namespaced-pinned-silent"       "$(evt Agent agent-harness:security-reviewer)"
expect_silent "b4-plan-inherit-silent"            "$(evt Agent Plan)"
expect_silent "b5-pinned-with-override-silent"    "$(evt Task code-reviewer haiku)"

echo
echo "=== non-targets and fail-open silence ==="
expect_silent "c1-non-dispatch-tool"  '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
expect_silent "c2-write-tool"         '{"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"x.py"}}'
expect_silent "c3-missing-subagent"   '{"event":"PreToolUse","tool_name":"Task","tool_input":{"prompt":"x"}}'
expect_silent "c4-empty-subagent"     '{"event":"PreToolUse","tool_name":"Task","tool_input":{"subagent_type":"","prompt":"x"}}'
run 'not json {['
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "c5-malformed-stdin-silent-rc0"; else bad "c5-malformed" "rc=$RC out=$OUT"; fi
run ''
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "c6-empty-stdin-silent-rc0"; else bad "c6-empty-stdin" "rc=$RC out=$OUT"; fi

echo
echo "=== registry fallback: unreadable registry never crashes, still warns (fails open to inherit_top) ==="
OUT="$(printf '%s' "$(evt Task code-reviewer)" | env \
  AGENT_REGISTRY_PATH="$WORK/nonexistent.json" \
  python3 "$HOOK" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == *"model-routing:"* ]]; then
  ok "d1-missing-registry-falls-back-to-warn"
else
  bad "d1-missing-registry" "rc=$RC out='$OUT'"
fi

echo
echo "=== no observation-log contamination: the advisor writes nothing of its own ==="
BEFORE_EXISTS=0
[[ -f "$OBSERVER_SINK" ]] && BEFORE_EXISTS=1
run "$(evt Task general-purpose)"
run "$(evt Agent Explore)"
run "$(evt Task code-reviewer)"
AFTER_EXISTS=0
[[ -f "$OBSERVER_SINK" ]] && AFTER_EXISTS=1
if [[ "$BEFORE_EXISTS" -eq 0 && "$AFTER_EXISTS" -eq 0 ]]; then
  ok "e1-no-sink-file-created"
else
  bad "e1-no-sink-file-created" "sink appeared: before=$BEFORE_EXISTS after=$AFTER_EXISTS"
fi
# No AGENT_MODEL_ROUTING_SINK in env at all — still no log anywhere the hook could reach.
LOGDIR="$WORK/.agent/logs"
if [[ ! -d "$LOGDIR" ]]; then
  ok "e2-no-default-log-dir-created"
else
  bad "e2-no-default-log-dir-created" "$LOGDIR exists"
fi

echo
echo "=== RED: advisory message never sets a decision (advisory only, never enforcement) ==="
run "$(evt Task general-purpose)"
if [[ "$OUT" != *"permissionDecision"* ]]; then
  ok "f1-no-permission-decision-in-output"
else
  bad "f1-no-permission-decision-in-output" "$OUT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
