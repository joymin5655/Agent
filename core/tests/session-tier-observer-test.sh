#!/usr/bin/env bash
# session-tier-observer-test.sh — verify core/hooks/session-tier-observer.py.
#
# Contract: pure observer. ALWAYS exits 0 (present/absent/malformed input,
# unwritable sink). Detects the session model best-effort (stdin field →
# transcript tail → settings default), maps family → tier (fable/opus=TOP,
# sonnet=MID, haiku=LOW), emits one stderr advisory when detected, stdout
# stays EMPTY (SessionStart stdout injects context — an observer must not),
# and appends a JSONL record. Detection only — the hook must never emit a
# hook-decision payload.
#
# Usage: bash core/tests/session-tier-observer-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/session-tier-observer.py"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

SINK="$WORK/session-tier.jsonl"
EMPTY_SETTINGS="$WORK/no-settings.json"   # intentionally absent file

run_hook() {  # run_hook <stdin-string> [extra-env...]
  local payload="$1"; shift
  printf '%s' "$payload" | env \
    AGENT_SESSION_TIER_SINK="$SINK" \
    AGENT_CLAUDE_SETTINGS="$EMPTY_SETTINGS" \
    "$@" python3 "$HOOK"
}

echo "=== 1. stdin model field -> tier detected, advisory, record ==="
out="$(run_hook '{"session_id":"s1","model":{"id":"claude-fable-5"}}' 2>"$WORK/err1")"; rc=$?
last="$(tail -1 "$SINK" 2>/dev/null)"
[[ $rc -eq 0 ]];                                   check "exit-0" $?
[[ -z "$out" ]];                                   check "stdout-empty" $?
grep -q "session=TOP (claude-fable-5)" "$WORK/err1"; check "advisory-on-stderr" $?
grep -q "docs/model-routing.md" "$WORK/err1";      check "advisory-cites-policy" $?
[[ "$last" == *'"tier": "TOP"'* && "$last" == *'"source": "stdin"'* ]]
check "jsonl-record-tier-source" $?

echo
echo "=== 2. transcript tail fallback (resume shape) ==="
TR="$WORK/transcript.jsonl"
printf '%s\n%s\n' \
  '{"type":"assistant","message":{"model":"claude-haiku-4-5-20251001"}}' \
  '{"type":"assistant","message":{"model":"claude-sonnet-5"}}' > "$TR"
run_hook "{\"session_id\":\"s2\",\"transcript_path\":\"$TR\"}" >"$WORK/out2" 2>"$WORK/err2"; rc=$?
last="$(tail -1 "$SINK")"
[[ $rc -eq 0 ]];                                   check "exit-0" $?
[[ "$last" == *'"tier": "MID"'* && "$last" == *'"source": "transcript"'* ]]
check "last-model-wins-transcript" $?
grep -q "session=MID" "$WORK/err2";                check "advisory-mid" $?

echo
echo "=== 3. settings default fallback, labeled as such ==="
SETTINGS="$WORK/settings.json"
printf '{"model": "opus"}' > "$SETTINGS"
run_hook '{"session_id":"s3"}' AGENT_CLAUDE_SETTINGS="$SETTINGS" >"$WORK/out3" 2>"$WORK/err3"; rc=$?
last="$(tail -1 "$SINK")"
[[ $rc -eq 0 ]];                                   check "exit-0" $?
[[ "$last" == *'"tier": "TOP"'* && "$last" == *'"source": "settings-default"'* ]]
check "settings-source-labeled" $?
grep -q "configured default" "$WORK/err3";         check "advisory-flags-default" $?

echo
echo "=== 4. nothing detectable -> silent, unknown record, exit 0 ==="
run_hook '{"session_id":"s4"}' >"$WORK/out4" 2>"$WORK/err4"; rc=$?
last="$(tail -1 "$SINK")"
[[ $rc -eq 0 ]];                                   check "exit-0" $?
[[ ! -s "$WORK/err4" ]];                           check "no-advisory-when-unknown" $?
[[ "$last" == *'"tier": "unknown"'* && "$last" == *'"source": "none"'* ]]
check "unknown-still-recorded" $?

echo
echo "=== 5. malformed / hostile input -> exit 0, no crash ==="
run_hook 'not json at all' >"$WORK/out5" 2>"$WORK/err5"; rc=$?
[[ $rc -eq 0 ]];                                   check "malformed-json-exit-0" $?
run_hook '"just-a-string"' >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]];                                   check "non-object-exit-0" $?
run_hook '{"transcript_path": "/nonexistent/path/x.jsonl"}' >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]];                                   check "missing-transcript-exit-0" $?

echo
echo "=== 6. unwritable sink -> exit 0, silent ==="
printf '{"model":{"id":"claude-fable-5"}}' | env \
  AGENT_SESSION_TIER_SINK="/nonexistent-root-dir/deny/sink.jsonl" \
  AGENT_CLAUDE_SETTINGS="$EMPTY_SETTINGS" \
  python3 "$HOOK" >"$WORK/out6" 2>>"$WORK/err6"; rc=$?
[[ $rc -eq 0 ]];                                   check "unwritable-sink-exit-0" $?
[[ -z "$(cat "$WORK/out6")" ]];                    check "unwritable-sink-stdout-empty" $?

echo
echo "=== 7. never a hook decision: no permissionDecision in any output ==="
grep -rq "permissionDecision" "$WORK"/out* 2>/dev/null
[[ $? -ne 0 ]]; check "no-decision-payload" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
