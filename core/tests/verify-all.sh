#!/usr/bin/env bash
# verify-all.sh — P1-2: the single-command local verification runner.
#
# Fulfills the README "Verification" one-command promise: it bundles the COMPLETE
# check set and runs it in one pass, reporting PASS / FAIL / SKIP per check and a
# final tally. Exit 1 iff any check failed.
#
# The check set (nothing silently omitted):
#   1. DYNAMIC core/tests discovery — every core/tests/*.sh except this runner and
#      its own test (verify-all.sh, verify-all-test.sh). This auto-includes the
#      gates (adapter-parity / doc-reality / sanitize-audit / supply-chain-scan)
#      AND every *-test.sh battery, AND anything added later — the anti-rot
#      property: a new gate/battery is picked up with no edit here. Gates
#      (non-*-test.sh) run first, then batteries, each group sorted.
#   2. evals:deterministic — evals/run-evals.py (labeled-verdict grader, Pass^k).
#   3. evals:semantic       — the same runner over the semantic-judge dataset with
#      the reference judge as verifier.
#   4. gitleaks             — secret scan when the binary is present; otherwise a
#      LOUD SKIP (a silently-skipped security scan reported as pass is exactly the
#      false-green this repo guards against — a SKIP is not a pass, and is printed).
#
# Design: NOT `set -e`. Every check runs even if an earlier one fails (run all,
# report all). Each check runs in a SUBSHELL with combined output captured to a
# temp file, so a sub-script's own set -e / trap / exit cannot kill or corrupt
# this runner. REPO_ROOT is derived from BASH_SOURCE so it works from any cwd.
#
# Flags:
#   --list   print each check's label (one per line, run order) and exit 0
#            WITHOUT running anything. gitleaks is listed (it is a declared check).
#
# Internal test seams:
#   VERIFY_ALL_TESTS_DIR   override the core/tests glob source
#                          (default $REPO_ROOT/core/tests).
#   VERIFY_ALL_SKIP_FIXED=1  omit the evals + gitleaks checks from BOTH --list and
#                          execution, so hermetic logic tests run fast, offline,
#                          and gitleaks-independent.
#   VERIFY_ALL_SKIP_EVALS=1  omit only the two (slow) evals checks, keeping the
#                          gitleaks check listed — lets a test exercise the
#                          gitleaks present/absent branch offline without paying
#                          for the evals subprocesses.
#
# Usage:
#   bash core/tests/verify-all.sh          # run the full suite
#   bash core/tests/verify-all.sh --list   # print the check labels only
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${VERIFY_ALL_TESTS_DIR:-$REPO_ROOT/core/tests}"

LIST_ONLY=0
if [[ "${1:-}" == "--list" ]]; then
  LIST_ONLY=1
fi

# Parallel arrays: LABELS[i] is the display label, CMDS[i] the eval-able command.
# The gitleaks check carries the sentinel @gitleaks@ so the runner can apply its
# present-or-SKIP logic at run time (it is still listed unconditionally).
LABELS=()
CMDS=()
add_check() { LABELS+=("$1"); CMDS+=("$2"); }

# --- 1. dynamic core/tests discovery (gates first, then batteries) ---
# bash glob expansion is lexically sorted, so each group keeps sorted order.
shopt -s nullglob
gates=()
batteries=()
for f in "$TESTS_DIR"/*.sh; do
  base="$(basename "$f")"
  case "$base" in
    verify-all.sh|verify-all-test.sh) continue ;;  # skip self + self-test (no recursion)
  esac
  case "$base" in
    *-test.sh) batteries+=("$f") ;;
    *)         gates+=("$f") ;;
  esac
done
shopt -u nullglob

# ${arr[@]+...} guard: under `set -u`, expanding an empty array is an error on
# bash 3.2 (macOS default) — the guard yields nothing when the group is empty.
for f in ${gates[@]+"${gates[@]}"}; do
  add_check "$(basename "$f")" "bash $(printf '%q' "$f")"
done
for f in ${batteries[@]+"${batteries[@]}"}; do
  add_check "$(basename "$f")" "bash $(printf '%q' "$f")"
done

# --- 2-4. fixed checks (evals + gitleaks), unless a seam suppresses them ---
# SKIP_FIXED omits both groups; SKIP_EVALS omits only the two evals checks and
# keeps gitleaks listed (so the gitleaks present/absent branch stays testable).
if [[ "${VERIFY_ALL_SKIP_FIXED:-}" != "1" ]]; then
  if [[ "${VERIFY_ALL_SKIP_EVALS:-}" != "1" ]]; then
    add_check "evals:deterministic" \
      "python3 $(printf '%q' "$REPO_ROOT/evals/run-evals.py")"
    add_check "evals:semantic" \
      "python3 $(printf '%q' "$REPO_ROOT/evals/run-evals.py") \
--dataset $(printf '%q' "$REPO_ROOT/evals/datasets/semantic-judge.jsonl") \
--baseline $(printf '%q' "$REPO_ROOT/evals/baseline-semantic.json") \
--verifier $(printf '%q' "$REPO_ROOT/evals/judges/reference-judge.py")"
  fi
  add_check "gitleaks" "@gitleaks@"
fi

# --- --list: print labels in run order, run nothing ---
# ${arr[@]+...} guard: same bash-3.2 empty-array-under-set-u case as the discovery
# loops above — an empty check set must print nothing and exit 0, not abort.
if [[ $LIST_ONLY -eq 1 ]]; then
  for l in ${LABELS[@]+"${LABELS[@]}"}; do
    printf '%s\n' "$l"
  done
  exit 0
fi

# --- run every check, report each, tally ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUTFILE="$WORK/check.out"

passed=0
failed=0
skipped=0

i=0
n=${#LABELS[@]}
while [[ $i -lt $n ]]; do
  label="${LABELS[$i]}"
  cmd="${CMDS[$i]}"
  i=$((i + 1))

  # gitleaks: present -> run; absent -> loud SKIP (not a failure, not silent).
  if [[ "$cmd" == "@gitleaks@" ]]; then
    if command -v gitleaks >/dev/null 2>&1; then
      cmd="gitleaks detect --no-git --source $(printf '%q' "$REPO_ROOT") --config $(printf '%q' "$REPO_ROOT/gitleaks.toml")"
    else
      printf 'SKIP  %s  (%s)\n' "$label" "gitleaks not installed"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  start=$(date +%s)
  # Subshell isolation: the sub-script's set -e / traps / exit stay contained;
  # we only observe its exit status and captured output.
  ( eval "$cmd" ) >"$OUTFILE" 2>&1
  rc=$?
  end=$(date +%s)
  dur=$((end - start))

  if [[ $rc -eq 0 ]]; then
    printf 'PASS  %s  (%ss)\n' "$label" "$dur"
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "$label"
    tail -n 15 "$OUTFILE" | sed 's/^/    /'
    failed=$((failed + 1))
  fi
done

printf '=== verify-all: %d passed, %d failed, %d skipped ===\n' "$passed" "$failed" "$skipped"

# Floor guard: `[[ $failed -eq 0 ]]` is vacuously true when NOTHING ran, which
# would report success on an empty/broken discovery (dir moved, glob returns
# nothing) — the canonical "empty suite reports green" false-signal. Refuse it.
if [[ $((passed + failed + skipped)) -eq 0 ]]; then
  printf 'ERROR: verify-all discovered and ran zero checks — refusing to report success.\n' >&2
  exit 1
fi
[[ $failed -eq 0 ]]
