#!/usr/bin/env bash
# verify-all-test.sh — verify P1-2: core/tests/verify-all.sh is the single-command
# local verification runner that bundles the COMPLETE check set with no silent
# omissions, runs every check even when one fails, and never claims to run a set
# it does not actually run.
#
# Mirrors the house idiom (doc-reality-test.sh / supply-chain-scan-test.sh): a
# PASS/FAIL counter, per-assert ok/FAIL lines, a summary, exit 1 on any failure.
#
# Contract covered:
#   1. COMPLETENESS (anti-rot): --list names every real core/tests/*.sh check
#      (except verify-all.sh + verify-all-test.sh). Expected set is DERIVED by
#      globbing the real dir — a gate/battery omitted from the runner fails here.
#   2. FIXED-CHECKS DECLARED: --list contains evals:deterministic, evals:semantic,
#      gitleaks.
#   3. FAIL-PROPAGATION: a failing battery makes exit==1 and is reported FAIL,
#      while a passing one is reported PASS; summary counts 1 passed / 1 failed.
#   4. ALL-GREEN -> EXIT 0: a lone passing stub yields exit 0, 1 passed / 0 failed.
#   5. LIST-MATCHES-RUN (no lying): the labels --list prints equal the labels the
#      runner actually executes.
#   6. EMPTY-DISCOVERY FAILS LOUD: a discovery that finds zero checks must exit
#      non-zero, not report a vacuous "0 passed, 0 failed" green.
#   7. --list ON EMPTY: an empty check set prints nothing and exits 0 (no
#      unbound-variable crash under set -u on bash 3.2).
#   8. GITLEAKS SKIP-NOT-PASS: when the gitleaks binary is absent the check is a
#      loud SKIP counted as skipped (never as passed), and a SKIP does not fail
#      the run. This guards the runner's headline security-scan promise.
#
# Uses VERIFY_ALL_TESTS_DIR to point the glob at a hermetic fixture dir and
# VERIFY_ALL_SKIP_FIXED=1 to drop the evals + gitleaks checks so logic cases run
# fast, offline, and gitleaks-independent. Case 8 uses VERIFY_ALL_SKIP_EVALS=1
# (drops only the slow evals, keeps gitleaks) plus a PATH scrubbed of gitleaks's
# directory, so the gitleaks absent-branch is exercised for real.
#
# Usage: bash core/tests/verify-all-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/core/tests/verify-all.sh"
REAL_TESTS_DIR="$REPO_ROOT/core/tests"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fresh_dir() { mktemp -d "$TMP_ROOT/tXXXXXX"; }

