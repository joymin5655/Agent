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
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
