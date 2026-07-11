#!/usr/bin/env bash
# remote-url-scan-test.sh — verify core/git-hooks/scan-remote-url.py (W-3) and the
# gitleaks fire-drill core/infra/gitleaks-fire-test.sh.
#
# scan-remote-url.py flags an http(s) remote URL that embeds a credential
# (password userinfo or token-shaped userinfo) while never false-positiving on
# ssh / clean URLs / bare usernames. The synthetic token strings are assembled at
# runtime so this test file itself carries no secret literal.
#
# Usage: bash core/tests/remote-url-scan-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAN="$REPO_ROOT/core/git-hooks/scan-remote-url.py"
FIRE="$REPO_ROOT/core/infra/gitleaks-fire-test.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

# Runtime-assembled userinfo tokens (no secret literal in this file).
GH_PAT="ghp_$(printf 'A%.0s' $(seq 1 36))"
GEN_TOKEN="s3cr3t$(printf 'x%.0s' $(seq 1 10))"

# run_case <name> <url> <expect: block|allow>
run_case() {
  local name="$1" url="$2" expect="$3"
  printf '%s\n' "$url" | python3 "$SCAN" >/dev/null 2>&1
  local rc=$? got="allow"
  [[ $rc -eq 1 ]] && got="block"
  if [[ "$got" == "$expect" ]]; then echo "  ok   [$name] ($got)"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected=$expect got=$got (rc=$rc)"; FAIL=$((FAIL + 1)); fi
}

echo "=== block: http(s) URLs embedding a credential ==="
run_case "password-userinfo-block" "https://alice:${GEN_TOKEN}@github.com/o/r.git" block
run_case "ghp-token-userinfo-block" "https://${GH_PAT}@github.com/o/r.git"          block
run_case "http-scheme-block"        "http://u:${GEN_TOKEN}@example.com/x.git"       block

echo
echo "=== allow: no embedded credential (no false positives) ==="
run_case "ssh-scp-style-allow"      "git@github.com:o/r.git"                        allow
run_case "ssh-scheme-allow"         "ssh://git@github.com/o/r.git"                  allow
run_case "clean-https-allow"        "https://github.com/o/r.git"                    allow
run_case "bare-username-allow"      "https://alice@github.com/o/r.git"              allow

echo
echo "=== git remote -v line form is parsed (URL extracted from the line) ==="
printf 'origin\thttps://%s@github.com/o/r.git (push)\n' "$GH_PAT" | python3 "$SCAN" >/dev/null 2>&1
[[ $? -eq 1 ]]; check "remote-v-line-block" $?
printf 'origin\thttps://github.com/o/r.git (fetch)\n' | python3 "$SCAN" >/dev/null 2>&1
[[ $? -eq 0 ]]; check "remote-v-clean-line-allow" $?

echo
echo "=== redaction: the secret is never echoed back ==="
OUT_R="$(printf '%s\n' "https://alice:${GEN_TOKEN}@github.com/o/r.git" | python3 "$SCAN" 2>&1 || true)"
[[ "$OUT_R" == *"***@github.com"* && "$OUT_R" != *"$GEN_TOKEN"* ]]
check "secret-redacted-in-output" $?

echo
echo "=== empty / malformed input -> allow (exit 0), no crash ==="
printf '\n' | python3 "$SCAN" >/dev/null 2>&1; check "empty-input-allow" $?
printf 'not a url at all\n' | python3 "$SCAN" >/dev/null 2>&1; check "garbage-input-allow" $?

echo
echo "=== gitleaks fire-drill: detects a planted synthetic secret (or SKIPs cleanly) ==="
FIRE_OUT="$(bash "$FIRE" 2>&1)"; FIRE_RC=$?
if [[ $FIRE_RC -eq 2 ]]; then
  echo "  ok   [fire-drill-skip-when-no-gitleaks] (SKIP: gitleaks absent)"; PASS=$((PASS + 1))
  [[ "$FIRE_OUT" == *"SKIP"* ]]; check "fire-drill-skip-is-loud" $?
else
  [[ $FIRE_RC -eq 0 && "$FIRE_OUT" == *"PASS"*"gate is live"* ]]
  check "fire-drill-detects-planted-secret" $?
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
