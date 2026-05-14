#!/usr/bin/env bash
# Wraps `gemini` CLI with full agent-session lifecycle:
#   1. start lock entry + create worktree
#   2. spawn background heartbeat loop
#   3. cd into worktree and exec gemini
#   4. on exit: kill heartbeat + release lock
# Worktree NOT auto-removed; use `git worktree remove .worktrees/gemini-<slug>` afterward.

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
SESSION_SH="$REPO_ROOT/scripts/infra/agent-session.sh"

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "usage: gemini-session.sh <task-slug> [gemini-args...]" >&2
  exit 2
fi
shift || true

if ! command -v gemini >/dev/null 2>&1; then
  echo "gemini CLI not found in PATH" >&2
  exit 127
fi

export AGENT=gemini
export AGENT_SESSION_ID="gemini-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export AGENT_SESSION_PID="$$"
"$SESSION_SH" start "$SLUG"
WORKTREE="$REPO_ROOT/.worktrees/gemini-${SLUG}"

(
  while sleep 300; do
    AGENT=gemini AGENT_SESSION_ID="$AGENT_SESSION_ID" "$SESSION_SH" heartbeat 2>/dev/null || true
  done
) &
HB_PID=$!

cleanup() {
  kill "$HB_PID" 2>/dev/null || true
  AGENT=gemini AGENT_SESSION_ID="$AGENT_SESSION_ID" "$SESSION_SH" stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$WORKTREE"
gemini "$@"
