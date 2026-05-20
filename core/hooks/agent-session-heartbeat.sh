#!/usr/bin/env bash
# Claude Code UserPromptSubmit / PostToolUse hook — heartbeat current cwd worktree session.
# Silent and best-effort.
# Wire by adding to .claude/settings.local.json under "UserPromptSubmit" and/or "PostToolUse".

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
SESSION_SH="$ROOT/scripts/infra/agent-session.sh"
[[ -x "$SESSION_SH" ]] || exit 0
"$SESSION_SH" heartbeat-cwd >/dev/null 2>&1 || true
exit 0
