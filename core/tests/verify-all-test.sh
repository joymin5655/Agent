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
#   9-13. SKIP lane, undeclared/partial skip, all-skip floor, no exit-0 skips (see below).
#   14. SHARDING PARTITION: for every N in 1..5, the union of `--shard k/N --list` over
#       k=1..N equals `--list` exactly, with no label in two shards.
#   15. SHARD ARGUMENT VALIDATION: 0/4, 5/4, abc, 2/0 (and a missing value / unknown flag)
#       exit 1 with an error message; --list and --shard combine in either order.
#   16. WEIGHTS ARE HONOURED: with VERIFY_ALL_WEIGHTS pointing at a fixture, the two heavy
#       checks land in different shards, run order inside a shard is kept (gates first),
#       and a shard run executes only its own checks.
#   17. CI MATRIX is 1..N for `--shard N`, and a repeated --shard is rejected.
#   18-22. MUST-RUN (verify-all-must-run.txt): a pinned check that skips is a FAIL (a declared
#       skip, or gitleaks absent) while an unpinned one stays a SKIP; a pinned label missing from
#       the whole set fails in every shard but one living in another shard does not; the local /
#       ci profiles, their detection and the VERIFY_ALL_ENV override; the list file's format
#       (comments, duplicates, malformed lines) and a missing list being an error, in the real
#       tree or behind a mistyped override; the shipped list has no stale label, pins every
#       battery that declares a skip lane in the right profile, and keeps gitleaks local-only.
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
# shipped exactly this (backends-schema-test.sh and kiro-preflight-test.sh, the
# latter since moved to legacy/lanes-2026-10/tests/: both
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
echo "=== (14) SHARDING PARTITION: union of shards == full --list, no overlap ==="
FULL_SORTED="$(bash "$RUNNER" --list 2>&1 | sort)"
for n in 1 2 3 4 5; do
  union=""
  shard_rc=0
  for k in $(seq 1 "$n"); do
    out="$(bash "$RUNNER" --shard "$k/$n" --list 2>&1)" || shard_rc=1
    union="$union$out"$'\n'
  done
  union_sorted="$(printf '%s' "$union" | grep -v '^$' | sort)"
  [[ $shard_rc -eq 0 ]]; check "shard-N$n-all-exit-0" $?
  [[ "$union_sorted" == "$FULL_SORTED" ]]; check "shard-N$n-union-equals-full-list" $?
  [[ -z "$(printf '%s\n' "$union_sorted" | uniq -d)" ]]; check "shard-N$n-no-duplicates" $?
done

echo
echo "=== (15) SHARD ARGUMENT VALIDATION: bad K/N -> exit 1 + message; flags combine in any order ==="
for bad in 0/4 5/4 abc 2/0 1/ /4 -1/4 1.5/4; do
  err="$(bash "$RUNNER" --shard "$bad" --list 2>&1 >/dev/null)"; rc=$?
  [[ $rc -eq 1 ]]; check "shard-bad-$bad-exit-1" $?
  printf '%s\n' "$err" | grep -qF -- '--shard'; check "shard-bad-$bad-has-error-message" $?
done
bash "$RUNNER" --shard >/dev/null 2>&1; [[ $? -eq 1 ]]; check "shard-missing-value-exit-1" $?
bash "$RUNNER" --bogus >/dev/null 2>&1; [[ $? -eq 1 ]]; check "unknown-flag-exit-1" $?
A="$(bash "$RUNNER" --shard 2/3 --list 2>&1)"; B="$(bash "$RUNNER" --list --shard 2/3 2>&1)"
C="$(bash "$RUNNER" --shard=2/3 --list 2>&1)"
[[ -n "$A" && "$A" == "$B" && "$A" == "$C" ]]; check "shard-and-list-order-independent" $?
# 1/1 is the identity: the whole suite, in run order
[[ "$(bash "$RUNNER" --shard 1/1 --list 2>&1)" == "$(bash "$RUNNER" --list 2>&1)" ]]
check "shard-1-of-1-is-identity" $?

