#!/usr/bin/env bash
# grade.sh — P2-2 + L-1 (impl): the autonomous improvement-loop grader.
#
# The loop (§5, docs/harness-improvement-plan.md) grades a candidate harness change
# by REPLAYING the repo's own regression batteries, grouped by NAMED FAILURE MODE.
# This is the L-1 amendment to the original single-scalar `harness_score`: instead of
# one opaque number, the grader emits a per-mode verdict checklist over
# `evals/failure-modes.yaml`, then a rollup scalar. Naming the modes makes the grader
# adversarial the way a human review is — a candidate cannot make the number go up
# while quietly re-opening a known hole, because each hole has a battery that goes red.
#
# Output contract (consumed by the loop, §5.2 step 5 — `grep '^harness_score:'`):
#   - Zero or more `mode:<id> PASS|FAIL|N/A — <reason>` lines (GATE-pass path only).
#   - EXACTLY ONE final `harness_score: X.Y` line on every GRADING invocation (so an
#     empty grep is always a genuine crash, never a normal outcome — the §5.1 status
#     enum stays intact and infra failure is never silently a graded label). The
#     informational `--list-modes` invocation is NOT a grading path and emits no score.
#
# Scoring (GATE-pass path):
#   harness_score = (#PASS modes) − 0.5 × (#OER modes)
#   where OER = "over/erroneous refutation" = a mode whose guard the grader could
#   NOT trust (unmapped id, missing battery, infra error). A clean FAIL (guard red =
#   a real regression) is not penalized twice — it simply does not earn its PASS.
#   N/A modes (process discipline with no code guard) are reported and excluded.
#
# Fail-closed (the operator-chosen baseline verdict — B4 gate): any path where the
# grader cannot reach a trustworthy verdict emits `harness_score: 0` = discard:
#   - the rubric does not parse / has zero modes
#   - a GATE check fails (sanitize-audit / adapter-parity / hook-config-test /
#     post-commit-autosync / gitleaks) — the regression floor
#   - a TARGET-boundary violation (candidate diff touched a non-TARGET file, §5.1
#     pillar ③ — the grader physically refuses to score off-target edits)
# This mirrors the campaign's `infra-as-verdict` lesson (E-1 batch-3): a broken or
# absent backend must fail closed, never emit a trusted score.
#
# Baseline: on a clean tree (all batteries green) this emits `harness_score: 11.0`
# (11 code-guarded modes PASS; `review-false-clean` is N/A). This SUPERSEDES the
# pre-L-1 P2-2 target of 8.0 (which came from the retired single-scalar benchmark).
#
# NOT a CI gate — this is a loop-time tool (it re-runs batteries; run = minutes,
# §5.3). Its own battery `core/tests/grade-test.sh` drives it hermetically via the
# seams below. The reviewer-benchmark replay (docs/benchmark/sample-diff.ts, a
# model-backed richer signal) is intentionally OUT OF SCOPE for v1 and left to the
# B6 pilot — v1 is the deterministic regression grader, honestly bounded.
#
# Flags:
#   --target <regex>   restrict the candidate to files whose FULL path matches <regex>
#                      (anchored, `grep -xE` — e.g. 'agents/.*'); any off-target
#                      changed file => harness_score 0. Requires a clean working tree
#                      and --base. An unknown flag also fails closed.
#   --base <ref>       the mission's start ref; the boundary diff is <ref>..HEAD.
#                      REQUIRED when --target is given (no silent HEAD~1 default that
#                      would miss earlier commits of a multi-commit candidate).
#   --list-modes       print the rubric's mode ids (run order) and exit 0 (no score)
#
# Test seams (hermetic, offline):
#   GRADE_TESTS_DIR       battery source dir (default $REPO_ROOT/core/tests)
#   GRADE_RUBRIC          failure-modes.yaml path (default $REPO_ROOT/evals/failure-modes.yaml)
#   GRADE_SKIP_GITLEAKS=1 omit the gitleaks GATE check (offline logic tests)
#
# Usage:
#   bash core/tests/grade.sh                      # grade the working tree
#   bash core/tests/grade.sh --target '^agents/'  # loop mission: reviewer prompts only
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${GRADE_TESTS_DIR:-$REPO_ROOT/core/tests}"
RUBRIC="${GRADE_RUBRIC:-$REPO_ROOT/evals/failure-modes.yaml}"

