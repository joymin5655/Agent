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
    grade.sh) continue ;;  # loop-time grader excluded from the runner (see verify-all.sh)
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
echo "=== (9) DISCOVERED-CHECK SKIP LANE: exit 2 -> SKIP with reason, never PASS ==="
# Before this lane existed, a discovered battery could only say "I cannot run"
# by exiting 0 — which the runner printed as PASS while discarding the battery's
# own SKIP text (output is echoed on FAIL only). A battery gated on an optional
# binary (gitleaks) therefore reported green in CI having asserted nothing.
# Exit 2 is the sentinel core/infra/gitleaks-fire-test.sh and /wrap already use.
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "SKIP: widget-tool not installed"' 'exit 2' > "$D/zzz-skip-test.sh"
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -eq 0 ]]; check "discovered-skip-exit-0" $?
printf '%s\n' "$OUT" | grep -qE '^SKIP  zzz-skip-test\.sh'; check "discovered-skip-reported-SKIP" $?
printf '%s\n' "$OUT" | grep -qF 'widget-tool not installed'; check "discovered-skip-reason-surfaced" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 0 failed, 1 skipped'; check "discovered-skip-counted-skipped" $?
# the mutation this lane exists to prevent: a skipped battery must NOT read PASS.
if printf '%s\n' "$OUT" | grep -qE '^PASS  zzz-skip-test\.sh'; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "discovered-skip-not-counted-passed" $?
# exit 1 must still be a hard FAIL (the lane must not swallow real failures)
D=$(fresh_dir)
write_fail_stub "$D/zzz-fail-test.sh"
OUT2="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC2=$?
[[ $RC2 -eq 1 ]]; check "discovered-skip-lane-preserves-fail" $?
printf '%s\n' "$OUT2" | grep -qE '^FAIL  zzz-fail-test\.sh'; check "discovered-skip-lane-fail-still-FAIL" $?

echo
echo "=== (10) UNDECLARED exit 2 IS A FAILURE: bash syntax errors must not become SKIPs ==="
# bash itself exits 2 on a syntax error, and argparse exits 2 on a bad flag.
# Accepting a bare rc==2 as "inapplicable" would silently downgrade a truncated,
# merge-conflicted, or sabotaged battery from FAIL to SKIP — reachable with one
# malformed edit, since core/tests/ is ask-guarded, not deny-guarded. A skip
# must be DECLARED (a `SKIP` line), not merely signalled by the exit code.
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'if [ 1 -eq 1 ]; then' 'echo unterminated' > "$D/zzz-syntax-test.sh"
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -ne 0 ]]; check "undeclared-exit2-exit-nonzero" $?
printf '%s\n' "$OUT" | grep -qE '^FAIL  zzz-syntax-test\.sh'; check "undeclared-exit2-reported-FAIL" $?
if printf '%s\n' "$OUT" | grep -qE '^SKIP  zzz-syntax-test\.sh'; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "undeclared-exit2-not-counted-skipped" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 1 failed'; check "undeclared-exit2-tallied-failed" $?

echo
echo "=== (11) ALL-SKIP IS NOT SUCCESS: a run where nothing executed must fail loud ==="
# The floor above only refuses ZERO discovered checks. Once checks could skip
# themselves, "58 skipped, 0 passed" became a second vacuous-green shape that
# consumers (skills/harness-audit) read as a healthy harness.
D=$(fresh_dir)
printf '%s\n' '#!/usr/bin/env bash' 'echo "SKIP: widget-tool not installed"' 'exit 2' > "$D/aaa-skip-test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "SKIP: other-tool not installed"' 'exit 2' > "$D/mmm-skip-test.sh"
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -ne 0 ]]; check "all-skip-exit-nonzero" $?
printf '%s\n' "$OUT" | grep -qF 'skipped every check'; check "all-skip-error-message" $?
# and the mixed case must still succeed (the floor must not over-fire)
write_pass_stub "$D/zzz-pass-test.sh"
OUT2="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC2=$?
[[ $RC2 -eq 0 ]]; check "some-passed-some-skipped-still-exit-0" $?
printf '%s\n' "$OUT2" | grep -qF '1 passed, 0 failed, 2 skipped'; check "mixed-tally-correct" $?