echo
echo "=== (16) WEIGHTS ARE HONOURED: heavy checks split, run order kept, shard runs only its own ==="
D=$(fresh_dir)
write_pass_stub "$D/gate-a.sh"          # a gate (non-*-test.sh): runs before batteries
write_pass_stub "$D/aaa-light-test.sh"
write_pass_stub "$D/bbb-heavy-test.sh"
write_pass_stub "$D/ccc-light-test.sh"
write_pass_stub "$D/ddd-heavy-test.sh"
write_pass_stub "$D/eee-light-test.sh"
W="$TMP_ROOT/weights.txt"
{
  echo "# fixture weights"
  echo
  echo "bbb-heavy-test.sh 100"
  echo "ddd-heavy-test.sh 90"
  echo "no-such-check-test.sh 5000"   # stale label: must be ignored
} > "$W"
S1="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 VERIFY_ALL_WEIGHTS="$W" bash "$RUNNER" --shard 1/2 --list 2>&1)"
S2="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 VERIFY_ALL_WEIGHTS="$W" bash "$RUNNER" --shard 2/2 --list 2>&1)"
printf '%s\n' "$S1" | grep -qxF 'bbb-heavy-test.sh'; check "heavy-1-in-shard-1" $?
printf '%s\n' "$S2" | grep -qxF 'ddd-heavy-test.sh'; check "heavy-2-in-shard-2" $?
# LPT: heavy1 -> s1 (100), heavy2 -> s2 (90); each weight-1 check then goes to the lighter
# shard, and s2 stays lighter (91..94 < 100) — so s1 holds only heavy1 and s2 the rest,
# in the ORIGINAL run order (gate first, then batteries sorted; heavy2 slots in by name).
[[ "$S1" == "bbb-heavy-test.sh" ]]; check "weights-shard-1-is-only-heavy-1" $?
EXPECT_S2="$(printf '%s\n' gate-a.sh aaa-light-test.sh ccc-light-test.sh ddd-heavy-test.sh eee-light-test.sh)"
[[ "$S2" == "$EXPECT_S2" ]]; check "weights-shard-2-keeps-run-order-gate-first" $?
# the same fixture WITHOUT a weights file (missing path -> everything weighs 1) still partitions
M1="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 VERIFY_ALL_WEIGHTS="$TMP_ROOT/none.txt" bash "$RUNNER" --shard 1/2 --list 2>&1)"
M2="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 VERIFY_ALL_WEIGHTS="$TMP_ROOT/none.txt" bash "$RUNNER" --shard 2/2 --list 2>&1)"
[[ "$(printf '%s\n%s\n' "$M1" "$M2" | grep . | sort | paste -sd, -)" == \
   "$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" --list | sort | paste -sd, -)" ]]
check "missing-weights-file-still-partitions" $?
# a shard RUN executes exactly its own checks, and reports PASS lines with a duration
OUT="$(VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_FIXED=1 VERIFY_ALL_WEIGHTS="$W" bash "$RUNNER" --shard 1/2 2>&1)"; RC=$?
[[ $RC -eq 0 ]]; check "shard-run-exit-0" $?
EXEC="$(printf '%s\n' "$OUT" | awk '/^(PASS|FAIL|SKIP) /{print $2}')"
[[ "$EXEC" == "$S1" ]]; check "shard-run-executes-exactly-its-listed-checks" $?
printf '%s\n' "$OUT" | grep -qE '^PASS  bbb-heavy-test\.sh  \([0-9]+s\)$'; check "pass-line-carries-duration" $?
printf '%s\n' "$OUT" | grep -qF "$(printf '%s' "$S1" | grep -c .) passed, 0 failed"; check "shard-run-summary-counts-own-checks" $?

echo "=== (17) CI MATRIX MATCHES --shard N, AND A REPEATED --shard IS REJECTED ==="
# A matrix trimmed to [1,2,3] while the command still says /4 would leave shard 4's checks
# unrun with every job green — the silent omission this runner exists to prevent.
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
MATRIX="$(grep -E '^[[:space:]]+shard:[[:space:]]*\[' "$CI_YML" | head -n 1 | tr -d ' []' | cut -d: -f2)"
CI_N="$(grep -oE 'verify-all\.sh --shard \$\{\{ matrix\.shard \}\}/[0-9]+' "$CI_YML" | head -n 1 | sed 's#.*/##')"
WANT=""; i=1   # 1,2,..,N built by hand: BSD seq -s appends a trailing separator
while [[ -n "$CI_N" && $i -le $CI_N ]]; do WANT="${WANT:+$WANT,}$i"; i=$((i + 1)); done
[[ -n "$CI_N" && "$MATRIX" == "$WANT" ]]; check "ci-matrix-is-1..N-for-shard-N" $?
bash "$RUNNER" --shard 1/2 --shard 2/2 --list >/dev/null 2>&1; RC=$?
[[ $RC -eq 1 ]]; check "repeated-shard-exits-1" $?

# The must-run cases pin the profile explicitly: under GitHub Actions the caller's own
# GITHUB_ACTIONS=true would otherwise decide it. run_env <dir> <GITHUB_ACTIONS> <VERIFY_ALL_ENV> [args]
run_env() {
  local d="$1" gha="$2" venv="$3"; shift 3
  GITHUB_ACTIONS="$gha" VERIFY_ALL_ENV="$venv" VERIFY_ALL_MUST_RUN='' VERIFY_ALL_SKIP_EVALS='' \
    VERIFY_ALL_TESTS_DIR="$d" VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" "$@" 2>&1
}
must_run() { local d="$1" prof="$2"; shift 2; run_env "$d" "" "$prof" "$@"; }
# a skip-declaring battery stub: exit 2 with `SKIP: <reason>` as its only line
write_skip_stub() { printf '%s\n' '#!/usr/bin/env bash' "echo \"SKIP: $2\"" 'exit 2' > "$1"; }

echo
echo "=== (18) MUST-RUN: a pinned check that skips is a FAIL; an unpinned one stays a SKIP ==="
# The floor in (11) trips only when EVERYTHING skipped, so one battery going quiet (jq gone from
# the host, a skill file moved) left the run green. verify-all-must-run.txt names the checks that
# must END AS PASS. It lives beside the checks, so a fixture dir carries its own list.
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
write_skip_stub "$D/zzz-skip-test.sh" "widget-tool not installed"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 0 ]]; check "no-list-skip-stays-exit-0" $?
printf '%s\n' "$OUT" | grep -qE '^SKIP  zzz-skip-test\.sh  \(widget-tool not installed\)'; check "no-list-skip-stays-SKIP" $?
if printf '%s\n' "$OUT" | grep -qF 'must-run'; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "no-list-prints-nothing-about-must-run" $?
printf '%s\n' 'zzz-skip-test.sh all' > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 1 ]]; check "pinned-skip-exit-1" $?
printf '%s\n' "$OUT" | grep -qE '^FAIL  zzz-skip-test\.sh  \(must-run check skipped: widget-tool not installed\)  \([0-9]+s\)$'
check "pinned-skip-reported-FAIL-with-reason" $?
if printf '%s\n' "$OUT" | grep -qE '^SKIP  zzz-skip-test\.sh'; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "pinned-skip-never-reported-SKIP" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 1 failed, 0 skipped'; check "pinned-skip-tallied-failed-not-skipped" $?
printf '%s\n' "$OUT" | grep -qF '1 must-run check(s) did not run to a PASS under the local profile'; check "pinned-skip-error-line" $?
printf '%s\n' "$OUT" | grep -qF '=== verify-all: must-run profile local — 1 pinned, 1 in this run ==='; check "pinned-run-prints-its-profile" $?
# the pin is selective: a PASS stays a PASS, and an unpinned skip beside it stays a SKIP
printf '%s\n' 'aaa-pass-test.sh all' > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 0 ]]; check "pinned-pass-exit-0" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 0 failed, 1 skipped'; check "pinned-pass-leaves-unpinned-skip-skipped" $?
# a pinned check that FAILS is one ordinary FAIL — not a second must-run finding
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
write_fail_stub "$D/yyy-fail-test.sh"
printf '%s\n' 'yyy-fail-test.sh all' > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 1 ]]; check "pinned-fail-exit-1" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 1 failed, 0 skipped'; check "pinned-fail-counted-once" $?
if printf '%s\n' "$OUT" | grep -qF 'did not run to a PASS'; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "pinned-fail-is-not-a-must-run-finding" $?

