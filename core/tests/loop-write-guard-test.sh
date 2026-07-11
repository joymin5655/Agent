#!/usr/bin/env bash
# loop-write-guard-test.sh — battery for core/hooks/loop-write-guard.py (L-2).
#
# Verifies the loop write-ban: INERT outside a loop session; inside a session it
# escalates (ask) writes to the grader/verifier surface (core/tests/, evals/) and
# non-append rewrites of the ledger, while allowing TARGET edits and pure appends.
# Also proves the realpath containment cannot be dodged by a symlink into the
# guarded dir, and that ask reasons carry the WHY:/FIX: teaching tags.
#
# Usage: bash core/tests/loop-write-guard-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/loop-write-guard.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ROOT="$TMP_ROOT/proj"
mkdir -p "$ROOT/core/tests" "$ROOT/evals" "$ROOT/agents" "$ROOT/.agent/loop"

# run_hook <tool> <file_path> <content> [extra env assignments...] -> sets OUT
# loop is forced active via AGENT_LOOP_ACTIVE unless a case overrides it.
run_hook() {
  local tool="$1" fp="$2" content="$3"; shift 3
  local event
  event=$(TOOL="$tool" FP="$fp" C="$content" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":os.environ["TOOL"],"tool_input":{"file_path":os.environ["FP"],"content":os.environ["C"]}}))')
  OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" "$@" python3 "$HOOK" 2>/dev/null || true)"
}
is_ask() { printf '%s' "$OUT" | grep -q '"permissionDecision": "ask"'; }

echo "=== (a) INERT outside a loop session: grader edit passes untouched ==="
run_hook Write "$ROOT/core/tests/grade.sh" "x"   # no AGENT_LOOP_ACTIVE
[[ -z "$OUT" ]]; check "inert-no-loop-no-output" $?

echo
echo "=== (b) active loop: write under core/tests/ -> ask ==="
run_hook Write "$ROOT/core/tests/grade.sh" "tampered" AGENT_LOOP_ACTIVE=1
is_ask; check "coretests-write-ask" $?
printf '%s' "$OUT" | grep -q 'WHY:'; check "ask-has-WHY" $?
printf '%s' "$OUT" | grep -q 'FIX:'; check "ask-has-FIX" $?

echo
echo "=== (c) active loop: write under evals/ -> ask ==="
run_hook Write "$ROOT/evals/failure-modes.yaml" "weakened" AGENT_LOOP_ACTIVE=1
is_ask; check "evals-write-ask" $?

echo
echo "=== (d) active loop: TARGET edit (agents/) -> allow ==="
run_hook Edit "$ROOT/agents/code-reviewer.md" "improved prompt" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "target-edit-allowed" $?

echo
echo "=== (e) active loop: pure append to the ledger -> allow ==="
LEDG="$ROOT/.agent/loop/results.tsv"
printf 'commit\tharness_score\tduration_s\tstatus\tdescription\n' > "$LEDG"
# preserve the trailing newline that $(cat) would strip, so this is a TRUE byte-prefix
old="$(cat "$LEDG"; printf x)"; old="${old%x}"
run_hook Write "$LEDG" "${old}c1\t1.0\t1\tkeep\trow1data" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "ledger-pure-append-allowed" $?

echo
echo "=== (f) active loop: ledger rewrite (not a prefix of old) -> ask ==="
run_hook Write "$LEDG" "totally different content" AGENT_LOOP_ACTIVE=1
is_ask; check "ledger-rewrite-ask" $?

echo
echo "=== (g) active loop: Edit on the ledger (mutates existing bytes) -> ask ==="
run_hook Edit "$LEDG" "anything" AGENT_LOOP_ACTIVE=1
is_ask; check "ledger-edit-ask" $?

echo
echo "=== (h) loop marked active via FLAG FILE (not env) -> ask ==="
FLAG="$ROOT/.agent/loop/active"; : > "$FLAG"
run_hook Write "$ROOT/core/tests/x.sh" "y" AGENT_LOOP_FLAG="$FLAG"
is_ask; check "flag-file-activates-guard" $?
rm -f "$FLAG"

echo
echo "=== (i) realpath containment: a symlink INTO core/tests cannot dodge the guard ==="
ln -s "$ROOT/core/tests" "$ROOT/sneaky"     # $ROOT/sneaky -> core/tests
run_hook Write "$ROOT/sneaky/grade.sh" "tampered-via-symlink" AGENT_LOOP_ACTIVE=1
is_ask; check "symlink-into-guarded-dir-ask" $?
# a not-yet-existing leaf under the symlinked dir is contained too (parent realpath)
run_hook Write "$ROOT/sneaky/brand-new.sh" "z" AGENT_LOOP_ACTIVE=1
is_ask; check "symlink-nonexistent-leaf-ask" $?

echo
echo "=== (j) non-Write/Edit tool -> allow (exit 0, no decision) ==="
event='{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" AGENT_LOOP_ACTIVE=1 python3 "$HOOK" 2>/dev/null || true)"
[[ -z "$OUT" ]]; check "bash-tool-allowed" $?

echo
echo "=== (k) active loop: unrelated file (docs/) -> allow ==="
mkdir -p "$ROOT/docs"
run_hook Write "$ROOT/docs/note.md" "hi" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "unrelated-file-allowed" $?

# run a Bash event through the hook: sets OUT
run_bash() {
  local command="$1"; shift
  local event
  event=$(C="$command" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":os.environ["C"]}}))')
  OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" "$@" python3 "$HOOK" 2>/dev/null || true)"
}

echo
echo "=== (l) active loop: Bash WRITE into guarded surface -> ask (the Bash bypass) ==="
run_bash "sed -i '' 's/FAIL/PASS/' core/tests/grade.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-sed-i-coretests-ask" $?
run_bash "echo forged > evals/failure-modes.yaml" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-redirect-evals-ask" $?
run_bash "cp /tmp/fake core/tests/pre-tool-guard-test.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-cp-coretests-ask" $?
run_bash "rm .agent/loop/results.tsv" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-rm-ledger-ask" $?
run_bash "git checkout HEAD -- core/tests/grade.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-git-checkout-coretests-ask" $?
run_bash "python3 -c \"open('core/tests/x.sh','w').write('exit 0')\"" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-python-open-w-ask" $?

echo
echo "=== (m) active loop: Bash READ / unrelated -> allow (no false-ask) ==="
run_bash "cat core/tests/grade.sh" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-cat-coretests-allowed" $?
run_bash "grep -r FAIL core/tests/" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-grep-coretests-allowed" $?
run_bash "bash core/tests/grade.sh --base HEAD~1" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-run-grade-allowed" $?
# Bash write to guarded surface is INERT outside a loop
run_bash "echo x > core/tests/y.sh"    # no AGENT_LOOP_ACTIVE
[[ -z "$OUT" ]]; check "bash-write-inert-no-loop" $?

echo
echo "=== (n) self-protection: editing the guard's OWN enforcement code -> ask ==="
run_hook Write "$ROOT/core/hooks/loop-write-guard.py" "sys.exit(0)" AGENT_LOOP_ACTIVE=1
is_ask; check "self-edit-guard-ask" $?
mkdir -p "$ROOT/hooks"
run_hook Edit "$ROOT/hooks/hooks.json" "{}" AGENT_LOOP_ACTIVE=1
is_ask; check "edit-hooks-json-ask" $?

echo
echo "=== (o) MultiEdit into guarded surface -> ask (matcher covers MultiEdit) ==="
run_hook MultiEdit "$ROOT/core/tests/grade.sh" "patch" AGENT_LOOP_ACTIVE=1
is_ask; check "multiedit-coretests-ask" $?

echo
echo "=== (p) fail-closed: non-string ledger content cannot prove append -> ask ==="
: > "$LEDG"; printf 'header\n' > "$LEDG"
event='{"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$LEDG"'","content":12345}}'
OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" AGENT_LOOP_ACTIVE=1 python3 "$HOOK" 2>/dev/null || true)"
is_ask; check "ledger-nonstring-content-ask" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
