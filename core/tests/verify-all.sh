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
# SKIP contract for DISCOVERED checks: a check declares itself INAPPLICABLE (an
# optional binary it needs is absent) by exiting 2 with `SKIP <reason>` as its
# ONLY non-empty line of output. It is then tallied as skipped and printed as
# `SKIP  <label>  (<reason>)` — never as a pass. Without this lane a battery
# could only signal "cannot run" by exiting 0, which this runner would report as
# PASS with its own SKIP text discarded (the runner only echoes a check's output
# on FAIL) — a false green in exactly the place it is least visible. The
# only-line requirement is what keeps the lane from becoming a second false
# green: a battery that skips one SUB-PROBE, runs on, and then genuinely breaks
# must stay a FAIL. Partial skips belong in a battery's own tally, not here.
# Exits 0 and 1 keep their meanings (pass / fail).
#
# Design: NOT `set -e`. Every check runs even if an earlier one fails (run all,
# report all). Each check runs in a SUBSHELL with combined output captured to a
# temp file, so a sub-script's own set -e / trap / exit cannot kill or corrupt
# this runner. REPO_ROOT is derived from BASH_SOURCE so it works from any cwd.
#
# Flags:
#   --list   print each check's label (one per line, run order) and exit 0
#            WITHOUT running anything. gitleaks is listed (it is a declared check).
#   --shard K/N   run (or, with --list, print) only shard K of N (1 <= K <= N, integers).
#            Used by CI to fan the ~30 min serial run out over N parallel jobs. Assignment
#            is deterministic LPT (longest-processing-time-first) over the measured
#            per-check seconds in core/tests/verify-all-weights.txt (`<label> <seconds>`,
#            `#` comments; a label with no entry weighs 1): checks are sorted by weight
#            descending (ties keep run order) and each goes to the currently lightest
#            shard (ties: lowest shard number). Inside a shard the original run order
#            (gates first) is kept. The union of shards 1..N is exactly the full check
#            set, with no overlap. Flags combine in any order. No flag = the full run,
#            unchanged.
#
# Internal test seams:
#   VERIFY_ALL_TESTS_DIR   override the core/tests glob source
#                          (default $REPO_ROOT/core/tests).
#   VERIFY_ALL_SKIP_FIXED=1  omit the evals + gitleaks checks from BOTH --list and
#                          execution, so hermetic logic tests run fast, offline,
#                          and gitleaks-independent.
#   VERIFY_ALL_WEIGHTS     override the --shard weights file
#                          (default $REPO_ROOT/core/tests/verify-all-weights.txt;
#                          a missing file means every check weighs 1).
#   VERIFY_ALL_SKIP_EVALS=1  omit only the two (slow) evals checks, keeping the
#                          gitleaks check listed — lets a test exercise the
#                          gitleaks present/absent branch offline without paying
#                          for the evals subprocesses.
#
# Usage:
#   bash core/tests/verify-all.sh          # run the full suite
#   bash core/tests/verify-all.sh --list   # print the check labels only
#   bash core/tests/verify-all.sh --shard 2/4          # run shard 2 of 4
#   bash core/tests/verify-all.sh --shard 2/4 --list   # print shard 2's labels only
set -u

# W1-4: tag every record this run's batteries produce in security-violations.jsonl
# / model-routing.jsonl as origin="test", so a test-battery-produced block stays
# distinguishable from a real-session block downstream (telemetry-digest.sh).
export AGENT_LOG_ORIGIN=test

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${VERIFY_ALL_TESTS_DIR:-$REPO_ROOT/core/tests}"

WEIGHTS_FILE="${VERIFY_ALL_WEIGHTS:-$REPO_ROOT/core/tests/verify-all-weights.txt}"

die_usage() { printf 'verify-all: %s\n' "$1" >&2; exit 1; }

