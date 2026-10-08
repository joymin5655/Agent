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
# shellcheck disable=SC2016  # literal backticks in the advisory text are matched on purpose
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

evt() { # evt <tool_name> <subagent_type> [model] [effort] [prompt]
  python3 - "$@" <<'PY'
import json, sys
a = sys.argv[1:] + [""] * 5
ti = {"subagent_type": a[1], "prompt": a[4] or "x"}
if a[2]:
    ti["model"] = a[2]
if a[3]:
    ti["effort"] = a[3]
sys.stdout.write(json.dumps({"event": "PreToolUse", "tool_name": a[0], "tool_input": ti}))
PY
}

echo "=== leak case: unpinned dispatch -> advisory ==="
expect_warn "a1-unpinned-general-purpose-warns" "$(evt Task general-purpose)"
expect_warn "a2-unpinned-explore-warns"          "$(evt Agent Explore)"
expect_warn "a3-namespaced-unpinned-warns"       "$(evt Task agent-harness:general-purpose)"

echo
echo "=== silent cases: not a leak ==="
expect_silent "b1-model-and-effort-silent"           "$(evt Task Explore sonnet low)"
expect_silent "b2-pinned-specialist-silent"       "$(evt Task code-reviewer)"
expect_silent "b3-namespaced-pinned-silent"       "$(evt Agent agent-harness:security-reviewer)"
expect_silent "b4-plan-inherit-silent"            "$(evt Agent Plan)"
expect_silent "b5-pinned-with-override-silent"    "$(evt Task code-reviewer haiku)"
expect_silent "b6-pinned-risk-prompt-silent"      "$(evt Task security-reviewer "" "" "audit the auth module")"

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
echo "=== effort note (W6): only when a risk area is named; no general missing-effort nudge ==="
# nobj <out>: number of emitted JSON objects (a double emit must fail)
nobj() { printf '%s' "$1" | python3 -c '
import json, sys
d, s, n, i = json.JSONDecoder(), sys.stdin.read(), 0, 0
while i < len(s):
    if s[i].isspace():
        i += 1
        continue
    _, i = d.raw_decode(s, i)
    n += 1
print(n)'; }
# rawrun <tool_input-json> [tool_name]: build an event around a raw tool_input
rawrun() { run "{\"event\":\"PreToolUse\",\"tool_name\":\"${2:-Task}\",\"tool_input\":$1}"; }

# g1 (regression guard + the key noise test, red on the first W6 staging): model present,
# effort missing, no risk wording -> silent, exactly the pre-W6 behavior.
expect_silent "g1-model-present-no-effort-no-risk-silent" "$(evt Task Explore sonnet "" "rename a variable")"
# g2: risk wording + no effort -> one note recommending high, model present
run "$(evt Task Explore sonnet "" "review the auth token handling")"
if [[ "$RC" -eq 0 && "$(nobj "$OUT")" == 1 && "$OUT" == *'effort: high'* && "$OUT" == *"risk area"* && "$OUT" != *'no call-time `model`'* ]]; then ok "g2-risk-prompt-note-only"; else bad "g2" "rc=$RC out=$OUT"; fi
# g3: model missing + risk + no effort -> ONE object carrying both parts
run "$(evt Task general-purpose "" "" "fix the migration race condition")"
if [[ "$RC" -eq 0 && "$(nobj "$OUT")" == 1 && "$OUT" == *'no call-time `model`'* && "$OUT" == *'effort: high'* ]]; then ok "g3-model-and-risk-one-combined-object"; else bad "g3" "rc=$RC out=$OUT"; fi
# g4: model missing, no risk -> old advisory only (no effort text)
run "$(evt Task general-purpose "" "" "tidy the README")"
if [[ "$(nobj "$OUT")" == 1 && "$OUT" == *'no call-time `model`'* && "$OUT" != *"effort"* ]]; then ok "g4-model-missing-no-risk-model-part-only"; else bad "g4" "$OUT"; fi
# g5: valid effort -> no effort note even on risk wording (regression guard)
expect_silent "g5-risk-with-effort-silent" "$(evt Agent general-purpose sonnet high "migration work")"
for e in low medium high xhigh max HIGH " high "; do
  expect_silent "g5b-effort-[$e]-accepted" "$(evt Task Explore sonnet "$e" "fix the auth bug")"
done
# g6: invalid effort values count as missing -> the risk note fires
for v in '"turbo"' '5' '["high"]' '"  "' 'null' 'true'; do
  rawrun "{\"subagent_type\":\"Explore\",\"model\":\"sonnet\",\"effort\":$v,\"prompt\":\"fix the auth bug\"}"
  if [[ "$RC" -eq 0 && "$(nobj "$OUT")" == 1 && "$OUT" == *'effort: high'* ]]; then ok "g6-invalid-effort-$v-counts-as-missing"; else bad "g6-$v" "rc=$RC out=$OUT"; fi
done
# g7: where the risk word lives
rawrun '{"subagent_type":"Explore","model":"sonnet","description":"audit storage layer","prompt":"look around"}'
if [[ "$OUT" == *'effort: high'* ]]; then ok "g7a-risk-word-only-in-description"; else bad "g7a" "$OUT"; fi
expect_silent "g7b-author-is-not-auth"        "$(evt Task Explore sonnet "" "ask the author about the bug")"
long="$(python3 -c 'print("x " * 300 + "security")')"
expect_silent "g7c-risk-word-beyond-500-char-prefix-silent" "$(evt Task Explore sonnet "" "$long")"
short="$(python3 -c 'print("x " * 100 + "security")')"
run "$(evt Task Explore sonnet "" "$short")"
if [[ "$OUT" == *'effort: high'* ]]; then ok "g7d-risk-word-inside-prefix-matches"; else bad "g7d" "$OUT"; fi
for w in security authentication authorization concurrency "race condition" deadlock storage database migration; do
  run "$(evt Task Explore sonnet "" "please handle the $w part")"
  if [[ "$OUT" == *'effort: high'* ]]; then ok "g7e-risk-word-[$w]"; else bad "g7e-$w" "$OUT"; fi
done
# g8: Plan and pinned specialists stay silent regardless of risk wording
expect_silent "g8a-plan-silent"   "$(evt Agent Plan "" "" "design the auth system")"
expect_silent "g8b-pinned-silent" "$(evt Task security-reviewer "" "" "audit the auth module")"
# g9: malformed tool_input shapes exit 0 silently
for ti in 'null' '"str"' '[1]' '5'; do
  rawrun "$ti"
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "g9-non-dict-tool_input-$ti-silent"; else bad "g9-$ti" "rc=$RC out=$OUT"; fi
done
# g10: never a decision key, always exit 0
all_ok=1
for j in "$(evt Task Explore sonnet "" "auth")" "$(evt Task general-purpose)" "$(evt Task general-purpose "" "" "auth migration")"; do
  run "$j"; [[ "$RC" -eq 0 && "$OUT" != *'"permissionDecision"'* && "$OUT" != *'"decision"'* ]] || all_ok=0
done
if [[ "$all_ok" -eq 1 ]]; then ok "g10-never-deny-or-ask"; else bad "g10" "decision key or nonzero rc"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
