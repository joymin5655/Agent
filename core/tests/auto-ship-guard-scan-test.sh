#!/usr/bin/env bash
# auto-ship-guard-scan-test.sh — verify core/infra/auto-ship-guard-scan.py.
#
# Feeds synthetic unified diffs on stdin (never a real `gh pr diff`).
#
# Covers: (a) clean diff exit 0, (b) secret in added line of non-EXEMPT file exit 1 with
# BLOCK + path on stderr, (c) removed/context lines and +++ header ignored, (d) EXEMPT
# paths (docs/, *.test.*, /tests/) skipped, (e) exempt chunk does not leak into the next
# file, (f) AGENT_EXEMPT_PATTERNS override, (g) AGENT_SECRETS_REGEX override, (h) long
# snippet truncated to 200 chars, (i) only first 5 hits listed but all counted, (j) empty
# stdin exit 0, (k) sk- token and JWT-like token detected.
#
# Usage: bash core/tests/auto-ship-guard-scan-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/auto-ship-guard-scan.py"

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

TMP_DIR="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
unset AGENT_EXEMPT_PATTERNS AGENT_SECRETS_REGEX

scan() { python3 "$SCRIPT" 2>"$TMP_DIR/err"; }
hdr() { printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -0,0 +1 @@\n' "$1" "$1" "$1" "$1"; }

# (a)
{ hdr src/app.py; echo '+print("hello")'; } | scan; rc=$?
[[ $rc -eq 0 ]]; check "clean diff exit 0" $?

# (b)
{ hdr src/config.py; echo '+API_TOKEN = "abc"'; } | scan; rc=$?
[[ $rc -eq 1 ]] && grep -q 'BLOCK' "$TMP_DIR/err" && grep -q 'src/config.py' "$TMP_DIR/err"
check "secret in non-EXEMPT file -> exit 1 + BLOCK + path" $?

# (c)
{ hdr src/app.py; echo '-API_TOKEN = "old"'; echo ' API_KEY context'; echo '+++ b/API_KEY'; } | scan; rc=$?
[[ $rc -eq 0 ]]; check "removed/context/+++ lines ignored" $?

# (d)
for p in docs/setup.md src/foo.test.js core/tests/x.sh .env.example; do
  { hdr "$p"; echo '+API_TOKEN=example'; } | scan; rc=$?
  [[ $rc -eq 0 ]]; check "EXEMPT path skipped ($p)" $?
done

# (e)
{ hdr docs/a.md; echo '+API_KEY=doc'; hdr src/b.py; echo '+x = 1'; } | scan; rc=$?
[[ $rc -eq 0 ]]; check "exempt chunk then clean file -> exit 0" $?
{ hdr docs/a.md; echo '+API_KEY=doc'; hdr src/b.py; echo '+SERVICE_ROLE_KEY=1'; } | scan; rc=$?
[[ $rc -eq 1 ]] && grep -q 'src/b.py' "$TMP_DIR/err" && ! grep -q 'docs/a.md' "$TMP_DIR/err"
check "exempt state resets for next file" $?

# (f)
{ hdr docs/a.md; echo '+API_KEY=1'; } | AGENT_EXEMPT_PATTERNS="vendor/" scan; rc=$?
[[ $rc -eq 1 ]] && grep -q BLOCK "$TMP_DIR/err"; check "AGENT_EXEMPT_PATTERNS override un-exempts docs/" $?
{ hdr vendor/x.py; echo '+API_KEY=1'; } | AGENT_EXEMPT_PATTERNS="vendor/" scan; rc=$?
[[ $rc -eq 0 ]]; check "AGENT_EXEMPT_PATTERNS override exempts vendor/" $?

# (g)
{ hdr src/a.py; echo '+API_KEY=1'; } | AGENT_SECRETS_REGEX='HUNTME' scan; rc=$?
[[ $rc -eq 0 ]]; check "AGENT_SECRETS_REGEX replaces default (no hit)" $?
{ hdr src/a.py; echo '+x = "HUNTME"'; } | AGENT_SECRETS_REGEX='HUNTME' scan; rc=$?
[[ $rc -eq 1 ]] && grep -q BLOCK "$TMP_DIR/err"; check "AGENT_SECRETS_REGEX custom hit" $?

# (h)
long="$(python3 -c 'print("+API_KEY=" + "a"*400)')"
{ hdr src/a.py; echo "$long"; } | scan >/dev/null; 
snippet_len="$(grep 'src/a.py:' "$TMP_DIR/err" | sed 's/^  src\/a.py: //' | tr -d '\n' | wc -c | tr -d ' ')"
[[ "$snippet_len" -eq 200 ]] && grep -q '\.\.\.$' "$TMP_DIR/err"; check "long snippet truncated to 200 chars" $?

# (i)
{ hdr src/a.py; for i in 1 2 3 4 5 6 7; do echo "+API_KEY=$i"; done; } | scan >/dev/null
[[ "$(grep -c '^  src/a.py:' "$TMP_DIR/err")" -eq 5 ]] && grep -q '7 hit' "$TMP_DIR/err"; check "lists first 5 hits, counts all 7" $?

# (j)
printf '' | scan; rc=$?
[[ $rc -eq 0 ]]; check "empty stdin exit 0" $?

# (k)
{ hdr src/a.py; echo "+k = sk-$(python3 -c 'print("A"*24)')"; } | scan; rc=$?
[[ $rc -eq 1 ]] && grep -q BLOCK "$TMP_DIR/err"; check "sk- token detected" $?
{ hdr src/a.py; echo "+t = eyJ$(python3 -c 'print("a"*40)')"; } | scan; rc=$?
[[ $rc -eq 1 ]] && grep -q BLOCK "$TMP_DIR/err"; check "JWT-like token detected" $?
{ hdr src/a.py; echo "+k = sk-short"; } | scan; rc=$?
[[ $rc -eq 0 ]]; check "short sk- string not flagged (boundary)" $?

echo "auto-ship-guard-scan-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
