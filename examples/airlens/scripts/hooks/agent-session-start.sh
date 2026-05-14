#!/usr/bin/env bash
# Claude Code SessionStart hook — register lock entry if cwd is inside .worktrees/<agent>-<slug>/.
# Silent and best-effort: never blocks claude session start.
# Wire by adding to .claude/settings.local.json:
#   "hooks": { "SessionStart": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "scripts/hooks/agent-session-start.sh" }] }] }

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

"$SESSION_SH" register-cwd >/dev/null 2>&1 || true

# T0-D: auto GC on SessionStart.
# (1) Prune git worktree admin entries for removed dirs.
# (2) Run agent-session.sh gc to drop stale lock entries (heartbeat > 30min).
# (3) Remove worktrees whose branches are fully merged into origin/main.
git -C "$ROOT" worktree prune 2>/dev/null || true
"$SESSION_SH" gc >/dev/null 2>&1 || true
if [[ -x "$ROOT/scripts/hooks/worktree-stale-cleanup.sh" ]]; then
  "$ROOT/scripts/hooks/worktree-stale-cleanup.sh" 2>/dev/null || true
fi

# 2026-05-01 fix: supervisor flag 세션 단위 reset.
# write_flags가 더 이상 매 prompt마다 DISPATCHED를 unlink 하지 않으므로,
# 새 세션 시작 시 깨끗한 상태로 복원. 누적 false-positive 방지.
rm -f /tmp/airlens-intent-feature \
      /tmp/airlens-required-agents \
      /tmp/airlens-dispatched-agents \
      /tmp/airlens-harness-mode \
      /tmp/airlens-supervisor-analysis.json 2>/dev/null || true

# Tier 2 — broadcast 'started' event so other sessions see this one come online.
# When cwd is the main tree (no AGENT_SESSION_ID, no worktree), fall back to a
# main-tree-tagged session_id so the work-feed still records new sessions.
if ! "$SESSION_SH" broadcast started "session start" 2>/dev/null; then
  AGENT_SESSION_ID="${AGENT:-claude}-main-$(date -u +%Y%m%dT%H%M%SZ)" \
    "$SESSION_SH" broadcast started "session start (main tree)" 2>/dev/null || true
fi

# G1+G2 (session-awareness-hook-gaps plan) — emit additionalContext JSON so the
# SessionStart prompt receives a system reminder with:
#   1) dashboard summary (active sessions + locks + recent events) — R11
#   2) main behind origin/main count + recent commits — detect main updates
#
# Claude Code SessionStart hook ignores raw stdout for prompt context; only
# the {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
# JSON shape is injected. Falls back to plain stdout when jq is missing
# (still useful for tail logs).
if command -v jq >/dev/null 2>&1; then
  CTX_PARTS=()

  SUMMARY="$("$SESSION_SH" dashboard --format=summary 2>/dev/null || true)"
  if [[ -n "$SUMMARY" ]]; then
    CTX_PARTS+=("=== Multi-agent dashboard ===" "$SUMMARY")
  fi

  # G2 — silent best-effort fetch + behind detection.
  if /usr/bin/git -C "$ROOT" fetch origin main --quiet 2>/dev/null; then
    BEHIND="$(/usr/bin/git -C "$ROOT" rev-list --count main..origin/main 2>/dev/null || echo 0)"
    if [[ -n "$BEHIND" && "$BEHIND" -gt 0 ]]; then
      RECENT="$(/usr/bin/git -C "$ROOT" log --oneline main..origin/main 2>/dev/null | head -5)"
      CTX_PARTS+=("" "=== main is $BEHIND commits behind origin/main ===" "$RECENT" \
        "Run: git -C \"$ROOT\" rebase origin/main (in main tree) or pull from your worktree.")
    fi
  fi

  if [[ ${#CTX_PARTS[@]} -gt 0 ]]; then
    CTX="$(printf '%s\n' "${CTX_PARTS[@]}")"
    /usr/bin/jq -nc \
      --arg ctx "$CTX" \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  fi
else
  # jq missing — keep legacy stdout behavior (visible in transcript only).
  "$SESSION_SH" dashboard --format=summary 2>/dev/null || true
fi

exit 0
