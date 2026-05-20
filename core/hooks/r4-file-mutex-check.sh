#!/usr/bin/env bash
# AirLens — PreToolUse R4.1 *file-level* mutex check (T1-A, 2026-05-07).
# Mirrors r4-mutex-check.sh but for code files.
#
# Behavior: if the target file is already claimed by a DIFFERENT active session,
# request permission with hookSpecificOutput.permissionDecision="ask" so the
# user explicitly confirms the override.
# We never deny — file-level coordination across multiple AIs would be too
# friction-heavy if we hard-blocked.
#
# Wire in .claude/settings.local.json PreToolUse with matcher "Write|Edit|MultiEdit",
# AFTER gsd-cwd-guard.sh (so cwd-guard runs first to enforce worktree isolation).
#
# Self-touch: this hook ALSO records the current Edit in active-sessions.json
# under sessions[me].files[], so subsequent edits by other sessions can detect overlap.
# That bookkeeping is best-effort (silent failure).

set -e

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // ""')

# Only check on Write|Edit|MultiEdit
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

# Extract the target file path
TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')

if [[ -z "$TARGET" ]]; then
  exit 0
fi

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
LOCK_FILE="$ROOT/.claude/locks/active-sessions.json"
WORKTREES_DIR="$ROOT/.worktrees"

# Normalize TARGET to repo-relative path
if [[ "$TARGET" == /* ]]; then
  if [[ "$TARGET" == "$WORKTREES_DIR"/* ]]; then
    rel_with_worktree="${TARGET#"$WORKTREES_DIR"/}"
    case "$rel_with_worktree" in
      */*) REL="${rel_with_worktree#*/}" ;;
      *) exit 0 ;;
    esac
  elif [[ "$TARGET" == "$ROOT"/* ]]; then
    REL="${TARGET#$ROOT/}"
  else
    # Outside repo (e.g., ~/.claude/...) — skip mutex check.
    exit 0
  fi
else
  REL="$TARGET"
fi

# Whitelist patterns that bypass mutex (fixtures, generated, lock files)
case "$REL" in
  *.fixture.json|*-test.json|*.snap|*.lock|*.min.js|*.min.css|*-generated.*|*/dist/*|*/build/*|*/.cache/*|*/node_modules/*|.claude/locks/*|.claude/logs/*|*/__pycache__/*)
    exit 0
    ;;
esac

# Compute the calling session_id from env or cwd (mirrors r4-mutex-check.sh)
SESSION_ID=""
if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
  SESSION_ID="$AGENT_SESSION_ID"
fi
if [[ -z "$SESSION_ID" ]]; then
  CWD="$(pwd -P)"
  if [[ "$CWD" == "$WORKTREES_DIR"/* ]]; then
    rel="${CWD#"$WORKTREES_DIR"/}"
    wt_name="${rel%%/*}"
    if [[ "$wt_name" =~ ^(claude|codex|gemini)-(.+)$ ]]; then
      SESSION_ID="${BASH_REMATCH[1]}-wt-${BASH_REMATCH[2]}"
    fi
  fi
fi
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="${AGENT:-claude}-main"
fi

if [[ ! -f "$LOCK_FILE" ]]; then
  exit 0
fi

# Find any OTHER session that has this file in its files[] list
OWNER=$(jq -r --arg p "$REL" --arg me "$SESSION_ID" '
  [.sessions[]? | select(.session_id != $me) | select((.files // [])[]?.path == $p) | .session_id] | first // empty
' "$LOCK_FILE" 2>/dev/null || echo "")

if [[ -n "$OWNER" ]]; then
  OWNER_AGENT=$(jq -r --arg sid "$OWNER" '[.sessions[]? | select(.session_id == $sid) | .agent] | first // "unknown"' "$LOCK_FILE")
  OWNER_BRANCH=$(jq -r --arg sid "$OWNER" '[.sessions[]? | select(.session_id == $sid) | .branch] | first // "unknown"' "$LOCK_FILE")
  LAST_EDIT=$(jq -r --arg sid "$OWNER" --arg p "$REL" '
    [.sessions[]? | select(.session_id == $sid) | (.files // [])[]? | select(.path == $p) | .last_edit] | first // ""
  ' "$LOCK_FILE")

  python3 - "$REL" "$OWNER" "$OWNER_AGENT" "$OWNER_BRANCH" "$LAST_EDIT" "$SESSION_ID" <<'PY'
import json, sys
path, owner, owner_agent, owner_branch, last_edit, current = sys.argv[1:7]
reason = (
    f"R4.1 file mutex: '{path}' is being edited by another session.\n"
    f"  owner_session = {owner}\n"
    f"  owner_agent   = {owner_agent}\n"
    f"  owner_branch  = {owner_branch}\n"
    f"  last_edit     = {last_edit}\n"
    f"  current       = {current}\n"
    f"Coordinate before overwriting (PR #222 pattern). Confirm to proceed."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
  exit 0
fi

# No conflict — record this edit in our session's files[] (best-effort)
"$ROOT/scripts/infra/agent-session.sh" touch "$REL" >/dev/null 2>&1 || true

exit 0
