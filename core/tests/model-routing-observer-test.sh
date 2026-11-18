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
RUNS="$WORK/subagent-runs.jsonl"
REG="$WORK/registry.json"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

cat > "$REG" <<'EOF'
{"agents": [{"id": "code-reviewer", "model": "sonnet"}, {"id": "security-reviewer", "model": "fable"}]}
EOF

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# run <json>  -> sets OUT, RC
run() {
  OUT="$(printf '%s' "$1" | env \
    AGENT_MODEL_ROUTING_SINK="$SINK" \
    AGENT_SUBAGENT_RUNS_SINK="$RUNS" \
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
echo "=== W2-3: effort field ==="
run '{"event":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"Explore","prompt":"x","effort":"high"}}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"effort": "high"'* ]]; then ok "f1-effort-recorded"; else bad "f1-effort-recorded" "$last"; fi
run "$(evt Task Explore)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"effort": null'* ]]; then ok "f2-no-effort-is-null"; else bad "f2-no-effort-is-null" "$last"; fi

echo
echo "=== W2-3: fable-family models classify TOP, same as opus ==="
run "$(evt Task Explore fable)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"tier": "TOP"'* ]]; then ok "g1-override-fable-is-top"; else bad "g1-override-fable-is-top" "$last"; fi
run "$(evt Task Explore claude-fable-5-1)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"tier": "TOP"'* ]]; then ok "g2-override-fable-alias-is-top"; else bad "g2-override-fable-alias-is-top" "$last"; fi
run "$(evt Task Explore opus)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"tier": "TOP"'* ]]; then ok "g3-override-opus-is-top"; else bad "g3-override-opus-is-top" "$last"; fi
run "$(evt Agent agent-harness:security-reviewer)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"tier": "TOP"'* ]]; then ok "g4-pinned-fable-specialist-is-top"; else bad "g4-pinned-fable-specialist-is-top" "$last"; fi
run "$(evt Task Explore sonnet)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"tier": "MID"'* ]]; then ok "g5-override-sonnet-is-mid"; else bad "g5-override-sonnet-is-mid" "$last"; fi
run "$(evt Task Explore)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"tier": "unknown"'* ]]; then ok "g6-inherit-top-tier-is-unknown"; else bad "g6-inherit-top-tier-is-unknown" "$last"; fi

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
  AGENT_SUBAGENT_RUNS_SINK="$RUNS" \
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
echo "=== session ids: runtime UUID (stdin) + AGENT_SESSION_ID ==="
run '{"event":"PostToolUse","session_id":"uuid-1","tool_name":"Task","tool_input":{"subagent_type":"Explore","prompt":"x"}}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"session_id": "uuid-1"'* && "$last" == *'"agent_session_id": "test"'* ]]; then
  ok "s1-stdin-uuid-preferred-env-kept"
else bad "s1-stdin-uuid" "$last"; fi
run "$(evt Task Explore)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"session_id": "test"'* && "$last" == *'"agent_session_id": "test"'* ]]; then
  ok "s2-no-stdin-uuid-falls-back-to-env"
else bad "s2-fallback" "$last"; fi
run '{"hook_event_name":"SubagentStop","session_id":"uuid-2","agent_type":"Explore","agent_id":"a1"}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"session_id": "uuid-2"'* && "$last" == *'"agent_session_id": "test"'* ]]; then
  ok "s3-subagent-event-dual-ids"
else bad "s3-subagent-event" "$last"; fi

echo
echo "=== subagent lifecycle rows are not dispatch verdicts (86% inherit_top inflation) ==="
run '{"hook_event_name":"SubagentStart","agent_type":"","agent_id":"i1"}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"verdict": "unclassified"'* && "$last" != *inherit_top* ]]; then ok "r1-internal-agent-event-not-inherit-top"; else bad "r1-internal-agent" "$last"; fi
run '{"hook_event_name":"SubagentStop","agent_type":"agent-harness:code-reviewer","agent_id":"i2"}'
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"verdict": "pinned_specialist"'* ]]; then ok "r2-registry-agent-event-still-pinned"; else bad "r2-pinned-event" "$last"; fi
rm -f "$RUNS"
run '{"hook_event_name":"SubagentStart","agent_type":"Explore","agent_id":"i3"}'
if [[ ! -s "$RUNS" ]]; then ok "r3-start-writes-no-measured-run"; else bad "r3-start-no-run" "$(cat "$RUNS")"; fi

