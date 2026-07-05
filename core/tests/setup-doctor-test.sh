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
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