echo
echo "=== (19) MUST-RUN: a pinned label that is not in the check set fails, in every shard ==="
# Renamed, moved or deleted: nothing skipped, the check simply is not there. Judged against the
# WHOLE set (before --shard narrows it), so a label that lives in the OTHER shard is not "gone".
D=$(fresh_dir)
write_pass_stub "$D/aaa-test.sh"
write_pass_stub "$D/bbb-test.sh"
printf '%s\n' 'aaa-test.sh all' 'gone-test.sh all' > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 1 ]]; check "missing-pinned-exit-1" $?
printf '%s\n' "$OUT" | grep -qE '^FAIL  gone-test\.sh  \(must-run check not found: .*verify-all-must-run\.txt\)'
check "missing-pinned-reported-FAIL" $?
printf '%s\n' "$OUT" | grep -qF '2 passed, 1 failed, 0 skipped'; check "missing-pinned-tallied-failed" $?
for k in 1 2; do
  OUT="$(must_run "$D" local --shard "$k/2")"; RC=$?
  [[ $RC -eq 1 ]]; check "missing-pinned-fails-in-shard-$k" $?
  printf '%s\n' "$OUT" | grep -qE '^FAIL  gone-test\.sh'; check "missing-pinned-named-in-shard-$k" $?
done
printf '%s\n' 'aaa-test.sh all' 'bbb-test.sh all' > "$D/verify-all-must-run.txt"
for k in 1 2; do
  OUT="$(must_run "$D" local --shard "$k/2")"; RC=$?
  [[ $RC -eq 0 ]]; check "pinned-in-other-shard-is-not-missing-shard-$k" $?
  printf '%s\n' "$OUT" | grep -qF '=== verify-all: must-run profile local — 2 pinned, 1 in this run ==='
  check "shard-$k-counts-only-its-own-pinned" $?
