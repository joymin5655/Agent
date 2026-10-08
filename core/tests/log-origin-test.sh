#!/usr/bin/env bash
# log-origin-test.sh — verify the W1-4 log-origin tag on the two JSONL writers.
#
# All 7,443 pre-existing security-violations.jsonl / model-routing.jsonl
# records carry session_id="main", so a block produced by a test battery is
# indistinguishable from a real-session block. hook_config.log_origin() reads
# AGENT_LOG_ORIGIN (default "session"; verify-all.sh exports "test"), and both
# writers now stamp every record with an "origin" field carrying that value.
#
# Covers:
#   (a) pre-tool-guard.sh, AGENT_LOG_ORIGIN unset -> origin "session"
#   (b) pre-tool-guard.sh, AGENT_LOG_ORIGIN=test  -> origin "test"
#   (c) model-routing-observer.py, AGENT_LOG_ORIGIN unset -> origin "session"
#   (d) model-routing-observer.py, AGENT_LOG_ORIGIN=test  -> origin "test"
#   (e) running pre-tool-guard-test.sh itself under AGENT_LOG_ORIGIN=test ->
#       its own last-written log record carries origin=="test"
#
# Usage: bash core/tests/log-origin-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u
# X-5: this battery reads the project-local sink, so the run-wide redirect must not apply.
unset AGENT_GATE_SINK_DIR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD_HOOK="$REPO_ROOT/core/hooks/pre-tool-guard.sh"
ROUTING_HOOK="$REPO_ROOT/core/hooks/model-routing-observer.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then
    echo "  ok   [$name]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name]"
    FAIL=$((FAIL + 1))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- (a)/(b) pre-tool-guard.sh -----------------------------------------------
# Drives the hook exactly the way pre-tool-guard-test.sh does (canonical
# PreToolUse Bash event on stdin) but isolates the log sink via
# AGENT_PROJECT_DIR — a scratch dir, never the real repo — so this battery
# never writes into the harness's own .agent/logs/.
guard_last_origin() {  # guard_last_origin <project-dir>
  tail -1 "$1/.agent/logs/security-violations.jsonl" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("origin",""))' 2>/dev/null
}

run_guard() {  # run_guard <project-dir> [origin-env]
  local proj="$1" origin_env="${2:-}"
  local event
  event=$(printf '%s' 'cat secrets/prod.env' | python3 -c 'import sys,json; print(json.dumps({"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')
  if [[ -n "$origin_env" ]]; then
    printf '%s' "$event" | AGENT_PROJECT_DIR="$proj" AGENT_LOG_ORIGIN="$origin_env" bash "$GUARD_HOOK" >/dev/null 2>&1
  else
    printf '%s' "$event" | AGENT_PROJECT_DIR="$proj" env -u AGENT_LOG_ORIGIN bash "$GUARD_HOOK" >/dev/null 2>&1
  fi
}

echo "=== (a) pre-tool-guard.sh: AGENT_LOG_ORIGIN unset -> origin 'session' ==="
PROJ_A="$WORK/proj-a"
mkdir -p "$PROJ_A"
run_guard "$PROJ_A"
[[ "$(guard_last_origin "$PROJ_A")" == "session" ]]
check "guard-default-origin-session" $?

echo
echo "=== (b) pre-tool-guard.sh: AGENT_LOG_ORIGIN=test -> origin 'test' ==="
PROJ_B="$WORK/proj-b"
mkdir -p "$PROJ_B"
run_guard "$PROJ_B" test
[[ "$(guard_last_origin "$PROJ_B")" == "test" ]]
check "guard-explicit-origin-test" $?

echo
echo "=== (b2) pre-tool-guard.sh: JSON-breaking AGENT_LOG_ORIGIN is sanitized, record still parses ==="
PROJ_B2="$WORK/proj-b2"
mkdir -p "$PROJ_B2"
run_guard "$PROJ_B2" $'te"st\\\n'
[[ "$(guard_last_origin "$PROJ_B2")" == "test" ]]
check "guard-origin-sanitized-json-parses" $?

# --- (c)/(d) model-routing-observer.py ---------------------------------------
routing_last_origin() {  # routing_last_origin <sink-file>
  tail -1 "$1" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("origin",""))' 2>/dev/null
}

run_routing() {  # run_routing <sink-file> [origin-env]
  local sink="$1" origin_env="${2:-}"
  local event='{"event":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"Explore","prompt":"x"}}'
  if [[ -n "$origin_env" ]]; then
    printf '%s' "$event" | AGENT_MODEL_ROUTING_SINK="$sink" AGENT_LOG_ORIGIN="$origin_env" python3 "$ROUTING_HOOK" >/dev/null 2>&1
  else
    printf '%s' "$event" | AGENT_MODEL_ROUTING_SINK="$sink" env -u AGENT_LOG_ORIGIN python3 "$ROUTING_HOOK" >/dev/null 2>&1
  fi
}

echo
echo "=== (c) model-routing-observer.py: AGENT_LOG_ORIGIN unset -> origin 'session' ==="
SINK_C="$WORK/routing-c.jsonl"
run_routing "$SINK_C"
[[ "$(routing_last_origin "$SINK_C")" == "session" ]]
check "routing-default-origin-session" $?

echo
echo "=== (d) model-routing-observer.py: AGENT_LOG_ORIGIN=test -> origin 'test' ==="
SINK_D="$WORK/routing-d.jsonl"
run_routing "$SINK_D" test
[[ "$(routing_last_origin "$SINK_D")" == "test" ]]
check "routing-explicit-origin-test" $?

# --- (e) pre-tool-guard-test.sh's OWN records, run under AGENT_LOG_ORIGIN=test
echo
echo "=== (e) pre-tool-guard-test.sh under AGENT_LOG_ORIGIN=test -> its last record origin=='test' ==="
PROJ_E="$WORK/proj-e"
mkdir -p "$PROJ_E"
( AGENT_PROJECT_DIR="$PROJ_E" AGENT_GATE_SINK_DIR="$PROJ_E/.agent/logs" AGENT_LOG_ORIGIN=test bash "$REPO_ROOT/core/tests/pre-tool-guard-test.sh" >/dev/null 2>&1 )
[[ "$(guard_last_origin "$PROJ_E")" == "test" ]]
check "pre-tool-guard-test-battery-tags-origin-test" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
