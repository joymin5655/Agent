#!/usr/bin/env bash
# claude-extended-events-test.sh — verify the Claude-only extended hook events
# (W3-2): PostToolUseFailure -> circuit-breaker.py, SessionEnd -> session-close.sh,
# PreModelSwitch/PostModelSwitch -> session-tier-observer.py, SubagentStart/SubagentStop
# -> model-routing-observer.py. WorktreeCreate/WorktreeRemove are deliberately NOT
# wired (a WorktreeCreate hook replaces git's worktree creation — docs/hook-protocol.md
# §12); §3 asserts they stay unwired while still covering r4-mutex-check.sh's
# retained worktree branch as script logic.
#
# NOTE: core/tests/adapter-parity.sh covers ONLY the canonical 5 events
# (PreToolUse/PostToolUse/SessionStart/Stop/UserPromptSubmit — docs/hook-protocol.md
# §1). These 6 wired events are Claude-only extensions layered on top; they cannot
# regress cross-AI parity because Codex/Gemini never see them. This battery is
# their only coverage.
#
# Each hook is run through the REAL adapter (adapters/claude-code/adapter.sh),
# which is a pure pass-through (exec's the named core hook with stdin/stdout
# untouched) — so this battery exercises the exact command Claude Code would
# invoke, not the core hook directly.
#
# Usage: bash core/tests/claude-extended-events-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTER="$REPO_ROOT/adapters/claude-code/adapter.sh"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }
check() { local name="$1" cond="$2" detail="${3:-}"; if [[ "$cond" -eq 0 ]]; then ok "$name"; else bad "$name" "$detail"; fi; }

