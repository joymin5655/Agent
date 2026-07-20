#!/usr/bin/env bash
# Wraps `codex` CLI with full agent-session lifecycle:
#   1. start lock entry + create worktree (.worktrees/codex-<slug>)
#   2. spawn background heartbeat loop (every 5 min)
#   3. cd into worktree and exec codex
#   4. on exit: kill heartbeat + release lock
#
# Worktree is NOT auto-removed; use `git worktree remove .worktrees/codex-<slug>` afterward.

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
  echo "usage: codex-session.sh <task-slug> [codex-args...]" >&2
  exit 2
fi
shift || true

if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI not found in PATH" >&2
  exit 127
fi

export AGENT=codex
export AGENT_SESSION_ID="codex-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export AGENT_SESSION_PID="$$"
"$SESSION_SH" start "$SLUG"
WORKTREE="$REPO_ROOT/.worktrees/codex-${SLUG}"

(
  while sleep 300; do
    AGENT=codex AGENT_SESSION_ID="$AGENT_SESSION_ID" "$SESSION_SH" heartbeat 2>/dev/null || true
  done
) &
HB_PID=$!

cleanup() {
  kill "$HB_PID" 2>/dev/null || true
  # Cross-AI brain breadcrumb: capture uncommitted WIP to raw/ before releasing
  # the lock. Env-driven (no stdin); fail-open so it never blocks session teardown.
  AGENT=codex AGENT_SESSION_ID="$AGENT_SESSION_ID" \
    python3 "$REPO_ROOT/core/hooks/brain-capture.py" </dev/null >/dev/null 2>&1 || true
  AGENT=codex AGENT_SESSION_ID="$AGENT_SESSION_ID" "$SESSION_SH" stop 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$WORKTREE"
codex "$@"
