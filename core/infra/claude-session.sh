#!/usr/bin/env bash
# Wraps `claude` (Claude Code CLI) with full agent-session lifecycle:
#   1. start lock entry + create worktree (.worktrees/claude-<slug>)
#   2. spawn background heartbeat loop (every 5 min)
#   3. cd into worktree and exec claude
#   4. on exit: kill heartbeat + release lock
#
# Claude Code also fires SessionStart / SessionStop / heartbeat hooks if they're wired
# in ~/.claude/settings.json — this wrapper is for users who prefer manual coordination
# or want the worktree-per-task convention without configuring hooks.
#
# Worktree is NOT auto-removed; use `git worktree remove .worktrees/claude-<slug>` afterward.

set -euo pipefail

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

REPO_ROOT="$(resolve_canonical_root)"
SESSION_SH="$REPO_ROOT/core/infra/agent-session.sh"

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "usage: claude-session.sh <task-slug> [claude-args...]" >&2
  exit 2
fi
shift || true

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found in PATH" >&2
  exit 127
fi

export AGENT=claude
export AGENT_SESSION_ID="claude-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export AGENT_SESSION_PID="$$"
"$SESSION_SH" start "$SLUG"
WORKTREE="$REPO_ROOT/.worktrees/claude-${SLUG}"

(
  while sleep 300; do
    AGENT=claude AGENT_SESSION_ID="$AGENT_SESSION_ID" "$SESSION_SH" heartbeat 2>/dev/null || true
  done
) &
HB_PID=$!

cleanup() {
  kill "$HB_PID" 2>/dev/null || true
  AGENT=claude AGENT_SESSION_ID="$AGENT_SESSION_ID" "$SESSION_SH" stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$WORKTREE"
claude "$@"