echo
echo "=== (12) PARTIAL SKIP IS NOT A SKIP: a battery that runs and then breaks must FAIL ==="
# Requiring a DECLARED SKIP line was still not enough. A battery that skips one
# SUB-PROBE ("SKIP: sqlite3 missing, skipping the breaker checks"), keeps going,
# and then genuinely breaks with rc 2 satisfied "exit 2 + a SKIP line somewhere"
# and was reported as an inapplicable SKIP with the run exiting 0. No adversary
# needed — a partial-skip battery plus one bad edit. Anchoring to the FIRST line
# does not help either, since that battery declares its sub-probe skip first.
# The declaration must therefore be the ONLY non-empty line: real inapplicable
# checks detect the missing binary up front and exit having done nothing else.
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'echo "SKIP: sqlite3 missing — skipping the breaker sub-probe only"' \
  'echo "running the remaining checks..."' \
  'if [ then' > "$D/zzz-partial-test.sh"
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -ne 0 ]]; check "partial-skip-exit-nonzero" $?
printf '%s\n' "$OUT" | grep -qE '^FAIL  zzz-partial-test\.sh'; check "partial-skip-reported-FAIL" $?
if printf '%s\n' "$OUT" | grep -qE '^SKIP  zzz-partial-test\.sh'; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "partial-skip-not-counted-skipped" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 1 failed'; check "partial-skip-tallied-failed" $?
# The tightening must not break the shape real skip users emit: exactly one
# non-empty SKIP line and nothing else. Both current users are this shape, and
# a stray blank line around it must not disqualify them.
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo' 'echo "SKIP: widget-tool not installed"' 'echo' 'exit 2' \
  > "$D/zzz-clean-skip-test.sh"
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -eq 0 ]]; check "clean-skip-still-exit-0" $?
printf '%s\n' "$OUT" | grep -qE '^SKIP  zzz-clean-skip-test\.sh  \(widget-tool not installed\)'
check "clean-skip-still-skipped-with-reason" $?