done

echo
echo "=== (20) MUST-RUN PROFILES: local-only pins are excused in CI; the profile is detected and overridable ==="
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
write_skip_stub "$D/zzz-skip-test.sh" "widget-tool not installed"
printf '%s\n' 'zzz-skip-test.sh local' > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 1 ]]; check "local-pin-fails-under-local" $?
OUT="$(must_run "$D" ci)"; RC=$?
[[ $RC -eq 0 ]]; check "local-pin-excused-under-ci-exit-0" $?
printf '%s\n' "$OUT" | grep -qE '^SKIP  zzz-skip-test\.sh'; check "local-pin-excused-under-ci-still-reported-SKIP" $?
printf '%s\n' "$OUT" | grep -qF '=== verify-all: must-run profile ci — 0 pinned, 0 in this run ==='; check "ci-profile-pins-nothing-here" $?
printf '%s\n' 'zzz-skip-test.sh ci' > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 0 ]]; check "ci-pin-excused-under-local" $?
OUT="$(must_run "$D" ci)"; RC=$?
[[ $RC -eq 1 ]]; check "ci-pin-fails-under-ci" $?
printf '%s\n' 'zzz-skip-test.sh all' > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?; [[ $RC -eq 1 ]]; check "all-pin-fails-under-local" $?
OUT="$(must_run "$D" ci)"; RC=$?; [[ $RC -eq 1 ]]; check "all-pin-fails-under-ci" $?
# detection: GITHUB_ACTIONS=true means ci, anything else local, and an explicit VERIFY_ALL_ENV wins
printf '%s\n' 'zzz-skip-test.sh local' > "$D/verify-all-must-run.txt"
OUT="$(run_env "$D" true "")"; RC=$?; [[ $RC -eq 0 ]]; check "github-actions-detected-as-ci" $?
OUT="$(run_env "$D" "" "")"; RC=$?; [[ $RC -eq 1 ]]; check "no-github-actions-detected-as-local" $?
OUT="$(run_env "$D" false "")"; RC=$?; [[ $RC -eq 1 ]]; check "github-actions-false-is-local" $?
OUT="$(run_env "$D" true local)"; RC=$?; [[ $RC -eq 1 ]]; check "explicit-env-beats-github-actions" $?
OUT="$(run_env "$D" "" ci)"; RC=$?; [[ $RC -eq 0 ]]; check "explicit-ci-beats-default-local" $?
OUT="$(run_env "$D" "" staging)"; RC=$?
[[ $RC -eq 1 ]]; check "bad-env-value-exits-1" $?
printf '%s\n' "$OUT" | grep -qF "VERIFY_ALL_ENV must be 'local' or 'ci' (got 'staging')"; check "bad-env-value-message" $?
# the gitleaks check is the same lane, through the binary being absent (see (8) for the PATH scrub)
if PATH="$SCRUBBED" command -v gitleaks >/dev/null 2>&1 \
   || ! PATH="$SCRUBBED" command -v bash >/dev/null 2>&1; then
  echo "  ok   [must-run-gitleaks-unavailable-on-this-host]"; PASS=$((PASS + 1))
