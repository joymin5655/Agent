#!/usr/bin/env bash
# Stop hook — session close cleanup + broadcast 'done' + macOS notification (optional).

set -euo pipefail

# Resolve repo root
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

PROJECT_ROOT="$(resolve_canonical_root)"

# 0. SessionEnd — cheap lock/session release ONLY. ALL SessionEnd hooks share
# a 1.5s budget (docs/hook-protocol.md), so this branch must skip everything
# below that costs a python startup, a network round-trip, or brain capture:
# the TODO scan, tmpfile cleanup, macOS notification, and the session-store
# broadcast (which shells out to python3) all stay on Stop, which has no such
# shared-budget constraint. `stop`/`stop-cwd` are pure bash+jq lock-file edits.
INPUT="$(cat 2>/dev/null || true)"
HOOK_EVENT="$(printf '%s' "$INPUT" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')" || true
if [[ -z "$HOOK_EVENT" ]]; then
  HOOK_EVENT="$(printf '%s' "$INPUT" | grep -o '"event"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/')" || true
fi

if [[ "$HOOK_EVENT" == "SessionEnd" ]]; then
  SESSION_SH="$PROJECT_ROOT/core/infra/agent-session.sh"
  if [[ -x "$SESSION_SH" ]]; then
    # 1s mutex budget: SessionEnd hooks share a 1.5s runtime budget, and
    # update_lock() would otherwise wait up to 10s on a contended lock.
    export AGENT_SESSION_MUTEX_TIMEOUT=1
    if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
      "$SESSION_SH" stop >/dev/null 2>&1 || true
    else
      "$SESSION_SH" stop-cwd >/dev/null 2>&1 || true
    fi
  fi
  exit 0
fi

# 1. TODO summary (project-specific — only fires if TODO.md exists)
TODO_FILE="$PROJECT_ROOT/TODO.md"
if [[ -f "$TODO_FILE" ]]; then
  PENDING=$(grep -c '^\- \[ \]' "$TODO_FILE" 2>/dev/null) || PENDING=0
  if [[ "$PENDING" -gt 0 ]]; then
    echo "[session-close] TODO.md has $PENDING unchecked item(s)."
  fi
fi

# 2. Per-session tmpfile cleanup (matches session-init.py)
rm -f /tmp/agent-dept-* 2>/dev/null || true
rm -f /tmp/agent-harness-checked 2>/dev/null || true
rm -f /tmp/agent-importance-checked 2>/dev/null || true
rm -f /tmp/agent-purpose-declared 2>/dev/null || true
rm -f /tmp/agent-harness-bypass 2>/dev/null || true
rm -f /tmp/agent-build-error 2>/dev/null || true
rm -f /tmp/agent-advisor-consulted 2>/dev/null || true
rm -f /tmp/agent-intent-feature 2>/dev/null || true
rm -f /tmp/agent-review-model 2>/dev/null || true
rm -f /tmp/agent-plan-approved 2>/dev/null || true

# 3. macOS notification (silent on non-macOS)
if command -v osascript >/dev/null 2>&1; then
  osascript -e 'display notification "Session ended" with title "Agent" sound name "Purr"' >/dev/null 2>&1 &
fi

# 4. Broadcast 'done' event for multi-session visibility
SESSION_SH="$PROJECT_ROOT/core/infra/agent-session.sh"
if [[ -x "$SESSION_SH" ]]; then
  "$SESSION_SH" broadcast done "session ended" 2>/dev/null || true
fi

exit 0