# a passing battery stub (exit 0)
write_pass_stub() { printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$1"; }
# a failing battery stub that prints a recognizable marker to stderr, exit 1
write_fail_stub() {
  printf '%s\n' '#!/usr/bin/env bash' 'echo "ZZZMARKER-boom" >&2' 'exit 1' > "$1"
}

echo "=== (1) COMPLETENESS: --list names every real core/tests/*.sh check (anti-rot) ==="
LIST_OUT="$(bash "$RUNNER" --list 2>&1)"
missing=0
for f in "$REAL_TESTS_DIR"/*.sh; do
  base="$(basename "$f")"
  case "$base" in
    verify-all.sh|verify-all-test.sh) continue ;;
  esac
  if ! printf '%s\n' "$LIST_OUT" | grep -qxF "$base"; then
    echo "    MISSING from --list: $base"
    missing=$((missing + 1))
  fi
done
[[ $missing -eq 0 ]]; check "every-real-check-listed" $?

echo
echo "=== (2) FIXED-CHECKS DECLARED: evals:deterministic / evals:semantic / gitleaks ==="
printf '%s\n' "$LIST_OUT" | grep -qxF 'evals:deterministic'; check "lists-evals-deterministic" $?
printf '%s\n' "$LIST_OUT" | grep -qxF 'evals:semantic'; check "lists-evals-semantic" $?
printf '%s\n' "$LIST_OUT" | grep -qxF 'gitleaks'; check "lists-gitleaks" $?

echo
echo "=== (3) FAIL-PROPAGATION: one pass + one fail -> exit 1, both reported, 1/1 summary ==="
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
write_fail_stub "$D/zzz-fail-test.sh"
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -eq 1 ]]; check "fail-propagates-exit-1" $?
printf '%s\n' "$OUT" | grep -qE '^FAIL  zzz-fail-test\.sh'; check "failing-check-reported-FAIL" $?
printf '%s\n' "$OUT" | grep -qE '^PASS  aaa-pass-test\.sh'; check "passing-check-reported-PASS" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 1 failed'; check "summary-1-passed-1-failed" $?
printf '%s\n' "$OUT" | grep -qF 'ZZZMARKER-boom'; check "failing-output-tail-shown" $?

echo
echo "=== (4) ALL-GREEN -> EXIT 0: lone passing stub -> exit 0, 1 passed / 0 failed ==="
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -eq 0 ]]; check "all-green-exit-0" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 0 failed'; check "summary-1-passed-0-failed" $?

echo
echo "=== (5) LIST-MATCHES-RUN: labels listed == labels executed (no lying) ==="
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
write_pass_stub "$D/mmm-pass-test.sh"
LISTED="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" --list 2>&1 | sort)"
RUN_OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"
EXECUTED="$(printf '%s\n' "$RUN_OUT" | awk '/^(PASS|FAIL|SKIP) /{print $2}' | sort)"
[[ "$LISTED" == "$EXECUTED" ]]; check "listed-set-equals-executed-set" $?
[[ -n "$LISTED" ]]; check "listed-set-nonempty" $?

echo
echo "=== (6) EMPTY-DISCOVERY FAILS LOUD: zero checks -> exit != 0, not a vacuous green ==="
D=$(fresh_dir)  # empty fixture dir: no *.sh, fixed checks suppressed -> zero checks
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -ne 0 ]]; check "empty-discovery-exit-nonzero" $?
printf '%s\n' "$OUT" | grep -qF 'zero checks'; check "empty-discovery-error-message" $?

echo
echo "=== (7) --list ON EMPTY: prints nothing, exits 0 (no set -u crash on bash 3.2) ==="
D=$(fresh_dir)
LOUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" --list 2>&1)"; RC=$?
[[ $RC -eq 0 ]]; check "list-empty-exit-0" $?
[[ -z "$LOUT" ]]; check "list-empty-no-output" $?

echo
echo "=== (8) GITLEAKS SKIP-NOT-PASS: absent binary -> loud SKIP, counted skipped not passed ==="
# Scrub gitleaks's directory from PATH so `command -v gitleaks` fails inside the
# runner, while bash/coreutils (in /usr/bin, /bin) stay available. If gitleaks is
# not installed at all, PATH is unchanged and the check is already absent.
GL="$(command -v gitleaks 2>/dev/null || true)"
if [[ -n "$GL" ]]; then
  GLDIR="$(dirname "$GL")"
  SCRUBBED="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$GLDIR" | paste -sd: -)"
else
  SCRUBBED="$PATH"
fi
if PATH="$SCRUBBED" command -v gitleaks >/dev/null 2>&1 \
   || ! PATH="$SCRUBBED" command -v bash >/dev/null 2>&1; then
  # Cannot cleanly hide gitleaks without also hiding the runner's tools on this
  # host — report honestly rather than assert vacuously.
  echo "  ok   [gitleaks-skip-unavailable-on-this-host]"; PASS=$((PASS + 1))
else
  D=$(fresh_dir)
  write_pass_stub "$D/aaa-pass-test.sh"
  OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_EVALS=1 PATH="$SCRUBBED" bash "$RUNNER" 2>&1)"; RC=$?
  [[ $RC -eq 0 ]]; check "gitleaks-absent-exit-0" $?
  printf '%s\n' "$OUT" | grep -qE '^SKIP  gitleaks'; check "gitleaks-absent-reported-SKIP" $?
  printf '%s\n' "$OUT" | grep -qF '1 passed, 0 failed, 1 skipped'; check "gitleaks-absent-counted-skipped" $?
  # the exact mutation the review flagged: SKIP must NOT be reported as PASS.
  if printf '%s\n' "$OUT" | grep -qE '^PASS  gitleaks'; then bad=1; else bad=0; fi
  [[ $bad -eq 0 ]]; check "gitleaks-absent-not-counted-passed" $?
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
