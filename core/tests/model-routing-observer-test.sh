#!/usr/bin/env bash
# model-routing-observer-test.sh — verify core/hooks/model-routing-observer.py.
#
# Pure observer on PostToolUse Task|Agent: classifies each subagent dispatch's
# model choice and appends one JSONL record to the sink. Emits NOTHING on stdout
# (no decision, no systemMessage) and always exits 0 — observation must never
# steer or block. Verdicts:
#   override          — dispatch carried an explicit tool_input.model
#   pinned_specialist — subagent_type resolves to a master-registry agent id
#                       (bare or plugin-namespaced), whose frontmatter pin rules
#   inherit_top       — neither: the dispatch inherits the session's top model
#                       (the leak this observer exists to measure)
#
# Spend signal: every record carries prompt_chars (len of tool_input.prompt)
# and total_tokens (tool_response usage probe; null when absent).
#
# Seams: AGENT_MODEL_ROUTING_SINK (sink path), AGENT_REGISTRY_PATH (fixture
# registry), AGENT_SESSION_ID.
#
# Usage: bash core/tests/model-routing-observer-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/model-routing-observer.py"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
SINK="$WORK/model-routing.jsonl"
REG="$WORK/registry.json"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

cat > "$REG" <<'EOF'
{"agents": [{"id": "code-reviewer", "model": "sonnet"}, {"id": "security-reviewer", "model": "opus"}]}
EOF

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# run <json>  -> sets OUT, RC
run() {
  OUT="$(printf '%s' "$1" | env \
    AGENT_MODEL_ROUTING_SINK="$SINK" \
    AGENT_REGISTRY_PATH="$REG" \
    AGENT_SESSION_ID=test \
    python3 "$HOOK" 2>/dev/null)"
  RC=$?
}

# expect_verdict <name> <json> <verdict>  — record appended with that verdict, silent stdout, rc 0
expect_verdict() {
  local name="$1" json="$2" want="$3"
  local before after last
  before="$( [[ -f "$SINK" ]] && wc -l < "$SINK" || echo 0 )"
  run "$json"
  after="$( [[ -f "$SINK" ]] && wc -l < "$SINK" || echo 0 )"
  last="$( [[ -f "$SINK" ]] && tail -1 "$SINK" || echo '' )"
  if [[ "$RC" -eq 0 && -z "$OUT" && "$after" -eq $((before + 1)) && "$last" == *"\"verdict\": \"$want\""* ]]; then
    ok "$name (verdict=$want)"
  else
    bad "$name" "rc=$RC out='$OUT' lines=$before->$after last=$last"
  fi
}

# expect_silent_norecord <name> <json>
expect_silent_norecord() {
  local name="$1" json="$2"
  local before after
  before="$( [[ -f "$SINK" ]] && wc -l < "$SINK" || echo 0 )"
  run "$json"
  after="$( [[ -f "$SINK" ]] && wc -l < "$SINK" || echo 0 )"
  if [[ "$RC" -eq 0 && -z "$OUT" && "$after" -eq "$before" ]]; then
    ok "$name"
  else
    bad "$name" "rc=$RC out='$OUT' lines=$before->$after"
  fi
}

evt() { # evt <tool_name> <subagent_type> [model]
  if [[ -n "${3:-}" ]]; then
    printf '{"event":"PostToolUse","tool_name":"%s","tool_input":{"subagent_type":"%s","model":"%s","prompt":"x"}}' "$1" "$2" "$3"
  else
    printf '{"event":"PostToolUse","tool_name":"%s","tool_input":{"subagent_type":"%s","prompt":"x"}}' "$1" "$2"
  fi
}

echo "=== verdict classification ==="
expect_verdict "a1-explicit-model-is-override"        "$(evt Task Explore sonnet)"                      override
expect_verdict "a2-registry-id-is-pinned"             "$(evt Task code-reviewer)"                       pinned_specialist
expect_verdict "a3-namespaced-registry-id-is-pinned"  "$(evt Agent agent-harness:security-reviewer)"    pinned_specialist
expect_verdict "a4-unpinned-no-model-is-inherit-top"  "$(evt Task Explore)"                             inherit_top
expect_verdict "a5-plan-no-model-is-inherit-top"      "$(evt Agent Plan)"                               inherit_top
expect_verdict "a6-pinned-with-override-is-override"  "$(evt Task code-reviewer haiku)"                 override

echo
echo "=== record fields ==="
run "$(evt Task general-purpose opus)"
last="$(tail -1 "$SINK")"
for field in '"subagent_type": "general-purpose"' '"model": "opus"' '"session_id": "test"' '"ts"'; do
  if [[ "$last" == *"$field"* ]]; then ok "b-field-present [$field]"; else bad "b-field" "missing $field in $last"; fi
done

echo
echo "=== spend signal: prompt_chars + total_tokens ==="
run '{"event":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"Explore","prompt":"12345"},"tool_response":{"usage":{"total_tokens":777}}}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"prompt_chars": 5'* ]]; then ok "e1-prompt-chars-counted"; else bad "e1-prompt-chars" "$last"; fi
if [[ "$last" == *'"total_tokens": 777'* ]]; then ok "e2-usage-total-tokens-captured"; else bad "e2-usage-tokens" "$last"; fi
run '{"event":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"Explore","prompt":"x"},"tool_response":{"totalTokens":42}}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"total_tokens": 42'* ]]; then ok "e3-camelcase-usage-captured"; else bad "e3-camelcase" "$last"; fi
run "$(evt Task Explore)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"total_tokens": null'* ]]; then ok "e4-no-usage-is-null"; else bad "e4-no-usage" "$last"; fi
run '{"event":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"Explore"},"tool_response":"plain text"}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"prompt_chars": 0'* && "$last" == *'"total_tokens": null'* ]]; then ok "e5-missing-prompt-nonobj-response-safe"; else bad "e5-safety" "$last"; fi

echo
echo "=== non-targets and fail-open silence ==="
expect_silent_norecord "c1-non-dispatch-tool" '{"event":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
expect_silent_norecord "c2-exitplanmode"      '{"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{}}'
expect_silent_norecord "c3-missing-subagent"  '{"event":"PostToolUse","tool_name":"Task","tool_input":{"prompt":"x"}}'
run 'not json {['
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "c4-malformed-stdin-silent-rc0"; else bad "c4-malformed" "rc=$RC out=$OUT"; fi

echo
echo "=== registry fallback: unreadable registry never crashes, still records ==="
before="$(wc -l < "$SINK")"
OUT="$(printf '%s' "$(evt Task code-reviewer)" | env \
  AGENT_MODEL_ROUTING_SINK="$SINK" \
  AGENT_REGISTRY_PATH="$WORK/nonexistent.json" \
  AGENT_SESSION_ID=test \
  python3 "$HOOK" 2>/dev/null)"; RC=$?
after="$(wc -l < "$SINK")"
if [[ "$RC" -eq 0 && -z "$OUT" && "$after" -eq $((before + 1)) ]]; then
  ok "d1-missing-registry-still-records (falls back to inherit_top)"
else
  bad "d1-missing-registry" "rc=$RC out='$OUT' lines=$before->$after"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