echo
echo "=== (13) NO BATTERY MAY SKIP VIA exit 0: that is reported as PASS ==="
# A battery that announces `SKIP: <tool> not installed` and then exits 0 is
# printed by the runner as `PASS <name>` with its SKIP text discarded (output is
# echoed on FAIL only) — the same false green the skip lane exists to remove,
# just declared from the battery's side instead of the runner's. Two batteries
# shipped exactly this (backends-schema-test.sh, kiro-preflight-test.sh: both
# `echo "SKIP: jq not installed"; exit 0`), so with jq absent they reported PASS
# having asserted nothing. Static tripwire, because the dynamic path only shows
# up on a host that happens to be missing the optional binary — which is
# precisely where nobody is looking.
# skip_declared_with_exit_0 <file> — 0 if the file DECLARES a skip and exits 0
# right there. Two calibration lessons are baked in, both from false signals this
# check itself produced:
#
#   WINDOW. It must be tight. A 5-line window flagged a perfectly CORRECT short
#   battery — `{ echo "SKIP: jq…"; exit 2; }` up top, a few lines of checks, then
#   the normal terminal `exit 0` — because the two happened to land within five
#   lines of each other. A gate that fails a correct file is worse than one that
#   misses a bad file: it blocks every unrelated change until someone silences
#   it. So the exit must be on the SAME line as the declaration or the next one,
#   which is how both real offenders were written (`echo "SKIP…"; exit 0`).
#
#   VERBS AND QUOTING. It must cover how skips are actually spelled HERE:
#   `echo`, `echo -e`, `printf`, single OR double quotes, and the
#   `printf '%s\n' "SKIP…"` format-then-argument form — which is this repo's
#   dominant printf idiom (242 occurrences), and so the most likely way an author
#   here would write one. SKIP must still START the printed string; matching the
#   word anywhere flagged telemetry-digest-test.sh, whose section HEADER merely
#   describes the skip behaviour of the script it tests.
#
# NOT a proof — a source-text heuristic. `exit "$rc"` where rc is 0, and a skip
# whose exit lives elsewhere in the file, are not detected. The contract in
# verify-all.sh's header is the actual rule.
skip_declared_with_exit_0() {
  grep -A1 -E "(echo|printf)[[:space:]]+(-e[[:space:]]+)?('%s.n'|\"%s.n\")?[[:space:]]*[\"']?SKIP([[:space:]]|:|\\\\n|\"|')" "$1" 2>/dev/null \
    | grep -qE 'exit[[:space:]]+0'
}
REAL_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
offenders=""
for f in "$REAL_TESTS_DIR"/*.sh; do
  case "$(basename "$f")" in verify-all-test.sh) continue ;; esac
  if skip_declared_with_exit_0 "$f"; then offenders="$offenders $(basename "$f")"; fi
done
[[ -z "$offenders" ]]; check "no-battery-skips-with-exit-0" $?
[[ -n "$offenders" ]] && echo "    offenders:$offenders — a SKIP must exit 2, or the runner reports it as PASS"
# The tripwire must actually FIRE, or the check above is vacuously green. Both
# print verbs and a non-adjacent exit are exercised, because those are the two
# ways the first version was blind.
D=$(fresh_dir)
# Every spelling a battery author here would plausibly use must be caught. The
# first version knew only `echo "SKIP` and missed four of these.
printf '%s\n' '#!/usr/bin/env bash' 'echo "SKIP: widget not installed"' 'exit 0' > "$D/e.sh"
skip_declared_with_exit_0 "$D/e.sh"; check "tripwire-detects-echo-double-quoted" $?
printf '%s\n' '#!/usr/bin/env bash' "echo 'SKIP: widget not installed'" 'exit 0' > "$D/e2.sh"
skip_declared_with_exit_0 "$D/e2.sh"; check "tripwire-detects-echo-single-quoted" $?
printf '%s\n' '#!/usr/bin/env bash' 'echo -e "SKIP: widget not installed"' 'exit 0' > "$D/e3.sh"
skip_declared_with_exit_0 "$D/e3.sh"; check "tripwire-detects-echo-dash-e" $?
printf '%s\n' '#!/usr/bin/env bash' 'printf "SKIP: widget not installed\n"' 'exit 0' > "$D/p.sh"
skip_declared_with_exit_0 "$D/p.sh"; check "tripwire-detects-printf-direct" $?
# this repo's dominant printf idiom — the format string carries no SKIP at all.
# Written as a quoted heredoc: building this line with printf/echo escaping is
# how the fixture silently ended up with a doubled backslash and tested nothing.
cat > "$D/p2.sh" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "SKIP: widget not installed"
exit 0
FIXTURE
skip_declared_with_exit_0 "$D/p2.sh"; check "tripwire-detects-printf-format-arg" $?
printf '%s\n' '#!/usr/bin/env bash' 'command -v jq || { echo "SKIP: jq"; exit 0; }' 'run' > "$D/g.sh"
skip_declared_with_exit_0 "$D/g.sh"; check "tripwire-detects-same-line-guard" $?
# ...and it must NOT fire on correct code, or it is noise that gets silenced.
printf '%s\n' '#!/usr/bin/env bash' 'echo "SKIP: widget not installed"' 'exit 2' > "$D/ok.sh"
if skip_declared_with_exit_0 "$D/ok.sh"; then fp=1; else fp=0; fi
[[ $fp -eq 0 ]]; check "tripwire-no-false-positive-on-exit-2" $?
# The FP that a 5-line window actually produced: a CORRECT short battery whose
# guard exits 2 and whose normal terminal exit 0 happened to land nearby.
printf '%s\n' '#!/usr/bin/env bash' 'command -v jq || { echo "SKIP: jq"; exit 2; }' \
  'run_checks' 'report' 'exit 0' > "$D/short.sh"
if skip_declared_with_exit_0 "$D/short.sh"; then fp=1; else fp=0; fi
[[ $fp -eq 0 ]]; check "tripwire-no-false-positive-on-short-correct-battery" $?
# ...and prose describing the behaviour of some OTHER script
printf '%s\n' '#!/usr/bin/env bash' 'echo "=== (n) missing log -> LOUD SKIP, exit 0 ==="' 'run' 'exit 0' > "$D/prose.sh"
if skip_declared_with_exit_0 "$D/prose.sh"; then fp=1; else fp=0; fi
[[ $fp -eq 0 ]]; check "tripwire-no-false-positive-on-prose" $?
# KNOWN BLIND SPOTS, named so this is not mistaken for proof: `exit "$rc"` where
# rc is 0, and a skip whose exit lives further away than the next line, both slip
# past. Detecting those needs control-flow analysis, not a regex; widening the
# window instead is what produced the false positive pinned above. This raises
# the cost of the mistake; it does not make it impossible. The contract in
# verify-all.sh's header is the actual rule.
echo "    (heuristic: exit-code indirection and distant exits are NOT detected)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
