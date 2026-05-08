#!/usr/bin/env bash
# T1-B: pre-PR drift detector — invoked BEFORE `gh pr create`.
# Compares current branch's changed files vs files touched by other OPEN PRs.
# Exit 1 if overlap detected, listing the conflicting PR numbers.
#
# Usage:
#   pre-pr-drift-check.sh                # uses current branch + auto-detect base
#   pre-pr-drift-check.sh <base>         # explicit base (default origin/main)
#   DRIFT_CHECK_DRY_RUN=1 pre-pr-drift-check.sh   # warn, exit 0
#
# Memory: PR #222 incident — codex/paper-ink-web-migration vs main's #219/#220/#221
# touched same paper/ink components, blocked at merge time. This hook flags it
# at PR-create time (before push to remote, before reviewer time wasted).
#
# Wire: scripts/infra/agent-session.sh ship + codex / gemini wrappers' pre-create step.
# Not a Claude Code hook (PR creation is user-initiated).

set -e

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
DRY_RUN="${DRIFT_CHECK_DRY_RUN:-0}"
BASE="${1:-origin/main}"

if ! command -v gh >/dev/null 2>&1; then
  echo "pre-pr-drift-check: gh CLI unavailable — skipping" >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "pre-pr-drift-check: jq unavailable — skipping" >&2
  exit 0
fi

# Refresh the base ref (best-effort)
git -C "$ROOT" fetch origin main --quiet 2>/dev/null || true

CURRENT_BRANCH="$(git -C "$ROOT" branch --show-current)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  echo "pre-pr-drift-check: detached HEAD, skipping" >&2
  exit 0
fi

# Files this branch changed vs base
MY_FILES="$(git -C "$ROOT" diff --name-only "${BASE}...HEAD" 2>/dev/null | sort -u)"

if [[ -z "$MY_FILES" ]]; then
  echo "pre-pr-drift-check: no changes vs $BASE — nothing to check" >&2
  exit 0
fi

# All open PRs (excluding current branch's PR if any)
OPEN_PRS_JSON="$(gh pr list --state open --limit 50 --json number,headRefName,author,title 2>/dev/null || echo '[]')"

if [[ "$OPEN_PRS_JSON" == "[]" ]]; then
  echo "pre-pr-drift-check: no open PRs — clear to push" >&2
  exit 0
fi

# Build a list of (pr_number, branch) excluding ours
CANDIDATES="$(printf '%s' "$OPEN_PRS_JSON" \
  | jq -r --arg me "$CURRENT_BRANCH" '
    .[] | select(.headRefName != $me)
    | "\(.number)\t\(.headRefName)\t\(.title)"
  ')"

if [[ -z "$CANDIDATES" ]]; then
  echo "pre-pr-drift-check: no other open PRs — clear to push" >&2
  exit 0
fi

OVERLAP_FOUND=0
TMP_MY="$(mktemp)"
printf '%s\n' "$MY_FILES" > "$TMP_MY"

while IFS=$'\t' read -r pr_num pr_branch pr_title; do
  [[ -z "$pr_num" ]] && continue
  # Get the files of this PR (paginated up to 100)
  pr_files="$(gh pr view "$pr_num" --json files --jq '.files[].path' 2>/dev/null | sort -u)"
  [[ -z "$pr_files" ]] && continue

  # Compute overlap
  overlap="$(comm -12 <(echo "$pr_files") "$TMP_MY")"

  if [[ -n "$overlap" ]]; then
    OVERLAP_FOUND=1
    echo "" >&2
    echo "✗ DRIFT: PR #${pr_num} (${pr_branch}) — \"${pr_title}\"" >&2
    echo "  shared files:" >&2
    echo "$overlap" | sed 's/^/    /' >&2
  fi
done <<< "$CANDIDATES"

rm -f "$TMP_MY"

if [[ $OVERLAP_FOUND -eq 1 ]]; then
  echo "" >&2
  echo "Drift detected — coordinate before pushing:" >&2
  echo "  • Wait for the other PR to merge, then rebase your branch onto origin/main" >&2
  echo "  • OR: split your changes to avoid the shared files" >&2
  echo "  • OR: pair-review with the other PR's author" >&2
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "(DRIFT_CHECK_DRY_RUN=1, exit 0 instead of 1)" >&2
    exit 0
  fi
  exit 1
fi

echo "✓ pre-pr-drift-check: no overlap with ${CANDIDATES//$'\t'/ } — clear to push" >&2
exit 0