else
  D=$(fresh_dir)
  write_pass_stub "$D/aaa-pass-test.sh"
  printf '%s\n' 'gitleaks local' > "$D/verify-all-must-run.txt"
  OUT="$(GITHUB_ACTIONS='' VERIFY_ALL_ENV=local VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_EVALS=1 PATH="$SCRUBBED" bash "$RUNNER" 2>&1)"; RC=$?
  [[ $RC -eq 1 ]]; check "gitleaks-absent-pinned-exit-1" $?
  printf '%s\n' "$OUT" | grep -qE '^FAIL  gitleaks  \(must-run check skipped: gitleaks not installed\)$'; check "gitleaks-absent-pinned-reported-FAIL" $?
  OUT="$(GITHUB_ACTIONS='' VERIFY_ALL_ENV=ci VERIFY_ALL_TESTS_DIR="$D" VERIFY_ALL_SKIP_EVALS=1 PATH="$SCRUBBED" bash "$RUNNER" 2>&1)"; RC=$?
  [[ $RC -eq 0 ]]; check "gitleaks-absent-excused-under-ci-exit-0" $?
  printf '%s\n' "$OUT" | grep -qE '^SKIP  gitleaks  \(gitleaks not installed\)$'; check "gitleaks-absent-excused-under-ci-reported-SKIP" $?
fi

echo
echo "=== (21) MUST-RUN LIST FILE: comments, malformed lines, and a missing list in the real tree ==="
D=$(fresh_dir)
write_pass_stub "$D/aaa-pass-test.sh"
write_skip_stub "$D/zzz-skip-test.sh" "widget-tool not installed"
{
  echo "# a comment"
  echo
  echo "   "
  echo "zzz-skip-test.sh   all   # trailing comment"
  echo "   # indented comment"
} > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
[[ $RC -eq 1 ]]; check "comments-and-blanks-tolerated-pin-still-applies" $?
printf '%s\n' "$OUT" | grep -qE '^FAIL  zzz-skip-test\.sh  \(must-run check skipped'; check "trailing-comment-does-not-hide-the-label" $?
# a malformed line is an error, never a silently dropped pin — in a run and under --list
for badline in 'zzz-skip-test.sh' 'zzz-skip-test.sh sometimes' 'zzz-skip-test.sh all extra' 'zzz-skip-test.sh ALL'; do
  printf '%s\n' '# fine' "$badline" > "$D/verify-all-must-run.txt"
  OUT="$(must_run "$D" local)"; RC=$?
  [[ $RC -eq 1 ]]; check "malformed-[$badline]-exits-1" $?
  printf '%s\n' "$OUT" | grep -qF 'malformed line(s) 2'; check "malformed-[$badline]-names-the-line" $?
  must_run "$D" local --list >/dev/null; [[ $? -eq 1 ]]; check "malformed-[$badline]-fails-list-too" $?
