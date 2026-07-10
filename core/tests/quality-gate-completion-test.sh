#!/usr/bin/env bash
# quality-gate-completion-test.sh — verify P3-1: session.completion_tests
# execution in core/hooks/session-quality-gate.py (Stop hook).
#
# A project can declare completion tests in .agent/hook-config.yml|json:
#     session:
#       completion_tests:
#         - "pytest -q"
# On Stop, the hook runs each command; if any FAILS, the hook emits
# {"decision":"block"} so the session can't end while tests fail. Stop hooks
# cannot emit `ask` (PreToolUse-only per hook-protocol.md), so the enforcement
# verb is `block`. The hook ALWAYS exits 0 (an internal error must not crash the
# Stop event).
#
# All fixtures live in an isolated mktemp dir passed as the event `cwd` — the
# real repo .agent/ is never touched.
#
# Contract covered:
#   (a) passing completion_test  -> no block (exit 0)
#   (b) failing completion_test  -> decision:block (exit 0)
#   (c) failing + stop_hook_active=true -> pass (anti-loop second Stop)
#   (d) failing + AGENT_QUALITY_GATE_BLOCK=0 -> advisory (no block)
#   (e) no config at all         -> no-op (no block)
#   (f) malformed config         -> fail-safe (no crash, no block, exit 0)
#   (g) every invocation exits 0
#
# Usage: bash core/tests/quality-gate-completion-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/session-quality-gate.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# make_project <subdir> — a throwaway project root with an .agent/ dir; echoes path
make_project() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/.agent"
  echo "$d"
}

# run_stop <proj-root> <stop_hook_active:true|false> [env KEY=VAL ...]
# Writes the hook's stdout to $OUTFILE and echoes its exit code (so the caller
# gets BOTH — a function called via $(...) runs in a subshell, so a global set
# inside it would not propagate; the file + echoed rc pattern avoids that).
OUTFILE="$TMP_ROOT/.hookout"
run_stop() {
  local root="$1" active="$2"; shift 2
  local event
  event=$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Stop","session_id":"t","cwd":sys.argv[1],"stop_hook_active":sys.argv[2]=="true"}))' "$root" "$active")
  printf '%s' "$event" | env "$@" python3 "$HOOK" > "$OUTFILE" 2>/dev/null
  echo $?
}

is_block()  { [[ "$1" == *'"decision": "block"'* || "$1" == *'"decision":"block"'* ]]; }

echo "=== (a) passing completion_test -> no block, exit 0 ==="
P=$(make_project pass)
cat > "$P/.agent/hook-config.json" <<'EOF'
{ "session": { "completion_tests": ["true"] } }
EOF
RCA=$(run_stop "$P" false); OUT=$(cat "$OUTFILE")
[[ $RCA -eq 0 ]]; check "exit-0" $?
is_block "$OUT" && check "passing-test-no-block" 1 || check "passing-test-no-block" 0

echo
echo "=== (b) failing completion_test -> decision:block, exit 0 ==="
P=$(make_project fail)
cat > "$P/.agent/hook-config.json" <<'EOF'
{ "session": { "completion_tests": ["false"] } }
EOF
RCB=$(run_stop "$P" false); OUT=$(cat "$OUTFILE")
[[ $RCB -eq 0 ]]; check "exit-0-on-fail" $?
is_block "$OUT" && check "failing-test-blocks" 0 || check "failing-test-blocks" 1
# T-1 teaching contract: the block reason must carry WHY: and FIX: tags.
[[ "$OUT" == *"WHY:"* && "$OUT" == *"FIX:"* ]]; check "block-reason-teaching-tags" $?

echo
echo "=== (c) failing + stop_hook_active -> pass (anti-loop) ==="
run_stop "$P" true >/dev/null; OUT=$(cat "$OUTFILE")
is_block "$OUT" && check "second-stop-passes" 1 || check "second-stop-passes" 0

echo
echo "=== (d) failing + AGENT_QUALITY_GATE_BLOCK=0 -> advisory (no block) ==="
run_stop "$P" false AGENT_QUALITY_GATE_BLOCK=0 >/dev/null; OUT=$(cat "$OUTFILE")
is_block "$OUT" && check "advisory-no-block" 1 || check "advisory-no-block" 0

echo
echo "=== (e) no config -> no-op (no block), exit 0 ==="
P=$(make_project none)
RCE=$(run_stop "$P" false); OUT=$(cat "$OUTFILE")
[[ $RCE -eq 0 ]]; check "exit-0-no-config" $?
is_block "$OUT" && check "no-config-no-block" 1 || check "no-config-no-block" 0

