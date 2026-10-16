#!/usr/bin/env bash
# review-tier.sh — review-cadence SSOT: how much review does this diff need?
#
# Three tiers, consumed by skills/wrap/SKILL.md step 1d and documented in
# docs/model-routing.md "Review cadence": review dispatches are the
# second-largest routing cost after implementation, so cadence — not just
# model tier — is a lever. Every diff gets EXACTLY one tier:
#   tier 0 — skip: docs-only, or non-risk code changes at or below
#            AGENT_REVIEW_SKIP_LINES (self-check only, no reviewer dispatch)
#   tier 1 — one code-reviewer pass at wrap/commit time (the common case)
#   tier 2 — council-scale: /council-review (delegated to
#            core/infra/council-threshold.sh, the existing SSOT for that
#            judgment — this script does NOT re-mirror its risk-area
#            GUARD_PATTERNS; that script's own header already flags itself
#            as the third hand-mirror of spec-gate's patterns, so a FOURTH
#            copy here is exactly the drift it warns against)
#
# usage: review-tier.sh [--staged|--head|<range>]  (same shape/semantics as
#         council-threshold.sh — --staged falls back to HEAD~1..HEAD when
#         staging is empty; <range> is terminated with --end-of-options so a
#         range starting with '-' can never be consumed as a git option)
#
# stdout: ALWAYS one line —
#   "tier=<0|1|2> lines=<N> files=<M> code_lines=<K> risk=<comma-list|none>"
#   lines/files/risk are council-threshold.sh's own numbers, parsed from its
#   output line rather than recomputed — one SSOT for those three. Since the
#   2026-10 change those lines/files EXCLUDE test and docs paths (its trailing
#   excluded=<n> field is ignored here): size alone escalates to tier 2 only on
#   non-test, non-docs code. code_lines is computed here: changed lines in files
#   that are NOT docs-shaped — tests still count, so a test-only diff above
#   AGENT_REVIEW_SKIP_LINES gets the tier-1 reviewer pass instead of tier 0.
# exit:   0  = tier 0 (skip)
#         5  = tier 1 (standard review)
#         10 = tier 2 (council-scale — same exit code council-threshold.sh
#              itself uses for "escalate", so a caller checking for 10 reads
#              the same signal from either script)
#
# env seams: AGENT_REVIEW_SKIP_LINES (default 50), plus AGENT_COUNCIL_LINES /
# AGENT_COUNCIL_FILES which council-threshold.sh reads directly.
#
# Consumers: skills/wrap/SKILL.md step 1d, docs/model-routing.md "Review
# cadence".
set -u

THRESHOLD_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/council-threshold.sh"
# is_docs_path — shared with council-threshold.sh so both use ONE docs definition
# shellcheck source=core/infra/path-kinds.sh
. "$(dirname "${BASH_SOURCE[0]}")/path-kinds.sh"
SKIP_LINES="${AGENT_REVIEW_SKIP_LINES:-50}"
ARG="${1:---staged}"

# Delegate the council-scale judgment (and the lines/files/risk numbers) to
# council-threshold.sh — the existing SSOT. Its own stdout line is the ONLY
# source for lines/files/risk; this script never recomputes them.
THRESHOLD_OUT="$(bash "$THRESHOLD_SCRIPT" "$ARG" 2>/dev/null)"
THRESHOLD_RC=$?

LINES=0
FILES=0
RISK="none"
# risk= is one token: council-threshold.sh appends " excluded=<n>" after it.
if [[ "$THRESHOLD_OUT" =~ lines=([0-9]+)\ files=([0-9]+)\ risk=([^\ ]*) ]]; then
  LINES="${BASH_REMATCH[1]}"
  FILES="${BASH_REMATCH[2]}"
  RISK="${BASH_REMATCH[3]}"
fi

# Same --numstat call council-threshold.sh makes (same hardening flags —
# core.fsmonitor=, --no-ext-diff --no-textconv --no-renames, --end-of-options
# for a caller-supplied range — see that script's header for why each one is
# there), recomputed here (rather than reusing council-threshold's line
# total) because that total now excludes test paths too, while code_lines
# must keep counting them (tier 0 vs 1 is about "is there anything to review").
case "$ARG" in
  --staged)
    NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames --staged --numstat 2>/dev/null)"
    if [[ -z "$NUMSTAT" ]]; then
      NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames HEAD~1..HEAD --numstat 2>/dev/null)"
    fi
    ;;
  --head)
    NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames HEAD~1..HEAD --numstat 2>/dev/null)"
    ;;
  *)
    NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames --numstat --end-of-options "$ARG" 2>/dev/null)"
    ;;
esac

CODE_LINES=0
while IFS=$'\t' read -r add del path; do
  [[ -z "$path" ]] && continue
  is_docs_path "$path" && continue
  [[ "$add" =~ ^[0-9]+$ ]] && CODE_LINES=$((CODE_LINES + add))
  [[ "$del" =~ ^[0-9]+$ ]] && CODE_LINES=$((CODE_LINES + del))
done <<< "$NUMSTAT"

TIER=1
if [[ "$THRESHOLD_RC" -eq 10 ]]; then
  TIER=2
elif [[ "$RISK" == "none" ]] && { [[ "$CODE_LINES" -eq 0 ]] || [[ "$CODE_LINES" -le "$SKIP_LINES" ]]; }; then
  TIER=0
fi

printf 'tier=%d lines=%d files=%d code_lines=%d risk=%s\n' "$TIER" "$LINES" "$FILES" "$CODE_LINES" "$RISK"

case "$TIER" in
  0) exit 0 ;;
  1) exit 5 ;;
  2) exit 10 ;;
esac