done
# duplicate lines pin the label once: one "pinned", one FAIL line, one failure in the tally
printf '%s\n' 'zzz-skip-test.sh all' 'zzz-skip-test.sh local' 'gone-test.sh all' 'gone-test.sh local' \
  > "$D/verify-all-must-run.txt"
OUT="$(must_run "$D" local)"; RC=$?
printf '%s\n' "$OUT" | grep -qF '=== verify-all: must-run profile local — 2 pinned, 1 in this run ==='; check "duplicate-labels-pinned-once" $?
[[ "$(printf '%s\n' "$OUT" | grep -c -E '^FAIL  (zzz-skip-test|gone-test)\.sh')" -eq 2 ]]; check "duplicate-labels-fail-once-each" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 2 failed, 0 skipped'; check "duplicate-labels-tallied-once-each" $?
# an override that names a file that is not there is an error as well — a typo must not pin nothing
OUT="$(GITHUB_ACTIONS='' VERIFY_ALL_ENV=local VERIFY_ALL_MUST_RUN="$D/no-such-list.txt" VERIFY_ALL_TESTS_DIR="$D" \
  VERIFY_ALL_SKIP_FIXED=1 bash "$RUNNER" 2>&1)"; RC=$?
[[ $RC -eq 1 ]]; check "override-naming-a-missing-file-exits-1" $?
printf '%s\n' "$OUT" | grep -qF 'must-run list missing'; check "override-naming-a-missing-file-message" $?
# in the REAL tree (no VERIFY_ALL_TESTS_DIR) a missing list is an error, not "nothing pinned":
# deleting the file must not switch the guard off. A copy of the runner stands in for the tree.
T=$(fresh_dir)
mkdir -p "$T/core/tests"
cp "$RUNNER" "$T/core/tests/verify-all.sh"
write_pass_stub "$T/core/tests/aaa-pass-test.sh"
OUT="$(env -u VERIFY_ALL_TESTS_DIR -u VERIFY_ALL_MUST_RUN GITHUB_ACTIONS= VERIFY_ALL_ENV=local VERIFY_ALL_SKIP_FIXED=1 \
  bash "$T/core/tests/verify-all.sh" 2>&1)"; RC=$?
[[ $RC -eq 1 ]]; check "real-tree-missing-list-exits-1" $?
printf '%s\n' "$OUT" | grep -qF 'must-run list missing'; check "real-tree-missing-list-message" $?
if printf '%s\n' "$OUT" | grep -qE '^(PASS|FAIL|SKIP) '; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "real-tree-missing-list-runs-nothing" $?
printf '%s\n' 'aaa-pass-test.sh all' > "$T/core/tests/verify-all-must-run.txt"
OUT="$(env -u VERIFY_ALL_TESTS_DIR -u VERIFY_ALL_MUST_RUN GITHUB_ACTIONS= VERIFY_ALL_ENV=local VERIFY_ALL_SKIP_FIXED=1 \
  bash "$T/core/tests/verify-all.sh" 2>&1)"; RC=$?
[[ $RC -eq 0 ]]; check "real-tree-restored-list-passes" $?
printf '%s\n' "$OUT" | grep -qF '1 passed, 0 failed, 0 skipped'; check "real-tree-restored-list-tally" $?

echo
echo "=== (22) THE SHIPPED MUST-RUN LIST matches the tree: no stale label, every skip lane pinned, CI excuses only gitleaks ==="
LIST_FILE="$REAL_TESTS_DIR/verify-all-must-run.txt"
[[ -s "$LIST_FILE" ]]; check "shipped-list-exists" $?
SHIPPED="$(awk '{ sub(/[ \t]*#.*/, "") } NF { print $1 " " $2 }' "$LIST_FILE")"
# the full label set, whatever test seams the caller has exported (they would drop gitleaks)
FULL_LIST="$(env -u VERIFY_ALL_SKIP_FIXED -u VERIFY_ALL_SKIP_EVALS -u VERIFY_ALL_TESTS_DIR -u VERIFY_ALL_MUST_RUN \
  bash "$RUNNER" --list 2>&1)"