echo
echo "=== PostToolUse record: resolved_model + env_subagent_model (measured, additive) ==="
OUT="$(printf '%s' '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore","prompt":"x"},"tool_response":{"resolvedModel":"claude-sonnet-5-5"}}' | env \
  AGENT_MODEL_ROUTING_SINK="$SINK" AGENT_SUBAGENT_RUNS_SINK="$RUNS" AGENT_REGISTRY_PATH="$REG" \
  CLAUDE_CODE_SUBAGENT_MODEL=sonnet python3 "$HOOK" 2>/dev/null)"; RC=$?
last="$(tail -1 "$SINK")"
if [[ "$RC" -eq 0 && -z "$OUT" && "$last" == *'"resolved_model": "claude-sonnet-5-5"'* && "$last" == *'"env_subagent_model": "sonnet"'* ]]; then
  ok "t1-resolved-model-and-env-recorded"; else bad "t1-resolved" "rc=$RC $last"; fi
run "$(evt Task Explore)"
last="$(tail -1 "$SINK")"
if [[ "$last" == *'"resolved_model": null'* ]]; then ok "t2-no-resolved-model-is-null"; else bad "t2-null" "$last"; fi

echo
echo "=== measured run record: SubagentStop -> user-level subagent-runs sink ==="
PROJ="$WORK/proj"; SESS="$PROJ/sess-1"; mkdir -p "$SESS/subagents"
TRANS="$SESS/subagents/agent-a1.jsonl"
cat > "$TRANS" <<'EOF'
{"type":"user","timestamp":"2026-11-18T10:00:00.000Z","message":{"role":"user","content":"SECRET-PROMPT-TEXT"}}
{"type":"assistant","timestamp":"2026-11-18T10:00:05.000Z","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"SECRET-ANSWER-TEXT"}]}}
{"type":"assistant","timestamp":"2026-11-18T10:00:20.000Z","effort":"high","message":{"model":"claude-opus-5-5","content":[]}}
{"type":"assistant","timestamp":"2026-11-18T10:01:00.000Z","message":{"model":"claude-sonnet-5-5","content":[]}}
EOF
printf '{"agentType":"agent-harness:security-reviewer","launchedWithDefaults":true,"effort":"low","model":"haiku"}' > "$SESS/subagents/agent-a1.meta.json"
stop_evt() { printf '{"hook_event_name":"SubagentStop","session_id":"sess-1","transcript_path":"%s","agent_type":"%s","agent_id":"%s","agent_transcript_path":"%s","last_assistant_message":"SECRET-ANSWER-TEXT"}' "$PROJ/sess-1.jsonl" "$1" "$2" "$3"; }
run "$(stop_evt agent-harness:security-reviewer a1 "$TRANS")"
last="$(tail -1 "$RUNS" 2>/dev/null)"
if [[ "$RC" -eq 0 && -z "$OUT" ]] && printf '%s' "$last" | python3 -c '
import json,sys
r=json.load(sys.stdin)
want={"ts","agent_type","agent_id","model","effort","requested_model","launched_with_defaults","started","ended","duration_s","turns","outcome","origin"}
assert set(r)==want, sorted(set(r)^want)
assert r["model"]=="claude-opus-5-5" and r["effort"]=="high" and r["requested_model"]=="haiku", r
assert r["launched_with_defaults"] is True and r["turns"]==3 and r["duration_s"]==60, r
assert r["started"]=="2026-11-18T10:00:00+00:00" and r["ended"]=="2026-11-18T10:01:00+00:00", r
assert r["outcome"]=="ok" and r["agent_id"]=="a1", r
'; then ok "m1-run-record-keys-and-values"; else bad "m1-run-record" "rc=$RC last=$last"; fi
if ! grep -q "SECRET" "$RUNS"; then ok "m2-no-prompt-or-answer-content"; else bad "m2-content-leak" "$(cat "$RUNS")"; fi

# 위치 규칙 대체: agent_transcript_path 가 없으면 transcript_path + agent_id 로 찾는다.
cp "$TRANS" "$SESS/subagents/agent-a2.jsonl"; printf '{"agentType":"Explore","effort":"medium"}' > "$SESS/subagents/agent-a2.meta.json"
run "$(printf '{"hook_event_name":"SubagentStop","session_id":"sess-1","transcript_path":"%s","agent_type":"Explore","agent_id":"a2"}' "$PROJ/sess-1.jsonl")"
last="$(tail -1 "$RUNS")"
if [[ "$last" == *'"agent_id": "a2"'* && "$last" == *'"turns": 3'* && "$last" == *'"requested_model": null'* && "$last" == *'"launched_with_defaults": null'* ]]; then
  ok "m3-fallback-locates-by-transcript-path-and-agent-id"; else bad "m3-fallback" "$last"; fi

# effort: 줄에 없으면 meta.effort, 둘 다 없으면 null
printf '%s\n' '{"type":"assistant","timestamp":"2026-11-18T10:00:00.000Z","message":{"model":"claude-haiku-5-5"}}' > "$SESS/subagents/agent-a3.jsonl"
printf '{"agentType":"Explore","effort":"medium"}' > "$SESS/subagents/agent-a3.meta.json"
run "$(stop_evt Explore a3 "$SESS/subagents/agent-a3.jsonl")"
last="$(tail -1 "$RUNS")"
if [[ "$last" == *'"effort": "medium"'* && "$last" == *'"duration_s": 0'* ]]; then ok "m4-effort-falls-back-to-meta"; else bad "m4-effort-meta" "$last"; fi
printf '{"agentType":"Explore"}' > "$SESS/subagents/agent-a3.meta.json"
run "$(stop_evt Explore a3 "$SESS/subagents/agent-a3.jsonl")"
last="$(tail -1 "$RUNS")"
if [[ "$last" == *'"effort": null'* ]]; then ok "m5-no-effort-anywhere-is-null"; else bad "m5-effort-null" "$last"; fi

# outcome: 실제 기록의 오류 표시(isApiErrorMessage)가 있을 때만 error
printf '%s\n' '{"type":"assistant","timestamp":"2026-11-18T10:00:00.000Z","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>"}}' > "$SESS/subagents/agent-a4.jsonl"
run "$(stop_evt Explore a4 "$SESS/subagents/agent-a4.jsonl")"
last="$(tail -1 "$RUNS")"
if [[ "$last" == *'"outcome": "error"'* ]]; then ok "m6-api-error-marker-is-error"; else bad "m6-error" "$last"; fi

# 누락·깨진 기록: 조용히 넘어가고 outcome unknown 한 줄
before="$(wc -l < "$RUNS")"
run "$(stop_evt Explore a5 "$SESS/subagents/agent-none.jsonl")"
last="$(tail -1 "$RUNS")"
after="$(wc -l < "$RUNS")"
if [[ "$RC" -eq 0 && -z "$OUT" && "$after" -eq $((before + 1)) && "$last" == *'"outcome": "unknown"'* && "$last" == *'"model": null'* && "$last" == *'"turns": 0'* ]]; then
  ok "m7-missing-transcript-unknown-rc0"; else bad "m7-missing" "rc=$RC $last"; fi
printf 'not json\n{"type":"assistant","message":{"model":"claude-opus-5-5"}}\n' > "$SESS/subagents/agent-a6.jsonl"
run "$(stop_evt Explore a6 "$SESS/subagents/agent-a6.jsonl")"
last="$(tail -1 "$RUNS")"
if [[ "$RC" -eq 0 && "$last" == *'"model": "claude-opus-5-5"'* && "$last" == *'"turns": 1'* ]]; then ok "m8-malformed-line-skipped"; else bad "m8-malformed" "$last"; fi

# 큰 파일 건너뛰기: 시험은 상한을 env 로 낮춘다(실제 64MB 파일을 만들지 않는다).
OUT="$(printf '%s' "$(stop_evt Explore a1 "$TRANS")" | env AGENT_MODEL_ROUTING_SINK="$SINK" AGENT_SUBAGENT_RUNS_SINK="$RUNS" \
  AGENT_REGISTRY_PATH="$REG" AGENT_SUBAGENT_RUNS_MAX_BYTES=10 python3 "$HOOK" 2>/dev/null)"; RC=$?
last="$(tail -1 "$RUNS")"
if [[ "$RC" -eq 0 && "$last" == *'"outcome": "unknown"'* && "$last" == *'"turns": 0'* ]]; then ok "m9-oversize-transcript-skipped-unknown"; else bad "m9-oversize" "rc=$RC $last"; fi

# 기본 상한은 64MB
if grep -q "64 \* 1024 \* 1024" "$HOOK"; then ok "m10-default-cap-is-64mb"; else bad "m10-cap" "64MB constant missing"; fi

# 사용자 단위 기록 쓰기 실패(경로가 파일 아래)여도 프로젝트별 기록은 남고 rc 0
BLOCK="$WORK/blockfile"; : > "$BLOCK"
before="$(wc -l < "$SINK")"
OUT="$(printf '%s' "$(stop_evt Explore a1 "$TRANS")" | env AGENT_MODEL_ROUTING_SINK="$SINK" AGENT_SUBAGENT_RUNS_SINK="$BLOCK/x/runs.jsonl" \
  AGENT_REGISTRY_PATH="$REG" python3 "$HOOK" 2>/dev/null)"; RC=$?
after="$(wc -l < "$SINK")"
if [[ "$RC" -eq 0 && -z "$OUT" && "$after" -eq $((before + 1)) ]]; then ok "m11-runs-sink-failure-silent-project-row-kept"; else bad "m11-sink-fail" "rc=$RC out=$OUT $before->$after"; fi

# 프로젝트별 기록 쓰기 실패(경로가 파일 아래)여도 사용자 단위 실측 줄은 남고 rc 0
before="$(wc -l < "$RUNS")"
OUT="$(printf '%s' "$(stop_evt Explore a1 "$TRANS")" | env AGENT_MODEL_ROUTING_SINK="$BLOCK/x/routing.jsonl" AGENT_SUBAGENT_RUNS_SINK="$RUNS" \
  AGENT_REGISTRY_PATH="$REG" python3 "$HOOK" 2>/dev/null)"; RC=$?
after="$(wc -l < "$RUNS")"
if [[ "$RC" -eq 0 && -z "$OUT" && "$after" -eq $((before + 1)) ]]; then ok "m12-project-sink-failure-silent-runs-row-kept"; else bad "m12-proj-fail" "rc=$RC out=$OUT $before->$after"; fi

# 한 응답이 내용 조각마다 여러 줄 — 고유 message.id 만 세고 <synthetic> 줄은 뺀다
{
  for _ in 1 2 3; do printf '%s\n' '{"type":"assistant","timestamp":"2026-11-18T10:00:00.000Z","message":{"id":"msg_1","model":"claude-opus-5-5"}}'; done
  for i in 1 2 3; do printf '%s\n' '{"type":"assistant","timestamp":"2026-11-18T10:00:01.000Z","message":{"id":"syn_'$i'","model":"<synthetic>"}}'; done
  printf '%s\n' '{"type":"assistant","timestamp":"2026-11-18T10:00:02.000Z","message":{"id":"msg_2","model":"claude-opus-5-5"}}'
} > "$SESS/subagents/agent-a7.jsonl"
run "$(stop_evt Explore a7 "$SESS/subagents/agent-a7.jsonl")"
last="$(tail -1 "$RUNS")"
if printf '%s' "$last" | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["turns"]==2 and r["model"]=="claude-opus-5-5" and r["outcome"]=="ok", r
'; then ok "m13-turns-count-unique-message-ids-skip-synthetic"; else bad "m13-turns" "$last"; fi

# agent_id 에 경로 조각이 있으면 대체 경로를 만들지 않는다
mkdir -p "$SESS/subagents/agent-zz"
printf '%s\n' '{"type":"assistant","timestamp":"2026-11-18T10:00:00.000Z","message":{"model":"claude-opus-5-5"}}' > "$SESS/subagents/decoy.jsonl"
run "$(printf '{"hook_event_name":"SubagentStop","session_id":"sess-1","transcript_path":"%s","agent_type":"Explore","agent_id":"zz/../decoy"}' "$PROJ/sess-1.jsonl")"
last="$(tail -1 "$RUNS")"
if [[ "$RC" -eq 0 && "$last" == *'"turns": 0'* && "$last" == *'"outcome": "unknown"'* ]]; then ok "m14-agent-id-path-injection-rejected"; else bad "m14-inject" "rc=$RC $last"; fi

# 위조된 입력 방어: FIFO·/dev/zero 는 열지 않고 2초 안에 rc 0 으로 끝난다
timed_run() {  # $1 = 이벤트 JSON; 2초 안에 안 끝나면 rc 124
  printf '%s' "$1" | env AGENT_MODEL_ROUTING_SINK="$SINK" AGENT_SUBAGENT_RUNS_SINK="$RUNS" \
    AGENT_REGISTRY_PATH="$REG" python3 -c '
import subprocess, sys
try:
    sys.exit(subprocess.run([sys.executable, sys.argv[1]], input=sys.stdin.buffer.read(),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
' "$HOOK"
}
FIFO="$SESS/subagents/agent-fifo.jsonl"; mkfifo "$FIFO"
timed_run "$(stop_evt Explore a8 "$FIFO")"; RC=$?
last="$(tail -1 "$RUNS")"
if [[ "$RC" -eq 0 && "$last" == *'"agent_id": "a8"'* && "$last" == *'"turns": 0'* ]]; then ok "m15-fifo-transcript-skipped-no-hang"; else bad "m15-fifo" "rc=$RC $last"; fi
timed_run "$(stop_evt Explore a9 /dev/zero)"; RC=$?
last="$(tail -1 "$RUNS")"
if [[ "$RC" -eq 0 && "$last" == *'"agent_id": "a9"'* && "$last" == *'"turns": 0'* ]]; then ok "m16-devzero-transcript-skipped"; else bad "m16-zero" "rc=$RC $last"; fi
# meta.json 이 FIFO 여도 멈추지 않는다
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5"}}' > "$SESS/subagents/agent-a10.jsonl"
mkfifo "$SESS/subagents/agent-a10.meta.json"
timed_run "$(stop_evt Explore a10 "$SESS/subagents/agent-a10.jsonl")"; RC=$?
last="$(tail -1 "$RUNS")"
if [[ "$RC" -eq 0 && "$last" == *'"agent_id": "a10"'* ]]; then ok "m17-fifo-meta-skipped-no-hang"; else bad "m17-meta-fifo" "rc=$RC $last"; fi

# 본문 복사 금지를 구조로: 긴 임의 문자열은 timestamp·model 칸에 들어가지 않는다
python3 - "$SESS/subagents/agent-a11.jsonl" "$SESS/subagents/agent-a11.meta.json" <<'PY'
import json, sys
junk = "Z" * 100 + " \n " + "W" * 100
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "assistant", "timestamp": junk, "message": {"id": "m1", "model": junk}}) + "\n")
with open(sys.argv[2], "w") as f:
    json.dump({"model": junk}, f)
