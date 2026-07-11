#!/usr/bin/env bash
# tdd-guard-test.sh — verify core/hooks/tdd-guard.py (P1-3 — this hook had no test).
#
# tdd-guard is a PreToolUse hook enforcing Red-Green-Refactor: writing in-scope
# production code needs a FAILING test in the area. Modes: off / dryrun (default,
# advisory) / block (deny). It resolves the repo root via `git rev-parse`, so each
# case runs inside a fresh mktemp git repo; the test cache and dryrun sink are
# repo-relative and pointed at that throwaway tree.
#
# Covers:
#   MODE=off                       -> always exit 0, empty stdout
#   out-of-scope file              -> allow (exit 0, empty)
#   risk-area path (secrets/)      -> guard_skip allow
#   test/spec file                 -> skip, allow
#   stale/missing cache            -> allow (can't enforce), dryrun logs mode_stale
#   in-scope + no test in area     -> block-mode deny / dryrun advisory
#   in-scope + FAILING test (red)  -> allow
#   in-scope + all-green test      -> block-mode deny (must write a failing test)
#   malformed stdin                -> no crash, exit 0
#
# Usage: bash core/tests/tdd-guard-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/tdd-guard.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# fresh_repo — new git repo with a fresh cache dir; echoes its path.
fresh_repo() {
  local r; r="$(mktemp -d "$TMP_ROOT/repoXXXXXX")"
  (cd "$r" && git init -q)
  mkdir -p "$r/.agent/state" "$r/.agent/logs"
  printf '%s' "$r"
}

# write_cache <repo> <fresh_json> — write the test-run cache (fresh mtime).
write_cache() {
  printf '%s' "$2" > "$1/.agent/state/test-last-run.json"
}

# run <repo> <mode> <file_path> — feed the event; sets OUT/RC (run from repo cwd
# so git rev-parse resolves to the fixture, not the real repo).
OUT=""; RC=0
run() {
  local repo="$1" mode="$2" fp="$3" ev
  ev=$(FP="$fp" python3 -c 'import os,json;print(json.dumps({"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":os.environ["FP"]}}))')
  OUT=$(cd "$repo" && printf '%s' "$ev" | AGENT_TDD_GUARD_MODE="$mode" python3 "$HOOK" 2>/dev/null)
  RC=$?
}
is_deny() { [[ "$OUT" == *'"permissionDecision": "deny"'* || "$OUT" == *'"permissionDecision":"deny"'* ]]; }

echo "=== (a) MODE=off -> always allow, empty stdout ==="
R=$(fresh_repo)
run "$R" off "src/foo.ts"
[[ $RC -eq 0 && -z "$OUT" ]]; check "mode-off-empty" $?

echo
echo "=== (b) out-of-scope file -> allow ==="
R=$(fresh_repo)
run "$R" block "docs/readme.md"
[[ $RC -eq 0 && -z "$OUT" ]]; check "out-of-scope-allow" $?

echo
echo "=== (c) risk-area path (secrets/) -> guard_skip allow, logged ==="
R=$(fresh_repo)
run "$R" block "src/secrets/loader.ts"
[[ $RC -eq 0 ]] && ! is_deny; check "risk-area-allow" $?
grep -q 'guard_skip' "$R/.agent/logs/tdd-guard-dryrun.jsonl" 2>/dev/null; check "risk-area-logged" $?

echo
echo "=== (d) test file itself -> skip, allow ==="
R=$(fresh_repo)
run "$R" block "src/foo.test.ts"
[[ $RC -eq 0 && -z "$OUT" ]]; check "test-file-skip" $?

echo
echo "=== (e) stale/missing cache -> allow (cannot enforce), logs mode_stale ==="
R=$(fresh_repo)   # no cache written
run "$R" block "src/foo.ts"
[[ $RC -eq 0 ]] && ! is_deny; check "stale-cache-allow" $?
grep -q 'mode_stale' "$R/.agent/logs/tdd-guard-dryrun.jsonl" 2>/dev/null; check "stale-cache-logged" $?

echo
echo "=== (f) in-scope + no test in area + fresh cache -> block-mode deny ==="
R=$(fresh_repo)
write_cache "$R" '{"testResults":[]}'
run "$R" block "src/foo.ts"
is_deny; check "no-test-block-deny" $?
# dryrun mode on the same setup must NOT deny (advisory only)
run "$R" dryrun "src/foo.ts"
[[ $RC -eq 0 ]] && ! is_deny; check "no-test-dryrun-advisory" $?

echo
echo "=== (g) in-scope + FAILING test in area (RGR red) -> allow ==="
R=$(fresh_repo)
write_cache "$R" '{"testResults":[{"file":"src/foo.test.ts","assertionResults":[{"status":"failed"}]}]}'
run "$R" block "src/foo.ts"
[[ $RC -eq 0 ]] && ! is_deny; check "failing-test-allow" $?

echo
echo "=== (h) in-scope + all-green test -> block-mode deny (write a failing test) ==="
R=$(fresh_repo)
write_cache "$R" '{"testResults":[{"file":"src/foo.test.ts","assertionResults":[{"status":"passed"}]}]}'
run "$R" block "src/foo.ts"
is_deny; check "green-test-block-deny" $?

echo
echo "=== (i) malformed stdin -> no crash, exit 0 ==="
R=$(fresh_repo)
OUT=$(cd "$R" && printf 'not json{' | AGENT_TDD_GUARD_MODE=block python3 "$HOOK" 2>/dev/null); RC=$?
[[ $RC -eq 0 ]]; check "malformed-no-crash" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