# emit_score_and_exit <score> — print the mandatory final line and exit 0. Every
# GRADING path funnels through here so `harness_score:` is ALWAYS the last line.
# (Defined before arg parsing so an early fail-closed exit can use it.)
emit_score_and_exit() {
  printf 'harness_score: %s\n' "$1"
  exit 0
}

TARGET_RE=""
BASE_REF=""
TARGET_SET=0
LIST_MODES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_RE="${2:-}"; TARGET_SET=1; shift 2 ;;
    --base)   BASE_REF="${2:-}"; shift 2 ;;
    --list-modes) LIST_MODES=1; shift ;;
    # An unknown flag (e.g. a typo like --taget) must NOT silently disable a check
    # and proceed — fail closed rather than grade with a misparsed boundary.
    *) printf 'grade.sh: unknown argument: %s (fail-closed)\n' "$1" >&2; emit_score_and_exit 0 ;;
  esac
done

# --- mode -> guard battery map (single source of truth for the grader). Each mode
# in evals/failure-modes.yaml maps to the battery that encodes its caught_in defect;
# the battery going red = the candidate re-opened that hole. Kept in the grader (not
# the rubric yaml) so the rubric stays a pure description; grade-test.sh asserts this
# map covers every rubric mode and that every named battery file exists (drift gate).
# @process@ = a discipline mode with no code guard (reported N/A, excluded from score).
guard_for() {
  case "$1" in
    silent-drop)          echo "completion-verify-test.sh" ;;
    vacuous-green)        echo "verify-all-test.sh" ;;
    vacuous-parity)       echo "adapter-parity.sh" ;;
    glob-scope-miss)      echo "supply-chain-scan-test.sh" ;;
    bypass-flag)          echo "pre-tool-guard-test.sh" ;;
    unanchored-skip)      echo "spec-gate-test.sh" ;;
    infra-as-verdict)     echo "llm-judge-test.sh" ;;
    lexical-containment)  echo "reference-judge-test.sh" ;;
    injection-breakout)   echo "pre-tool-guard-test.sh" ;;
    loose-coercion)       echo "evals-test.sh" ;;
    stale-ssot)           echo "doc-reality.sh" ;;
    review-false-clean)   echo "@process@" ;;
    *)                    echo "@unknown@" ;;
  esac
}

# --- load rubric mode ids (fail closed if the rubric is unparseable or empty) ---
MODE_IDS="$(RUBRIC="$RUBRIC" python3 - <<'PY' 2>/dev/null || true
import os, sys
try:
    import yaml
except Exception:
    sys.exit(3)
try:
    with open(os.environ["RUBRIC"]) as fh:
        doc = yaml.safe_load(fh)
    modes = doc.get("failure_modes") or []
    raw = [str(m["id"]).strip() for m in modes if isinstance(m, dict) and m.get("id")]
    # de-duplicate (preserve first-seen order): a repeated id must not be graded —
    # and PASS-counted — twice, which would inflate the score.
    seen = set()
    ids = [i for i in raw if not (i in seen or seen.add(i))]
except Exception:
    sys.exit(4)
if not ids:
    sys.exit(5)
print("\n".join(ids))
PY
)"

if [[ -z "$MODE_IDS" ]]; then
  printf 'GRADE: FAIL — rubric %s did not parse to >=1 mode (fail-closed)\n' "$RUBRIC" >&2
  emit_score_and_exit 0
fi

if [[ $LIST_MODES -eq 1 ]]; then
  printf '%s\n' "$MODE_IDS"
  exit 0
fi

# --- run one battery quietly; return its exit status ---
run_battery() {
  local script="$TESTS_DIR/$1"
  [[ -f "$script" ]] || return 127
  ( bash "$script" ) >/dev/null 2>&1
}

# --- GATE phase: the regression floor. Any failure => harness_score 0 (discard). ---
# GATE set per §5.1: sanitize-audit, adapter-parity, hook-config-test,
# post-commit-autosync, gitleaks. gitleaks is present-or-SKIP (a missing scanner is
# not a pass, but its absence must not silently fail the loop offline).
GATE_BATTERIES=(sanitize-audit.sh adapter-parity.sh hook-config-test.sh post-commit-autosync-test.sh)
for g in "${GATE_BATTERIES[@]}"; do
  if ! run_battery "$g"; then
    printf 'GATE: FAIL — %s (regression floor breached)\n' "$g" >&2
    emit_score_and_exit 0
  fi
