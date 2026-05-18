#!/usr/bin/env bash
# T0-D-2: stale worktree GC — remove worktrees whose branch has been merged into main.
# Silent + best-effort. Called by agent-session-start.sh on SessionStart.
#
# Strategy:
#   1. Enumerate .worktrees/<agent>-<slug>/
#   2. For each, read the branch (git -C <wt> branch --show-current)
#   3. If branch is merged into origin/main (git branch --merged), remove worktree
#   4. NEVER remove if cwd is inside that worktree (current session)
#   5. NEVER remove if active session in lock file owns the worktree
#   6. NEVER remove if the worktree has uncommitted or untracked changes
#
# Safety: uses `git worktree remove --force` only when branch is verified merged.
# Anything ambiguous → skip and log to stderr.

set -e

resolve_canonical_root() {
  local common_dir root
  if common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    if [[ "$(basename "$common_dir")" == ".git" ]]; then
      root="$(dirname "$common_dir")"
    else
      root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    (cd "$root" 2>/dev/null && pwd -P) && return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

ROOT="$(resolve_canonical_root)"
WORKTREES_DIR="$ROOT/.worktrees"
LOCK_FILE="$ROOT/.claude/locks/active-sessions.json"

[[ -d "$WORKTREES_DIR" ]] || exit 0

# Refresh main ref (best-effort; offline OK).
git -C "$ROOT" fetch origin main --quiet 2>/dev/null || true

# Owned worktree paths (active sessions).
OWNED=()
if [[ -f "$LOCK_FILE" ]] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r p; do
    [[ -n "$p" ]] && OWNED+=("$p")
  done < <(jq -r '.sessions[]?.worktree // empty' "$LOCK_FILE" 2>/dev/null)
fi

is_owned() {
  local target="$1" owned
  for owned in "${OWNED[@]}"; do
    [[ "$owned" == "$target" ]] && return 0
  done
  return 1
}

CURRENT_CWD="$(pwd -P)"

# Batch-fetch list of branches whose PRs are MERGED on GitHub.
# Single API call instead of per-worktree network calls. Best-effort: empty list on failure.
MERGED_BRANCHES=""
if command -v gh >/dev/null 2>&1; then
  MERGED_BRANCHES="$(gh pr list --state merged --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null || echo "")"
fi

is_pr_merged() {
  local branch="$1"
  [[ -z "$MERGED_BRANCHES" ]] && return 1
  echo "$MERGED_BRANCHES" | grep -Fxq "$branch"
}

removed=0
for wt in "$WORKTREES_DIR"/*/; do
  [[ -d "$wt" ]] || continue
  wt="${wt%/}"

  # Skip if current cwd is inside this worktree
  case "$CURRENT_CWD" in
    "$wt"|"$wt"/*) continue ;;
  esac

  # Skip if active session owns it
  if is_owned "$wt"; then continue; fi

  # Skip dirty worktrees even when their branch tip is merged. A session may
  # have uncommitted work while its branch ref still points at main.
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null || true)" ]]; then
    continue
  fi

  # Get branch name
  branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo "")
  [[ -z "$branch" ]] && continue

  # Check 1: traditional merge (branch tip is ancestor of origin/main)
  is_merged=0
  merge_base=$(git -C "$ROOT" merge-base "$branch" origin/main 2>/dev/null || echo "")
  branch_tip=$(git -C "$ROOT" rev-parse "$branch" 2>/dev/null || echo "")

  if [[ -n "$merge_base" && -n "$branch_tip" && "$merge_base" == "$branch_tip" ]]; then
    is_merged=1
  fi

  # Check 2: GitHub PR merged (covers squash-merge — the AirLens default pattern).
  # Uses batch result fetched once at the top of the script.
  if [[ $is_merged -eq 0 ]] && is_pr_merged "$branch"; then
    is_merged=1
  fi

  if [[ $is_merged -eq 1 ]]; then
    if git -C "$ROOT" worktree remove "$wt" --force 2>/dev/null; then
      echo "worktree-stale-cleanup: removed merged worktree $wt (branch=$branch)" >&2
      removed=$((removed + 1))
    fi
  fi
done

# Also prune .git/worktrees/ admin entries for removed paths
git -C "$ROOT" worktree prune 2>/dev/null || true

[[ $removed -gt 0 ]] && echo "worktree-stale-cleanup: removed $removed stale worktree(s)" >&2

exit 0
