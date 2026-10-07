#!/usr/bin/env bash
# secret-content-scan-ledger-test.sh — the Write/Edit evidence-ledger deny in
# core/hooks/secret-content-scan.py is scoped to the workers/logs dirs, not to any
# file that happens to be named reviews.jsonl.
#
# Usage: bash core/tests/secret-content-scan-ledger-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/secret-content-scan.py"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/.agent/workers/k" "$WORK/home/.agent/logs" "$WORK/proj/data" "$WORK/custom"

# run_case <name> <expect: deny|allow> <tool> <file_path> [ENV=val ...]
run_case() {
  local name="$1" expect="$2" tool="$3" file="$4" got out
  shift 4
  out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"{}"}}))' "$tool" "$file" \
    | env -u AGENT_WORKERS_DIR -u AGENT_LOGS_DIR HOME="$WORK/home" ${1+"$@"} python3 "$HOOK" 2>/dev/null)"
  got=allow
  [[ "$out" == *'"permissionDecision": "deny"'* ]] && got=deny
  if [[ "$got" == "$expect" ]]; then PASS=$((PASS + 1)); echo "  ok   [$name]"
  else FAIL=$((FAIL + 1)); echo "  FAIL [$name] expected=$expect got=$got :: $out"; fi
  if [[ "$expect" == deny && ( "$out" != *"WHY:"* || "$out" != *"FIX:"* ) ]]; then
    FAIL=$((FAIL + 1)); echo "  FAIL [$name/teaching] lacks WHY:/FIX:"
  fi
}

W="$WORK/home/.agent/workers/k"
run_case "project-data-reviews-allow"    allow Write "$WORK/proj/data/reviews.jsonl"
run_case "project-review-override-allow" allow Edit  "$WORK/proj/review-override.jsonl"
run_case "workers-dir-reviews-deny"      deny  Write "$W/reviews.jsonl"
run_case "workers-dir-mixed-case-deny"   deny  Write "$W/Reviews.JSONL"
run_case "logs-dir-override-deny"        deny  Edit  "$WORK/home/.agent/logs/review-override.jsonl"
run_case "multiedit-workers-deny"        deny  MultiEdit "$W/reviews.jsonl"
run_case "custom-workers-env-deny"       deny  Write "$WORK/custom/k/reviews.jsonl" AGENT_WORKERS_DIR="$WORK/custom"
run_case "custom-logs-env-deny"          deny  Write "$WORK/vlogs/review-override.jsonl" AGENT_LOGS_DIR="$WORK/vlogs"
run_case "default-workers-still-denied-when-env-moves-it" deny Write "$W/reviews.jsonl" AGENT_WORKERS_DIR="$WORK/custom"
run_case "default-logs-still-denied-when-env-moves-it" deny Write "$WORK/home/.agent/logs/review-override.jsonl" AGENT_LOGS_DIR="$WORK/vlogs"
ln -s "$W" "$WORK/proj/link"
run_case "symlink-into-workers-deny"     deny  Write "$WORK/proj/link/reviews.jsonl"

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