# parse_shard <K/N> — set SHARD_K / SHARD_N, or exit 1 on anything but integers 1<=K<=N.
# 10# forces base 10 so "08/10" is not an octal error; the 6-digit cap keeps the
# arithmetic well inside bash's range.
parse_shard() {
  local spec="$1"
  if ! [[ "$spec" =~ ^([0-9]{1,6})/([0-9]{1,6})$ ]]; then
    die_usage "--shard expects K/N with integers 1 <= K <= N (got '$spec')"
  fi
  SHARD_K=$((10#${BASH_REMATCH[1]}))
  SHARD_N=$((10#${BASH_REMATCH[2]}))
  if [[ $SHARD_N -lt 1 || $SHARD_K -lt 1 || $SHARD_K -gt $SHARD_N ]]; then
    die_usage "--shard expects K/N with integers 1 <= K <= N (got '$spec')"
  fi
}

LIST_ONLY=0
SHARD_K=0
SHARD_N=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_ONLY=1; shift ;;
    --shard|--shard=*)
      [[ $SHARD_N -eq 0 ]] || die_usage "--shard given more than once"
      if [[ "$1" == "--shard" ]]; then
        [[ $# -ge 2 ]] || die_usage "--shard requires a K/N argument"
        parse_shard "$2"; shift 2
      else
        parse_shard "${1#--shard=}"; shift
      fi ;;
    *) die_usage "unknown argument '$1' (usage: verify-all.sh [--list] [--shard K/N])" ;;
  esac
done

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
    grade.sh) continue ;;  # loop-time grader, NOT a gate: it re-runs the batteries
                           # itself (would recurse + cost minutes). grade-test.sh
                           # (a *-test.sh battery) still runs here.
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

# --- --shard K/N: keep only this shard's checks (deterministic LPT, see header) ---
# awk does the bin-packing so no associative array is needed in bash 3.2. Input is
# the label list in run order; output is `T <est-seconds>` then the 0-based indices
# that belong to shard K (ascending = original run order).
SHARD_EST=""
if [[ $SHARD_N -gt 0 ]]; then
  SEL="$(
    { for l in ${LABELS[@]+"${LABELS[@]}"}; do printf '%s\n' "$l"; done; } \
    | awk -v N="$SHARD_N" -v K="$SHARD_K" -v wfile="$WEIGHTS_FILE" '
        BEGIN {
          while ((getline line < wfile) > 0) {
            if (line ~ /^[ \t]*(#|$)/) continue
            m = split(line, f, /[ \t]+/)
            if (m >= 2 && f[2] ~ /^[0-9]+(\.[0-9]+)?$/) w[f[1]] = f[2] + 0
          }
          close(wfile)
        }
        { lab[n++] = $0; wt[n - 1] = ($0 in w) ? w[$0] : 1 }
        END {
          # stable selection sort by weight desc (ties keep run order)
          for (i = 0; i < n; i++) ord[i] = i
          for (i = 0; i < n; i++) {
            b = i
            for (j = i + 1; j < n; j++) if (wt[ord[j]] > wt[ord[b]]) b = j
            t = ord[b]
            # shift (not swap) to keep the remaining order stable
            for (j = b; j > i; j--) ord[j] = ord[j - 1]
            ord[i] = t
          }
          for (s = 1; s <= N; s++) load[s] = 0
          for (i = 0; i < n; i++) {
            c = 1
            for (s = 2; s <= N; s++) if (load[s] < load[c]) c = s
            asg[ord[i]] = c
            load[c] += wt[ord[i]]
          }
          printf "T %s\n", load[K]
          for (i = 0; i < n; i++) if (asg[i] == K) print i
        }'
  )"
  SHARD_EST="$(printf '%s\n' "$SEL" | sed -n 's/^T //p')"
  SHARDED_LABELS=()
  SHARDED_CMDS=()
  for idx in $(printf '%s\n' "$SEL" | grep -E '^[0-9]+$' || true); do
    SHARDED_LABELS+=("${LABELS[$idx]}")
    SHARDED_CMDS+=("${CMDS[$idx]}")
  done
  LABELS=("${SHARDED_LABELS[@]+"${SHARDED_LABELS[@]}"}")
  CMDS=("${SHARDED_CMDS[@]+"${SHARDED_CMDS[@]}"}")
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
# checks that run call-worker.sh must not append to the real ~/.agent logs; a caller-set
# seam wins so a test can still point them elsewhere
export AGENT_LOGS_DIR="${AGENT_LOGS_DIR:-$WORK/agent-logs}"
export AGENT_WORKERS_DIR="${AGENT_WORKERS_DIR:-$WORK/agent-workers}"
# X-5: gate hooks write security-violations.jsonl under <repo>/.agent/logs; redirect the
# whole run so the live sink row count is unchanged (origin=test above stays as 2nd line).
export AGENT_GATE_SINK_DIR="${AGENT_GATE_SINK_DIR:-$WORK/gate-sink}"
# AG9: marker = the sink path this runner owns; doctor/digest treat a sink dir WITHOUT a
# matching marker as live-config pollution (a leaked settings.json env value never matches).
export AGENT_GATE_SINK_TEST_RUN="$AGENT_GATE_SINK_DIR"
OUTFILE="$WORK/check.out"

if [[ $SHARD_N -gt 0 ]]; then
  printf '=== verify-all: shard %d/%d — %d checks, ~%ss estimated ===\n' \
    "$SHARD_K" "$SHARD_N" "${#LABELS[@]}" "${SHARD_EST:-0}"
fi

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

  # A check is SKIPPED only if it exits 2 *and* declares the skip on its FIRST
  # non-empty line of output. All three halves matter:
  #   - exit 2 alone is not a skip signal, because bash exits 2 on a SYNTAX
  #     ERROR — a truncated or merge-conflicted battery would be silently
  #     downgraded from FAIL to SKIP, and `core/tests/` is only `ask`-guarded,
  #     so one malformed edit from a loop agent reaches it. argparse also exits
  #     2 on a bad flag, a real failure of the evals lanes.
  #   - a SKIP line ANYWHERE was not enough either: a battery that skips one
  #     SUB-PROBE ("SKIP: sqlite3 missing, skipping the breaker checks"), runs
  #     on, and then genuinely breaks with rc 2 was reported as an inapplicable
  #     skip — a false green needing no adversary, just a partial-skip battery
  #     plus a bad edit. Anchoring to the FIRST line does not fix it either:
  #     that battery declares its sub-probe skip first and runs on afterwards.
  # So the declaration must be the ONLY non-empty line of output. That is what
  # an inapplicable check actually looks like: it detects the missing dependency
  # up front, says so, and exits without doing anything else. Both current users
  # (gitleaks-allowlist-test.sh, loop-run-test.sh) are exactly this shape. Any
  # other output means the battery RAN, so its rc 2 is a failure, not an
  # inapplicability, and it falls through to FAIL where the tail explains it.
  # A battery that must skip only part of itself reports that in its own tally
  # and exits 0 or 1; it does not get to claim the whole check was inapplicable.
  declared_skip=0
  first_line=""
  if [[ $rc -eq 2 ]]; then
    nonempty_count="$(grep -cv '^[[:space:]]*$' "$OUTFILE" 2>/dev/null || true)"
    first_line="$(grep -m1 -v '^[[:space:]]*$' "$OUTFILE" 2>/dev/null)"
    if [[ "${nonempty_count:-0}" -eq 1 && "$first_line" =~ ^SKIP([[:space:]]|:|$) ]]; then
      declared_skip=1
    fi
  fi

  if [[ $declared_skip -eq 1 ]]; then
    # Exit 2 + a SKIP line = the check declared itself INAPPLICABLE (an optional
    # binary it needs is absent). Counted as skipped and printed loudly, never as
    # a pass: a discovered battery that cannot run must not be indistinguishable
    # from one that ran and passed. The sentinel is the same one
    # core/infra/gitleaks-fire-test.sh and skills/wrap already use, and it is
    # what lets a battery guarded by an optional tool live under core/tests/
    # (inside the guarded surface) instead of being hidden outside discovery.
    reason="$(printf '%s' "$first_line" | sed -E 's/^SKIP[[:space:]]*[:—-]*[[:space:]]*//')"
    printf 'SKIP  %s  (%s)  (%ss)\n' "$label" "${reason:-check declared itself inapplicable}" "$dur"
    skipped=$((skipped + 1))
  elif [[ $rc -eq 0 ]]; then
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
# Second floor, same principle one level up: a run where NOTHING actually
# executed — every check skipped — is the same false-signal wearing a different
# tally. It became reachable once discovered checks could skip themselves (a
# host missing several optional binaries, or a sabotaged environment), and
# consumers read a zero exit as "the harness passes its own gates".
if [[ $passed -eq 0 && $skipped -gt 0 ]]; then
  printf 'ERROR: verify-all skipped every check (%d skipped, 0 passed) — nothing was verified, refusing to report success.\n' "$skipped" >&2
  exit 1
fi
[[ $failed -eq 0 ]]
