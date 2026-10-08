#!/usr/bin/env bash
# gate-telemetry-isolation-test.sh — backlog X-5: gate telemetry stays out of live sinks,
# digest aggregates across projects and reports the fixture rows it excluded.
#
# (a) a gate hook run with AGENT_GATE_SINK_DIR leaves the repo's live sink row count
#     unchanged and writes an origin-tagged row to the redirected dir
# (b) verify-all.sh redirects a whole run: a fake battery that fires a gate leaves the
#     live sink row count unchanged
# (c) telemetry-digest --gates --projects sums per-project sinks
# (d) digest reports the excluded fixture rows (reproduce_test + origin!=session)
# Usage: bash core/tests/gate-telemetry-isolation-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIGEST="$REPO_ROOT/core/infra/telemetry-digest.sh"
GUARD="$REPO_ROOT/core/hooks/pre-tool-guard.sh"
PASS=0; FAIL=0
check() {
  if [[ "$2" -eq 0 ]]; then echo "  ok   [$1]"; PASS=$((PASS + 1)); else echo "  FAIL [$1]"; FAIL=$((FAIL + 1)); fi
}
rows() { if [[ -f "$1" ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- throwaway project: a git repo so the hook resolves its root there ---
PROJ="$TMP/projA"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
LIVE="$PROJ/.agent/logs/security-violations.jsonl"
EVENT='{"ai":"claude-code","session_id":"s1","event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"},"cwd":"'"$PROJ"'"}'

# (a) redirected hook run
before=$(rows "$LIVE")
printf '%s' "$EVENT" | AGENT_PROJECT_DIR="$PROJ" AGENT_GATE_SINK_DIR="$TMP/sink" AGENT_LOG_ORIGIN=test bash "$GUARD" >/dev/null 2>&1
after=$(rows "$LIVE")
check "a: live sink unchanged under AGENT_GATE_SINK_DIR" "$([[ "$before" == "$after" ]]; echo $?)"
check "a: redirected sink got an origin=test row" \
  "$([[ -f "$TMP/sink/security-violations.jsonl" ]] && grep -q '"origin":"test"' "$TMP/sink/security-violations.jsonl"; echo $?)"
# control: without the seam the same event DOES reach the live sink (proves the test can fail)
printf '%s' "$EVENT" | env -u AGENT_GATE_SINK_DIR AGENT_PROJECT_DIR="$PROJ" bash "$GUARD" >/dev/null 2>&1
check "a: control — unredirected run writes the live sink" "$([[ "$(rows "$LIVE")" -gt "$after" ]]; echo $?)"

# (b) verify-all isolates a whole run
FAKE="$TMP/fake-tests"; mkdir -p "$FAKE"
cat >"$FAKE/fire-gate-test.sh" <<FAKE_EOF
#!/usr/bin/env bash
printf '%s' '$EVENT' | AGENT_PROJECT_DIR="$PROJ" bash "$GUARD" >/dev/null 2>&1
exit 0
FAKE_EOF
before=$(rows "$LIVE")
VERIFY_ALL_TESTS_DIR="$FAKE" VERIFY_ALL_SKIP_FIXED=1 bash "$REPO_ROOT/core/tests/verify-all.sh" >/dev/null 2>&1
check "b: verify-all run leaves the live sink row count unchanged" "$([[ "$(rows "$LIVE")" == "$before" ]]; echo $?)"

# --- digest fixtures: two projects, each with live + fixture rows ---
REG="$TMP/registry.md"
cat >"$REG" <<'REG_EOF'
<!-- gate-registry:begin -->
GATE g1 | pre-tool-guard.sh | deny | security-violations.jsonl | destructive | 2026-10-08 | assumption
<!-- gate-registry:end -->
REG_EOF
mk() { # dir ts origin repro
  printf '{"ts":"%s","guard":"destructive","hook":"pre-tool-guard.sh","decision":"deny","reproduce_test":%s%s}\n' \
    "$NOW" "$4" "${3:+,\"origin\":\"$3\"}" >>"$1/security-violations.jsonl"
}
P1="$TMP/p1"; P2="$TMP/p2"; mkdir -p "$P1/.agent/logs" "$P2/.agent/logs" "$TMP/main-logs"
mk "$P1/.agent/logs" x session false; mk "$P1/.agent/logs" x session false
mk "$P1/.agent/logs" x test false;    mk "$P1/.agent/logs" x "" true
mk "$P2/.agent/logs" x session false; mk "$P2/.agent/logs" x test false
mk "$TMP/main-logs" x "" false

# (c) cross-project sum: main 1 + p1 2 + p2 1 = 4
out=$(bash "$DIGEST" --gates --registry "$REG" --logs-dir "$TMP/main-logs" --projects "$P1:$P2" --json)
fired=$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["reports"][0]["fired"])')
check "c: --projects sums main + both projects (fired=4)" "$([[ "$fired" == 4 ]]; echo $?)"
solo=$(bash "$DIGEST" --gates --registry "$REG" --logs-dir "$TMP/main-logs" --json | python3 -c 'import sys,json; print(json.load(sys.stdin)["reports"][0]["fired"])')
check "c: without --projects only the main dir counts (fired=1)" "$([[ "$solo" == 1 ]]; echo $?)"

# (d) fixture rows excluded: p1 has 2, p2 has 1 -> 3
fx=$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["fixture_rows_excluded"])')
check "d: JSON fixture_rows_excluded=3" "$([[ "$fx" == 3 ]]; echo $?)"
txt=$(bash "$DIGEST" --gates --registry "$REG" --logs-dir "$TMP/main-logs" --projects "$P1:$P2")
check "d: text report prints fixture-rows-excluded: 3" "$(printf '%s' "$txt" | grep -q 'fixture-rows-excluded: 3'; echo $?)"

echo "gate-telemetry-isolation: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