# ---------------------------------------------------------------------------
# 1. PostToolUseFailure -> circuit-breaker.py
#    Fixture: tool_name, tool_input, tool_use_id, error (docs, 2026-09-26).
#    Below threshold -> empty stdout, exit 0. Real repo-tree cwd (not $WORK) so
#    the adapter can resolve HOOK_PATH; state is isolated via env var.
# ---------------------------------------------------------------------------
echo "=== 1. PostToolUseFailure -> circuit-breaker.py ==="
CB_STATE="$WORK/circuit-breaker-state.json"
EVENT=$(python3 -c '
import json
print(json.dumps({
    "ai": "claude-code", "hook_event_name": "PostToolUseFailure", "session_id": "ext-1",
    "tool_name": "Bash", "tool_input": {"command": "false"}, "tool_use_id": "tu-1",
    "error": "bash: false: command failed", "cwd": "/tmp",
}))')
OUT=$(printf '%s' "$EVENT" | AGENT_CIRCUIT_BREAKER_STATE="$CB_STATE" AGENT_CIRCUIT_BREAKER_THRESHOLD=3 \
  bash "$ADAPTER" circuit-breaker.py 2>/dev/null); RC=$?
check "posttoolusefailure-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "posttoolusefailure-empty-stdout-below-threshold" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
[[ -f "$CB_STATE" ]] && grep -q '"sig"' "$CB_STATE" 2>/dev/null
check "posttoolusefailure-recorded-in-state" $?

echo
echo "=== 1b. PostToolUseFailure -> threshold crossed -> advisory fires ==="
CB_STATE2="$WORK/circuit-breaker-state2.json"
rm -f "$CB_STATE2"
LAST=""
for i in 1 2 3; do
  EV=$(I="$i" python3 -c '
import json, os
print(json.dumps({
    "ai": "claude-code", "hook_event_name": "PostToolUseFailure", "session_id": "ext-1b",
    "tool_name": "Bash", "tool_input": {"command": "false"}, "tool_use_id": "tu-" + os.environ["I"],
    "error": "Traceback (most recent call last): boom", "cwd": "/tmp",
}))')
  LAST=$(printf '%s' "$EV" | AGENT_CIRCUIT_BREAKER_STATE="$CB_STATE2" AGENT_CIRCUIT_BREAKER_THRESHOLD=3 \
    bash "$ADAPTER" circuit-breaker.py 2>/dev/null)
done
[[ "$LAST" == *"Circuit Breaker"* ]]
check "posttoolusefailure-threshold-fires" $? "got: $LAST"
EV_NAME=$(printf '%s' "$LAST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])' 2>/dev/null)
check "posttoolusefailure-advisory-echoes-its-event-name" $([[ "$EV_NAME" == "PostToolUseFailure" ]]; echo $?) "hookEventName=$EV_NAME"

echo
echo "=== 1c. dedupe: repeated tool_use_id in PostToolUseFailure does not double-count ==="
CB_STATE3="$WORK/circuit-breaker-state3.json"
rm -f "$CB_STATE3"
EV_DUP=$(python3 -c '
import json
print(json.dumps({
    "ai": "claude-code", "hook_event_name": "PostToolUseFailure", "session_id": "ext-1c",
    "tool_name": "Bash", "tool_input": {"command": "false"}, "tool_use_id": "tu-same",
    "error": "Traceback: dup", "cwd": "/tmp",
}))')
printf '%s' "$EV_DUP" | AGENT_CIRCUIT_BREAKER_STATE="$CB_STATE3" AGENT_CIRCUIT_BREAKER_THRESHOLD=99 \
  bash "$ADAPTER" circuit-breaker.py >/dev/null 2>&1
printf '%s' "$EV_DUP" | AGENT_CIRCUIT_BREAKER_STATE="$CB_STATE3" AGENT_CIRCUIT_BREAKER_THRESHOLD=99 \
  bash "$ADAPTER" circuit-breaker.py >/dev/null 2>&1
COUNT=$(python3 -c "import json; print(len(json.load(open('$CB_STATE3'))))" 2>/dev/null || echo -1)
check "posttoolusefailure-dedupe-by-tool-use-id" $((COUNT == 1 ? 0 : 1)) "count=$COUNT"

# ---------------------------------------------------------------------------
# 2. SessionEnd -> session-close.sh
#    Cheap path only: no TODO scan, no notification, no broadcast. Must
#    complete well under the 1.5s SessionEnd budget (docs/hook-protocol.md).
# ---------------------------------------------------------------------------
echo
echo "=== 2. SessionEnd -> session-close.sh (cheap path, <1s) ==="
SE_EVENT='{"ai":"claude-code","hook_event_name":"SessionEnd","session_id":"ext-2","why_session_ended":"clear","cwd":"'"$REPO_ROOT"'"}'
START=$(date +%s%N)
OUT=$(printf '%s' "$SE_EVENT" | AGENT_SESSION_ID="ext-2-nonexistent" bash "$ADAPTER" session-close.sh 2>/dev/null); RC=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
check "sessionend-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "sessionend-empty-stdout" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
check "sessionend-under-1s" $((ELAPSED_MS < 1000 ? 0 : 1)) "elapsed_ms=$ELAPSED_MS"

echo
echo "=== 2a. SessionEnd as json.dumps-style JSON (\": \" separators) still takes the cheap path ==="
# The W4 Codex adapter emits json.dumps output ("key": "value"). The cheap-path
# branch must recognize SessionEnd there too; a TODO.md with an unchecked item
# makes the full path observable (it prints a summary line), the cheap path never does.
SE_ROOT="$WORK/se-repo"
mkdir -p "$SE_ROOT"
(cd "$SE_ROOT" && git init -q && printf -- '- [ ] pending\n' > TODO.md)
spaced_event() {
  E="$1" python3 -c 'import json, os; print(json.dumps({"ai": "claude-code", "hook_event_name": os.environ["E"], "session_id": "ext-2a"}))'
}
OUT=$(cd "$SE_ROOT" && spaced_event SessionEnd | AGENT_SESSION_ID="ext-2a-nonexistent" \
  bash "$REPO_ROOT/core/hooks/session-close.sh" 2>/dev/null)
check "sessionend-spaced-json-cheap-path" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
OUT=$(cd "$SE_ROOT" && spaced_event Stop | AGENT_SESSION_ID="ext-2a-nonexistent" \
  bash "$REPO_ROOT/core/hooks/session-close.sh" 2>/dev/null)
[[ "$OUT" == *"TODO.md has 1 unchecked"* ]]
check "stop-spaced-json-full-path-control" $? "out=$OUT"

echo
echo "=== 2b. Stop event -> session-close.sh still runs the full (non-cheap) path ==="
STOP_EVENT='{"ai":"claude-code","hook_event_name":"Stop","session_id":"ext-2b","cwd":"'"$REPO_ROOT"'"}'
OUT=$(printf '%s' "$STOP_EVENT" | AGENT_SESSION_ID="ext-2b-nonexistent" bash "$ADAPTER" session-close.sh 2>/dev/null); RC=$?
check "stop-event-still-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"

# ---------------------------------------------------------------------------
# 3. WorktreeCreate/WorktreeRemove — NOT wired (docs/hook-protocol.md §12).
#    Claude Code treats a WorktreeCreate hook as a REPLACEMENT for git's own
#    worktree creation: it must create the worktree and print its path on
#    stdout, and empty stdout fails the creation. r4-mutex-check.sh is an
#    observer (empty stdout always), so wiring it breaks every Claude worktree.
#    3a guards against re-wiring; 3b keeps the retained script branch honest
#    (registers/releases a shared_resource_locks entry keyed "worktree:<path>").
# ---------------------------------------------------------------------------
echo
echo "=== 3a. WorktreeCreate/WorktreeRemove stay unwired in both manifests ==="
TEMPLATE_JSON="$REPO_ROOT/adapters/claude-code/settings.json.template"
for MANIFEST in "$HOOKS_JSON" "$TEMPLATE_JSON"; do
  WIRED=$(python3 -c '
import json, sys
hooks = json.load(open(sys.argv[1], encoding="utf-8")).get("hooks", {})
print(",".join(e for e in ("WorktreeCreate", "WorktreeRemove") if e in hooks))
' "$MANIFEST"); RC=$?
  check "worktree-events-unwired:${MANIFEST#"$REPO_ROOT"/}" $(( RC == 0 && ${#WIRED} == 0 ? 0 : 1 )) \
    "rc=$RC wired=$WIRED"
done

echo
echo "=== 3b. r4-mutex-check.sh worktree branch (script logic, invoked directly) ==="
WT_ROOT="$WORK/r4-repo"
mkdir -p "$WT_ROOT"
(cd "$WT_ROOT" && git init -q && git commit -q --allow-empty -m init)
WT_PATH="/tmp/agent-ext-test-wt"

WC_EVENT='{"ai":"claude-code","hook_event_name":"WorktreeCreate","session_id":"ext-3","path":"'"$WT_PATH"'","branch":"claude/ext-test"}'
OUT=$(cd "$WT_ROOT" && printf '%s' "$WC_EVENT" | bash "$ADAPTER" r4-mutex-check.sh 2>/dev/null); RC=$?
LOCKFILE="$WT_ROOT/.agent/locks/active-sessions.json"
check "worktreecreate-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "worktreecreate-empty-stdout" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
[[ -f "$LOCKFILE" ]] && grep -q "worktree:$WT_PATH" "$LOCKFILE" 2>/dev/null
check "worktreecreate-registered-in-lockfile" $?

WR_EVENT='{"ai":"claude-code","hook_event_name":"WorktreeRemove","session_id":"ext-3","path":"'"$WT_PATH"'"}'
OUT=$(cd "$WT_ROOT" && printf '%s' "$WR_EVENT" | bash "$ADAPTER" r4-mutex-check.sh 2>/dev/null); RC=$?
check "worktreeremove-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "worktreeremove-empty-stdout" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
if [[ -f "$LOCKFILE" ]]; then
  grep -q "worktree:$WT_PATH" "$LOCKFILE" 2>/dev/null
  check "worktreeremove-released-from-lockfile" $((${?} == 0 ? 1 : 0))
else
  bad "worktreeremove-released-from-lockfile" "lockfile missing entirely"
fi

# Regression: the worktree lock write goes through agent-session.sh's mkdir
# mutex. session_store.py once pre-created the .mutex.d token on every call,
# so each acquire waited for the 2s stale rule — under the SessionEnd 1.5s
# budget that is a hard failure. A create+remove pair must finish in < 1.5s
# and leave no stale token behind.
T0=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
(cd "$WT_ROOT" && printf '%s' "$WC_EVENT" | bash "$ADAPTER" r4-mutex-check.sh >/dev/null 2>&1
 printf '%s' "$WR_EVENT" | bash "$ADAPTER" r4-mutex-check.sh >/dev/null 2>&1)
T1=$(date +%s%N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1e9))')
ELAPSED_MS=$(( (T1 - T0) / 1000000 ))
check "worktree-lock-roundtrip-under-1500ms" $((ELAPSED_MS < 1500 ? 0 : 1)) "elapsed=${ELAPSED_MS}ms"
[[ ! -d "$WT_ROOT/.agent/locks/.mutex.d" ]]
check "worktree-lock-no-stale-mutex-token" $?

# ---------------------------------------------------------------------------
# 4. PreModelSwitch/PostModelSwitch -> session-tier-observer.py
# ---------------------------------------------------------------------------
echo
echo "=== 4. PreModelSwitch/PostModelSwitch -> session-tier-observer.py ==="
ST_SINK="$WORK/session-tier.jsonl"

PRE_EVENT='{"ai":"claude-code","hook_event_name":"PreModelSwitch","session_id":"ext-4","to_model":"claude-sonnet-5","cwd":"/tmp"}'
OUT=$(printf '%s' "$PRE_EVENT" | AGENT_SESSION_TIER_SINK="$ST_SINK" bash "$ADAPTER" session-tier-observer.py 2>/dev/null); RC=$?
check "premodelswitch-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "premodelswitch-empty-stdout" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
LAST=$(tail -1 "$ST_SINK" 2>/dev/null)
[[ "$LAST" == *'"event": "PreModelSwitch"'* && "$LAST" == *'"tier_to": "MID"'* ]]
check "premodelswitch-record-shape" $? "last=$LAST"

POST_EVENT='{"ai":"claude-code","hook_event_name":"PostModelSwitch","session_id":"ext-4","from_model":"claude-haiku-5","to_model":"claude-opus-5-5","cwd":"/tmp"}'
OUT=$(printf '%s' "$POST_EVENT" | AGENT_SESSION_TIER_SINK="$ST_SINK" bash "$ADAPTER" session-tier-observer.py 2>"$WORK/pms.err"); RC=$?
check "postmodelswitch-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "postmodelswitch-empty-stdout" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
LAST=$(tail -1 "$ST_SINK" 2>/dev/null)
[[ "$LAST" == *'"tier_from": "LOW"'* && "$LAST" == *'"tier_to": "TOP"'* ]]
check "postmodelswitch-record-shape" $? "last=$LAST"
grep -q "advisory" "$WORK/pms.err" 2>/dev/null
check "postmodelswitch-crosstier-advisory-on-stderr" $?
grep -q "no-runtime-switching\|not blocking" "$WORK/pms.err" 2>/dev/null
check "postmodelswitch-advisory-not-blocking" $?

# ---------------------------------------------------------------------------
# 5. SubagentStart/SubagentStop -> model-routing-observer.py
# ---------------------------------------------------------------------------
echo
echo "=== 5. SubagentStart/SubagentStop -> model-routing-observer.py ==="
MR_SINK="$WORK/model-routing.jsonl"

SS_EVENT='{"ai":"claude-code","hook_event_name":"SubagentStart","session_id":"ext-5","agent_type":"code-reviewer","agent_id":"ag-1"}'
OUT=$(printf '%s' "$SS_EVENT" | AGENT_MODEL_ROUTING_SINK="$MR_SINK" bash "$ADAPTER" model-routing-observer.py 2>/dev/null); RC=$?
check "subagentstart-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "subagentstart-empty-stdout" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
LAST=$(tail -1 "$MR_SINK" 2>/dev/null)
[[ "$LAST" == *'"event": "SubagentStart"'* && "$LAST" == *'"source": "subagent_event"'* ]]
check "subagentstart-record-shape" $? "last=$LAST"

SE2_EVENT='{"ai":"claude-code","hook_event_name":"SubagentStop","session_id":"ext-5","agent_type":"code-reviewer","agent_id":"ag-1","last_assistant_message":"done, no issues found"}'
OUT=$(printf '%s' "$SE2_EVENT" | AGENT_MODEL_ROUTING_SINK="$MR_SINK" bash "$ADAPTER" model-routing-observer.py 2>/dev/null); RC=$?
check "subagentstop-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
check "subagentstop-empty-stdout" $((${#OUT} == 0 ? 0 : 1)) "out=$OUT"
LAST=$(tail -1 "$MR_SINK" 2>/dev/null)
[[ "$LAST" == *'"event": "SubagentStop"'* && "$LAST" == *'"last_assistant_message_len": 21'* ]]
check "subagentstop-record-shape" $? "last=$LAST"

echo
echo "=== 5b. PostToolUse Task/Agent dispatch record now carries source=post_tool_use ==="
TASK_EVENT='{"ai":"claude-code","hook_event_name":"PostToolUse","session_id":"ext-5b","tool_name":"Task","tool_input":{"subagent_type":"code-reviewer","prompt":"review this"}}'
OUT=$(printf '%s' "$TASK_EVENT" | AGENT_MODEL_ROUTING_SINK="$MR_SINK" bash "$ADAPTER" model-routing-observer.py 2>/dev/null); RC=$?
check "posttooluse-dispatch-exit-0" $((RC == 0 ? 0 : 1)) "rc=$RC"
LAST=$(tail -1 "$MR_SINK" 2>/dev/null)
[[ "$LAST" == *'"source": "post_tool_use"'* ]]
check "posttooluse-dispatch-source-tagged" $? "last=$LAST"

# ---------------------------------------------------------------------------
# 6. Manifest assertion — hooks/hooks.json wires each event->hook pair above.
#    This is the manifest-owning agent's half of W3-2; if it hasn't landed yet
#    this section reports "pending manifest wiring" rather than weakening the
#    assertion (per the task brief — do not soften this check to pass early).
# ---------------------------------------------------------------------------
echo
echo "=== 6. hooks/hooks.json manifest wiring ==="
if [[ ! -f "$HOOKS_JSON" ]]; then
  bad "manifest-file-exists" "not found: $HOOKS_JSON (pending manifest wiring)"
else
  MANIFEST_REPORT=$(python3 - "$HOOKS_JSON" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception as e:
    print(f"UNPARSEABLE {e}")
    sys.exit(0)
hooks = data.get("hooks", {})
expected = [
    ("PostToolUseFailure", "circuit-breaker.py"),
    ("SessionEnd", "session-close.sh"),
    ("PreModelSwitch", "session-tier-observer.py"),
    ("PostModelSwitch", "session-tier-observer.py"),
    ("SubagentStart", "model-routing-observer.py"),
    ("SubagentStop", "model-routing-observer.py"),
]
missing = []
for event, hook_name in expected:
    entries = hooks.get(event, [])
    found = False
    for group in entries if isinstance(entries, list) else []:
        for h in group.get("hooks", []):
            if hook_name in h.get("command", ""):
                found = True
    if not found:
        missing.append(f"{event}->{hook_name}")
if missing:
    print("MISSING " + ",".join(missing))
else:
    print("OK")
PY
)
  case "$MANIFEST_REPORT" in
    OK) ok "manifest-wires-all-6-event-hook-pairs" ;;
    MISSING*) bad "manifest-wires-all-6-event-hook-pairs" "pending manifest wiring: ${MANIFEST_REPORT#MISSING }" ;;
    *) bad "manifest-wires-all-6-event-hook-pairs" "$MANIFEST_REPORT" ;;
  esac
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