done
if [[ "${GRADE_SKIP_GITLEAKS:-}" != "1" ]]; then
  if command -v gitleaks >/dev/null 2>&1; then
    if ! ( gitleaks detect --no-git --source "$REPO_ROOT" --config "$REPO_ROOT/gitleaks.toml" ) >/dev/null 2>&1; then
      printf 'GATE: FAIL — gitleaks (secret detected)\n' >&2
      emit_score_and_exit 0
    fi
  else
    # Surface the SKIP on STDOUT too (not only stderr): the loop consumes run.log,
    # and a silently-absent secret scan reported alongside a clean score is exactly
    # the vacuous-green/infra-as-verdict trap. A SKIP is visible and is not a pass.
    printf 'gitleaks: SKIP (not installed) — regression floor has a gap this run\n'
    printf 'GATE: SKIP — gitleaks not installed (not a pass)\n' >&2
  fi
fi

# --- TARGET-boundary check (§5.1 pillar ③): refuse to score off-target diffs. ---
# The batteries execute the WORKING TREE, so the boundary check must cover exactly
# the bytes that run. We enforce: (1) --base is explicit (HEAD~1 misses earlier
# commits of a multi-commit candidate); (2) the tree is clean (an uncommitted tamper
# cannot hide where a committed-range diff can't see it); (3) git failure fails CLOSED
# (a boundary check that cannot run must not silently pass); (4) full-path anchored
# match (so 'core/tests/agents-helper.sh' is not mistaken for on-target 'agents/.*').
if [[ $TARGET_SET -eq 1 ]]; then
  if [[ -z "$BASE_REF" ]]; then
    printf 'TARGET-BOUNDARY — --target requires --base <mission-start-ref> (fail-closed)\n' >&2
    emit_score_and_exit 0
  fi
  if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
    printf 'TARGET-BOUNDARY — working tree is dirty; commit the candidate before grading (fail-closed)\n' >&2
    emit_score_and_exit 0
  fi
  changed="$(git -C "$REPO_ROOT" diff --name-only "$BASE_REF" HEAD 2>/dev/null)"
  if [[ $? -ne 0 ]]; then
    printf 'TARGET-BOUNDARY — git diff %s..HEAD failed; cannot verify boundary (fail-closed)\n' "$BASE_REF" >&2
    emit_score_and_exit 0
  fi
  offtarget=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! printf '%s' "$f" | grep -qxE "$TARGET_RE"; then
      offtarget="$offtarget $f"
    fi
  done <<< "$changed"
  if [[ -n "$offtarget" ]]; then
    printf 'TARGET-VIOLATION — off-target file(s) changed:%s\n' "$offtarget" >&2
    emit_score_and_exit 0
  fi
fi

# --- failure-mode checklist ---
pass=0
oer=0   # over/erroneous refutations (grader could not trust the guard) => -0.5 each
while IFS= read -r mode; do
  [[ -z "$mode" ]] && continue
  guard="$(guard_for "$mode")"
  case "$guard" in
    @process@)
      printf 'mode:%s N/A — process discipline, no code guard (excluded)\n' "$mode"
      ;;
    @unknown@)
      printf 'mode:%s FAIL — no guard mapped for this mode (fail-closed)\n' "$mode"
      oer=$((oer + 1))
      ;;
    *)
      if ! [[ -f "$TESTS_DIR/$guard" ]]; then
        printf 'mode:%s FAIL — guard battery %s missing (fail-closed)\n' "$mode" "$guard"
        oer=$((oer + 1))
      elif run_battery "$guard"; then
        printf 'mode:%s PASS — %s green (hole still closed)\n' "$mode" "$guard"
        pass=$((pass + 1))
      else
        printf 'mode:%s FAIL — %s red (hole re-opened)\n' "$mode" "$guard"
      fi
      ;;
  esac
done <<< "$MODE_IDS"

# --- rollup: PASS count minus half per untrustworthy (OER) mode ---
score="$(pass="$pass" oer="$oer" python3 - <<'PY'
import os
p = int(os.environ["pass"]); o = int(os.environ["oer"])
# floor at 0.0: a negative rollup is meaningless (it is deep in discard territory
# anyway) and the append-only ledger validates score as non-negative.
print(f"{max(0.0, p - 0.5 * o):.1f}")
PY
)"
emit_score_and_exit "$score"
