#!/usr/bin/env bash
# SessionStart hook — register lock entry + GC stale sessions + broadcast started.
#
# Silent and best-effort: never blocks AI session start.
# Wire by adding to your AI's SessionStart matcher (see adapters/<ai>/settings.template).
#
# Behavior:
#   1. Register the current cwd as an active session in .agent/locks/active-sessions.json
#   2. Garbage-collect stale entries (heartbeat > 30 min)
#   3. Broadcast a 'started' event for multi-session visibility
#   4. Emit a SessionStart additionalContext with:
#      - Dashboard summary (other active sessions, locks, recent events)
#      - main-behind-origin/main commit count
#      - tdd-guard test cache freshness (if cache present)

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
SESSION_SH="$ROOT/core/infra/agent-session.sh"
[[ -x "$SESSION_SH" ]] || exit 0

"$SESSION_SH" register-cwd >/dev/null 2>&1 || true

# Auto GC on SessionStart:
#   1. Prune git worktree admin entries for removed dirs
#   2. Drop stale lock entries (heartbeat > 30min)
#   3. Clean up worktrees whose branches are fully merged into origin/main
git -C "$ROOT" worktree prune 2>/dev/null || true
"$SESSION_SH" gc >/dev/null 2>&1 || true
if [[ -x "$ROOT/core/infra/worktree-stale-cleanup.sh" ]]; then
  "$ROOT/core/infra/worktree-stale-cleanup.sh" 2>/dev/null || true
fi

# Reset per-session supervisor flag files (so leftover state doesn't leak across sessions)
rm -f /tmp/agent-intent-feature \
      /tmp/agent-required-agents \
      /tmp/agent-dispatched-agents \
      /tmp/agent-harness-mode \
      /tmp/agent-supervisor-analysis.json 2>/dev/null || true

# Broadcast 'started' event so other sessions see this one come online.
# Fall back to main-tree-tagged session_id when no AGENT_SESSION_ID and no worktree.
if ! "$SESSION_SH" broadcast started "session start" 2>/dev/null; then
  AGENT_SESSION_ID="${AGENT:-claude}-main-$(date -u +%Y%m%dT%H%M%SZ)" \
    "$SESSION_SH" broadcast started "session start (main tree)" 2>/dev/null || true
fi

# Emit additionalContext JSON for the SessionStart prompt:
#   1) Dashboard summary (active sessions + locks + recent events) — R11
#   2) main behind origin/main count + recent commits
#   3) tdd-guard cache freshness (if present)
if command -v jq >/dev/null 2>&1; then
  CTX_PARTS=()

  SUMMARY="$("$SESSION_SH" dashboard --format=summary 2>/dev/null || true)"
  if [[ -n "$SUMMARY" ]]; then
    CTX_PARTS+=("=== Multi-agent dashboard ===" "$SUMMARY")
  fi

  # Supervisor goal-mode TUI status (silent when no active goals)
  GOAL_TUI="$("$SESSION_SH" goal-dashboard 2>/dev/null || true)"
  if [[ -n "$GOAL_TUI" ]]; then
    CTX_PARTS+=("" "$GOAL_TUI")
  fi

  # main behind origin/main — silent best-effort fetch
  if /usr/bin/git -C "$ROOT" fetch origin main --quiet 2>/dev/null; then
    BEHIND="$(/usr/bin/git -C "$ROOT" rev-list --count main..origin/main 2>/dev/null || echo 0)"
    if [[ -n "$BEHIND" && "$BEHIND" -gt 0 ]]; then
      RECENT="$(/usr/bin/git -C "$ROOT" log --oneline main..origin/main 2>/dev/null | head -5)"
      CTX_PARTS+=("" "=== main is $BEHIND commits behind origin/main ===" "$RECENT" \
        "Run: git -C \"$ROOT\" rebase origin/main (in main tree) or pull from your worktree.")
    fi
  fi

  # tdd-guard test cache freshness (TTL 600s default)
  TDD_CACHE="$ROOT/.agent/state/test-last-run.json"
  if [[ -f "$TDD_CACHE" ]]; then
    CACHE_MTIME="$(/usr/bin/stat -f %m "$TDD_CACHE" 2>/dev/null || /usr/bin/stat -c %Y "$TDD_CACHE" 2>/dev/null || echo 0)"
    if [[ "$CACHE_MTIME" -gt 0 ]]; then
      NOW_EPOCH="$(date -u +%s)"
      AGE_S="$((NOW_EPOCH - CACHE_MTIME))"
      FAILED_COUNT="$(/usr/bin/jq -r '.failedFiles | length' "$TDD_CACHE" 2>/dev/null || echo 0)"
      if [[ "$AGE_S" -gt 600 ]]; then
        FRESHNESS="stale (${AGE_S}s, TTL 600s — run your test suite to refresh)"
      else
        FRESHNESS="fresh (${AGE_S}s)"
      fi
      CTX_PARTS+=("" "=== tdd-guard test cache: $FRESHNESS — $FAILED_COUNT failed file(s) ===")
    fi
  fi

  if [[ ${#CTX_PARTS[@]} -gt 0 ]]; then
    CTX="$(printf '%s\n' "${CTX_PARTS[@]}")"
    /usr/bin/jq -nc \
      --arg ctx "$CTX" \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  fi
else
  "$SESSION_SH" dashboard --format=summary 2>/dev/null || true
fi

exit 0
