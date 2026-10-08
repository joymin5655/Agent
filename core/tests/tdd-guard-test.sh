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
echo "=== (j) hook-config risk_areas.secrets.paths UNIONs with the built-in whitelist ==="
write_cfg() { printf '%s' "$2" > "$1/.agent/hook-config.json"; }
armed_repo() { local r; r=$(fresh_repo); write_cache "$r" '{"testResults":[]}'; printf '%s' "$r"; }
LOG() { printf '%s' "$1/.agent/logs/tdd-guard-dryrun.jsonl"; }
CFG='{"risk_areas":{"secrets":{"paths":["vault/**"]}}}'
R=$(armed_repo)
run "$R" block "src/vault/k.ts"; is_deny; check "no-config-vault-enforced" $?
run "$R" block "src/secrets/k.ts"; ! is_deny; check "no-config-builtin-secret-allowed" $?
write_cfg "$R" "$CFG"
run "$R" block "src/vault/k.ts"; ! is_deny; check "config-vault-allowed" $?
grep -q 'secret-config' "$(LOG "$R")"; check "config-vault-logged" $?
run "$R" block "src/secrets/k.ts"; ! is_deny; check "union-builtin-secrets-still-allowed" $?
run "$R" block "src/.env.local.ts"; ! is_deny; check "union-builtin-env-still-allowed" $?
run "$R" block "src/billing/x.ts"; ! is_deny; check "union-keeps-billing" $?
run "$R" block "src/vaultish/k.ts"; is_deny; check "dir-token-path-anchored" $?
run "$R" block "$R/src/vault/k.ts"; ! is_deny; check "absolute-path-allowed" $?

echo
echo "=== (k) bare-word tokens never exempt; right boundary enforced ==="
R=$(armed_repo)
write_cfg "$R" '{"risk_areas":{"secrets":{"paths":["env","src","auth","vault/keys"]}}}'
run "$R" block "src/envelope.py"; is_deny; check "bare-env-does-not-exempt-envelope" $?
run "$R" block "src/foo.ts"; is_deny; check "bare-src-does-not-exempt-all" $?
run "$R" block "src/auth/login.ts"; is_deny; check "bare-auth-does-not-exempt" $?
run "$R" block "src/vault/keys/a.ts"; ! is_deny; check "slash-token-exempts" $?
run "$R" block "src/vault/keysmith/a.ts"; is_deny; check "slash-token-right-boundary" $?
ERR=$(cd "$R" && printf '%s' '{"tool_input":{"file_path":"src/foo.ts"}}' | AGENT_TDD_GUARD_MODE=block python3 "$HOOK" 2>&1 >/dev/null)
[[ "$ERR" == *"ignored bare-word"* ]]; check "bare-token-stderr-note" $?

echo
echo "=== (l) broken config falls back to built-ins (positive evidence) ==="
R=$(armed_repo); write_cfg "$R" '{not json'
run "$R" block "src/secrets/k.ts"; [[ $RC -eq 0 && -z "$OUT" ]]; check "bad-config-builtin-allow-empty" $?
grep -q '"guard_area": "secret"' "$(LOG "$R")"; check "bad-config-builtin-logged" $?
run "$R" block "src/vault/k.ts"; is_deny; check "bad-config-no-extra-exempt" $?

echo
echo "=== (m) .yml, .yml+.json together, project-dir resolution ==="
if python3 -c 'import yaml' 2>/dev/null; then
  R=$(armed_repo)
  printf 'risk_areas:\n  secrets:\n    paths:\n      - "ymlonly/**"\n' > "$R/.agent/hook-config.yml"
  run "$R" block "src/ymlonly/k.ts"; ! is_deny; check "yml-token-allowed" $?
  write_cfg "$R" '{"risk_areas":{"secrets":{"paths":["jsononly/**"]}}}'
  run "$R" block "src/ymlonly/k.ts"; ! is_deny; check "both-yml-token-allowed" $?
  run "$R" block "src/jsononly/k.ts"; ! is_deny; check "both-json-token-allowed" $?
else
  echo "  skip [yml cases] PyYAML not importable"
fi
R=$(armed_repo); P=$(fresh_repo); write_cfg "$P" "$CFG"
OUT=$(cd "$R" && printf '%s' '{"tool_input":{"file_path":"src/vault/k.ts"}}' | AGENT_PROJECT_DIR="$P" AGENT_TDD_GUARD_MODE=block python3 "$HOOK" 2>/dev/null)
[[ -z "$OUT" ]]; check "agent-project-dir-config-root" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