echo
echo "=== (f) malformed config -> fail-safe (no crash, no block, exit 0) ==="
P=$(make_project malformed)
printf '%s' '{ this is: not valid json ]' > "$P/.agent/hook-config.json"
RCF=$(run_stop "$P" false); OUT=$(cat "$OUTFILE")
[[ $RCF -eq 0 ]]; check "exit-0-malformed" $?
is_block "$OUT" && check "malformed-no-block" 1 || check "malformed-no-block" 0

echo
echo "=== (g) YAML config path (session.completion_tests) -> block on fail ==="
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "  skip [yaml-path] PyYAML not importable — .yml loading is optional"
else
  P=$(make_project yaml)
  cat > "$P/.agent/hook-config.yml" <<'EOF'
session:
  completion_tests:
    - "false"
EOF
  run_stop "$P" false >/dev/null; OUT=$(cat "$OUTFILE")
  is_block "$OUT" && check "yaml-failing-test-blocks" 0 || check "yaml-failing-test-blocks" 1
fi

echo
echo "=== (h) non-numeric AGENT_COMPLETION_TEST_TIMEOUT -> no crash, exit 0 ==="
# The timeout is parsed at MODULE IMPORT, before main()'s try/except. A typo like
# "2m"/"30s" must degrade to the default, never raise — else the Stop hook crashes
# with a traceback (exit 1) and breaks the 'Stop always exits 0' contract.
P=$(make_project badtimeout)
cat > "$P/.agent/hook-config.json" <<'EOF'
{ "session": { "completion_tests": ["true"] } }
EOF
for BAD in 2m 30s notanumber; do
  RCH=$(run_stop "$P" false AGENT_COMPLETION_TEST_TIMEOUT="$BAD")
  [[ $RCH -eq 0 ]]; check "exit-0-badtimeout-$BAD" $?
done

echo
echo "=== (i) process-group-signalling completion_test -> hook survives, exit 0 ==="
# A teardown idiom that signals its process GROUP (`kill 0`, `trap 'kill 0' EXIT`)
# must reach only the command's own group, not this hook — start_new_session=True.
# The command dies non-zero, so it registers as a failure and blocks; the point is
# the HOOK itself stays alive and exits 0.
for SIG in 'kill 0' "trap 'kill 0' EXIT; false"; do
  P=$(make_project "sig-$(printf '%s' "$SIG" | tr -c 'a-z' '-')")
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"session":{"completion_tests":[sys.argv[2]]}}))' \
    "$P/.agent/hook-config.json" "$SIG"
  RCI=$(run_stop "$P" false); OUT=$(cat "$OUTFILE")
  [[ $RCI -eq 0 ]]; check "group-signal-hook-exit-0" $?
  is_block "$OUT" && check "group-signal-blocks" 0 || check "group-signal-blocks" 1
done

echo
echo "=== (j) slow completion_test past timeout -> block, exit 0 ==="
# Exercises the subprocess.TimeoutExpired -> failure -> block branch that the
# docstring/template promise but no instant-command fixture reaches.
P=$(make_project slow)
cat > "$P/.agent/hook-config.json" <<'EOF'
{ "session": { "completion_tests": ["sleep 5"] } }
EOF
RCJ=$(run_stop "$P" false AGENT_COMPLETION_TEST_TIMEOUT=1); OUT=$(cat "$OUTFILE")
[[ $RCJ -eq 0 ]]; check "exit-0-timeout" $?
is_block "$OUT" && check "timeout-blocks" 0 || check "timeout-blocks" 1

echo
echo "=== (k) loader bounds — <=20 commands, <=500 chars each ==="
# The bounded loader (_MAX_COMPLETION_TESTS=20, _MAX_COMMAND_LEN=500) has no other
# coverage. Assert directly: 25 declared + one 600-char entry -> capped to 20, and
# every surviving entry is within the length bound.
P=$(make_project bounds)
python3 -c '
import json, sys
cmds = ["echo %d" % i for i in range(25)] + ["false #" + "x"*600]
open(sys.argv[1], "w").write(json.dumps({"session": {"completion_tests": cmds}}))
' "$P/.agent/hook-config.json"
BOUNDS=$(cd "$REPO_ROOT" && python3 -c '
import sys
sys.path.insert(0, "core/hooks")
import hook_config
c = hook_config.load_session_config(sys.argv[1]).get("completion_tests", [])
print("OK" if len(c) <= 20 and all(len(x) <= 500 for x in c) else "BAD len=%d" % len(c))
' "$P")
[[ "$BOUNDS" == OK ]]; check "loader-bounds-enforced" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