PY
run "$(stop_evt Explore a11 "$SESS/subagents/agent-a11.jsonl")"
last="$(tail -1 "$RUNS")"
if [[ "$RC" -eq 0 && "$last" != *ZZZZZ* && "$last" != *WWWWW* ]] && printf '%s' "$last" | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["started"] is None and r["ended"] is None and r["model"] is None and r["requested_model"] is None, r
assert r["turns"]==1, r
'; then ok "m18-freeform-strings-not-copied-null"; else bad "m18-freeform" "$last"; fi

# 새로 만든 사용자 단위 기록 파일은 0600, 새 폴더는 0700
FRESH="$WORK/fresh-dir/runs.jsonl"
printf '%s' "$(stop_evt Explore a1 "$TRANS")" | env AGENT_MODEL_ROUTING_SINK="$SINK" AGENT_SUBAGENT_RUNS_SINK="$FRESH" \
  AGENT_REGISTRY_PATH="$REG" python3 "$HOOK" >/dev/null 2>&1
modeof() { python3 -c 'import os,sys,stat; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }
fmode="$(modeof "$FRESH")"; dmode="$(modeof "$WORK/fresh-dir")"
if [[ "$fmode" == "600" && "$dmode" == "700" ]]; then ok "m19-new-runs-file-0600-dir-0700"; else bad "m19-perm" "file=$fmode dir=$dmode"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
