#!/usr/bin/env bash
# setup-doctor-test.sh — verify `setup.sh --doctor` environment diagnosis.
#
# Covers: (a) exit 0 + summary-line format on the current repo (pure
# read-only — no side effects), (b) gitleaks WARN when PATH excludes it,
# (c) exit 1 + a named FAIL line when a hook script loses its executable
# bit (exercised against a throwaway copy in mktemp — the real repo tree
# is never touched).
#
# Usage: bash core/tests/setup-doctor-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

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

echo "=== (a) --doctor on the current repo: exit 0 + summary line ==="
OUT_A="$(bash "$SETUP" --doctor 2>&1)"
RC_A=$?
[[ $RC_A -eq 0 ]]
check "exit-0-on-clean-repo" $?
[[ "$OUT_A" == *"doctor: "*" pass, "*" warn, "*" fail"* ]]
check "summary-line-format" $?
if [[ $RC_A -ne 0 ]]; then
  echo "  --- doctor output (for diagnosis) ---"
  echo "$OUT_A" | sed 's/^/  | /'
fi

echo
echo "=== (b) gitleaks WARN when PATH excludes it ==="
OUT_B="$(PATH=/usr/bin:/bin bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_B" == *"[WARN"*"gitleaks"* ]]
check "gitleaks-warn-without-path" $?

echo
echo "=== (c) missing hook executable bit -> exit 1 + FAIL line naming it ==="
TMP_COPY="$(mktemp -d)"
cp -R "$REPO_ROOT"/. "$TMP_COPY"/
chmod -x "$TMP_COPY/core/hooks/pre-tool-guard.sh"
OUT_C="$(bash "$TMP_COPY/setup.sh" --doctor 2>&1)"
RC_C=$?
rm -rf "$TMP_COPY"
[[ $RC_C -eq 1 ]]
check "exit-1-on-missing-exec-bit" $?
[[ "$OUT_C" == *"[FAIL"*"pre-tool-guard.sh"* ]]
check "fail-line-names-file" $?

echo
echo "=== (d) plugin cache: two cached versions -> WARN naming both ==="
CACHE_FIX="$(mktemp -d)"
mkdir -p "$CACHE_FIX/somemarket/agent-harness/0.1.0" "$CACHE_FIX/somemarket/agent-harness/0.2.0"
OUT_D="$(AGENT_PLUGIN_CACHE_ROOT="$CACHE_FIX" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_D" == *"[WARN"*"2 cached agent-harness versions"*"0.1.0,0.2.0"* ]]
check "dual-cache-warn" $?

echo
echo "=== (e) plugin cache: single version -> PASS ==="
rm -rf "$CACHE_FIX/somemarket/agent-harness/0.1.0"
OUT_E="$(AGENT_PLUGIN_CACHE_ROOT="$CACHE_FIX" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_E" == *"[PASS"*"single agent-harness version cached (0.2.0)"* ]]
check "single-cache-pass" $?
rm -rf "$CACHE_FIX"

echo
echo "=== (f) hook manifest: declared == live -> reconciled PASS ==="
MF_FIX="$(mktemp -d)"
cat > "$MF_FIX/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"node \"/home/u/.claude/hooks/alpha-guard.js\""},
  {"type":"command","command":"bash \"/home/u/.claude/hooks/beta-state.sh\""}]}]}}
JSON
printf '# declared hooks\nalpha-guard.js\nbeta-state.sh\n' > "$MF_FIX/manifest"
OUT_F="$(AGENT_HOOK_MANIFEST="$MF_FIX/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_F" == *"[PASS"*"2 declared / 2 live hooks all reconciled"* ]]
check "manifest-reconciled-pass" $?

echo
echo "=== (g) hook manifest: drift both directions -> WARN with details ==="
printf 'alpha-guard.js\ngamma-missing.sh\n' > "$MF_FIX/manifest"
OUT_G="$(AGENT_HOOK_MANIFEST="$MF_FIX/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_G" == *"[WARN"*"drift"*"declared-but-not-live: gamma-missing.sh"* ]]
check "manifest-drift-warn-missing" $?
[[ "$OUT_G" == *"live-but-undeclared: beta-state.sh"* ]]
check "manifest-drift-warn-undeclared" $?
RC_G_OUT="$(AGENT_HOOK_MANIFEST="$MF_FIX/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX/settings.json" bash "$SETUP" --doctor >/dev/null 2>&1; echo $?)"
[[ "$RC_G_OUT" -eq 0 ]]
check "manifest-drift-is-warn-not-fail" $?
rm -rf "$MF_FIX"

echo
echo "=== (g2) hook manifest: structurally malformed settings -> clean WARN, no traceback ==="
MF_FIX2="$(mktemp -d)"
printf 'alpha-guard.js\n' > "$MF_FIX2/manifest"
printf '{"hooks":{"PreToolUse":"not-a-list"}}' > "$MF_FIX2/settings.json"
OUT_G2="$(AGENT_HOOK_MANIFEST="$MF_FIX2/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX2/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_G2" == *"[WARN"*"malformed hooks structure"* ]]
check "manifest-malformed-structure-warn" $?
[[ "$OUT_G2" != *"Traceback"* ]]
check "manifest-malformed-no-traceback" $?

echo
echo "=== (g3) hook manifest: UTF-8 BOM in manifest -> still reconciles ==="
printf '\xef\xbb\xbfalpha-guard.js\n' > "$MF_FIX2/manifest"
cat > "$MF_FIX2/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"node \"/home/u/.claude/hooks/alpha-guard.js\""}]}]}}
JSON
OUT_G3="$(AGENT_HOOK_MANIFEST="$MF_FIX2/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX2/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_G3" == *"[PASS"*"1 declared / 1 live hooks all reconciled"* ]]
check "manifest-bom-reconciles" $?
rm -rf "$MF_FIX2"

echo
echo "=== (h) hook manifest: absent -> check skipped, exit unaffected ==="
OUT_H="$(AGENT_HOOK_MANIFEST=/nonexistent/no-manifest bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_H" == *"hook manifest — none at /nonexistent/no-manifest (check skipped)"* ]]
check "manifest-absent-skip" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