stale=0
while read -r lab _; do
  [[ -n "$lab" ]] || continue
  if ! printf '%s\n' "$FULL_LIST" | grep -qxF "$lab"; then echo "    STALE (not in --list): $lab"; stale=$((stale + 1)); fi
done <<EOF
$SHIPPED
EOF
[[ $stale -eq 0 ]]; check "shipped-list-has-no-stale-label" $?
# skip_declared_with_exit_2 <file> — 0 if the file prints `SKIP…` and exits 2 on that line or the next:
# a battery with a declared skip lane. The sibling of (13)'s exit-0 tripwire, same source-text heuristic.
skip_declared_with_exit_2() {
  grep -A1 -E "(echo|printf)[[:space:]]+(-e[[:space:]]+)?('%s.n'|\"%s.n\")?[[:space:]]*[\"']?SKIP([[:space:]]|:|\\\\n|\"|')" "$1" 2>/dev/null \
    | grep -qE 'exit[[:space:]]+2'
}
D=$(fresh_dir)
printf '%s\n' '#!/usr/bin/env bash' 'echo "SKIP: widget not installed"' 'exit 2' > "$D/next-line.sh"
skip_declared_with_exit_2 "$D/next-line.sh"; check "ratchet-detects-skip-then-exit-2" $?
printf '%s\n' '#!/usr/bin/env bash' 'command -v jq || { echo "SKIP: jq"; exit 2; }' 'run' > "$D/same-line.sh"
skip_declared_with_exit_2 "$D/same-line.sh"; check "ratchet-detects-same-line-guard" $?
printf '%s\n' '#!/usr/bin/env bash' 'echo "=== (n) missing log -> LOUD SKIP, exit 2 ==="' 'run' 'exit 2' > "$D/prose.sh"
if skip_declared_with_exit_2 "$D/prose.sh"; then fp=1; else fp=0; fi
[[ $fp -eq 0 ]]; check "ratchet-no-false-positive-on-prose" $?
unpinned=""
for f in "$REAL_TESTS_DIR"/*.sh; do
  base="$(basename "$f")"
  case "$base" in verify-all.sh|verify-all-test.sh) continue ;; esac
  if skip_declared_with_exit_2 "$f"; then
    # `all`, except the one battery that needs the binary CI does not have
    want=all; [[ "$base" == "gitleaks-allowlist-test.sh" ]] && want=local
    have="$(printf '%s\n' "$SHIPPED" | awk -v b="$base" '$1 == b { print $2 }' | paste -sd, -)"
    [[ "$have" == "$want" ]] || unpinned="$unpinned $base(${have:-not listed})"
  fi
done
[[ -z "$unpinned" ]]; check "every-skip-lane-battery-is-pinned-in-the-right-profile" $?
[[ -n "$unpinned" ]] && echo "    skip lanes pinned wrongly:$unpinned — core/tests/verify-all-must-run.txt (all; local for the gitleaks allowlist battery)"
# the environment split the list exists for: CI's verify job has no gitleaks (its secret-scan job
# enforces it), a developer machine does and may not skip it
CI_PINNED="$(printf '%s\n' "$SHIPPED" | awk '$2 == "all" || $2 == "ci" { print $1 }')"
LOCAL_PINNED="$(printf '%s\n' "$SHIPPED" | awk '$2 == "all" || $2 == "local" { print $1 }')"
if printf '%s\n' "$CI_PINNED" | grep -q '^gitleaks'; then bad=1; else bad=0; fi
[[ $bad -eq 0 ]]; check "ci-profile-does-not-pin-gitleaks" $?
printf '%s\n' "$LOCAL_PINNED" | grep -qxF 'gitleaks'; check "local-profile-pins-the-gitleaks-scan" $?
printf '%s\n' "$LOCAL_PINNED" | grep -qxF 'gitleaks-allowlist-test.sh'; check "local-profile-pins-the-allowlist-battery" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
