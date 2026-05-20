#!/usr/bin/env bash
# AirLens — R4.1 worktree commit register (gap fix, 2026-05-18).
# Closes the visibility gap where worktree commits don't trigger PreToolUse Write/Edit hooks,
# so files claimed via commit (not interactive edit) never reach active-sessions.json files[].
#
# Usage:
#   r4-file-mutex-register.sh baseline   # SessionStart — bulk register `git diff main..HEAD`
#   r4-file-mutex-register.sh commit     # PostToolUse Bash — register `git diff HEAD~..HEAD`
#                                        # (only when tool_input.command matches `git commit`)
#
# Best-effort: silent exit 0 on missing deps / non-worktree cwd / empty diff / unknown mode.
# Wire in .claude/settings.local.json (see multi-agent-worktree.md §R7.1):
#   SessionStart "*": position #4, after agent-session-start.sh
#   PostToolUse  "Bash": position #3, after post-merge-sync.sh
#
# Test override:
#   R4_REGISTER_SESSION_SH=<path>   # mock agent-session.sh for reproduce tests

set +e

MODE="${1:-}"
[[ -z "$MODE" ]] && exit 0

command -v git >/dev/null 2>&1 || exit 0
command -v jq  >/dev/null 2>&1 || exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -z "$REPO_ROOT" ]] && exit 0

# Only fire inside a worktree (skip main tree).
# .git is a file (gitlink) in a worktree, a directory in the main tree.
[[ -f "$REPO_ROOT/.git" ]] || exit 0

# Resolve main tree to locate agent-session.sh (worktree scripts/ symlinks to main).
MAIN_TREE="$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')"
SESSION_SH="${R4_REGISTER_SESSION_SH:-$MAIN_TREE/scripts/infra/agent-session.sh}"
[[ -x "$SESSION_SH" ]] || exit 0

register_files() {
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    "$SESSION_SH" touch "$path" 2>/dev/null || true
  done
}

case "$MODE" in
  baseline)
    # SessionStart — bulk register all worktree-vs-main diffs once
    git -C "$REPO_ROOT" diff main..HEAD --name-only 2>/dev/null | register_files
    ;;
  commit)
    # PostToolUse Bash — only fire after `git commit` patterns
    INPUT="$(cat 2>/dev/null)"
    [[ -z "$INPUT" ]] && exit 0
    CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -z "$CMD" ]] && exit 0
    # Match `git commit ...` (excludes git commit-tree / commit-graph plumbing)
    echo "$CMD" | grep -qE '\bgit\b[^|;&]*\bcommit(\s|$)' || exit 0
    # Register diff for the just-made commit (HEAD~..HEAD), with fallback for first commit
    if git -C "$REPO_ROOT" rev-parse HEAD~ >/dev/null 2>&1; then
      git -C "$REPO_ROOT" diff HEAD~..HEAD --name-only 2>/dev/null | register_files
    else
      git -C "$REPO_ROOT" show HEAD --name-only --pretty=format: 2>/dev/null | register_files
    fi
    ;;
esac

exit 0
