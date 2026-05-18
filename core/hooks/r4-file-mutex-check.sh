#!/usr/bin/env bash
# PreToolUse hook — R4.1 file-level mutex
#
# Mirrors r4-mutex-check.sh but at the code-file granularity. When a Write/Edit/MultiEdit
# targets a file already being edited by ANOTHER active session (recorded in
# .agent/locks/active-sessions.json under sessions[*].files[]), return permissionDecision="ask"
# so the user explicitly confirms the overlap.
#
# Never denies — file-level coordination across multiple AIs would be too friction-heavy
# if we hard-blocked. The `ask` decision surfaces the overlap to the user.
#
# Wire into PreToolUse with matcher "Write|Edit|MultiEdit". See adapters/<ai>/settings.template.
#
# Self-touch: this hook ALSO records the current edit in active-sessions.json under
# sessions[me].files[], so subsequent edits by other sessions can detect overlap.
# That bookkeeping is best-effort (silent failure).

set -e

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // .tool // ""')

case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

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
LOCK_FILE="$ROOT/.agent/locks/active-sessions.json"
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
    # Outside repo (e.g., ~/.config/...) — skip mutex check
    exit 0
  fi
else
  REL="$TARGET"
fi

# Whitelist patterns that bypass mutex (fixtures, generated, lock files)
case "$REL" in
  *.fixture.json|*-test.json|*.snap|*.lock|*.min.js|*.min.css|*-generated.*|*/dist/*|*/build/*|*/.cache/*|*/node_modules/*|.agent/locks/*|.agent/logs/*|*/__pycache__/*)
    exit 0
    ;;
esac

# Compute calling session_id from env or cwd
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
    f"Coordinate before overwriting. Confirm to proceed."
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
"$ROOT/core/infra/agent-session.sh" touch "$REL" >/dev/null 2>&1 || true

exit 0
