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
