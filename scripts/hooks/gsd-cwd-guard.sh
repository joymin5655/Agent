#!/usr/bin/env bash
# AirLens — PreToolUse GSD cwd-guard.
# Blocks Write/Edit creating .planning/config.json (or any .planning/** path)
# unless cwd is inside .worktrees/gsd-<task-slug>/.
# Enforces external-plugin-policy.md §3 C 룰 4 (Option B sandbox 격리).
# Wire in .claude/settings.local.json PreToolUse Write|Edit (after r4-mutex-check.sh).

set -e

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "GSD cwd-guard: jq unavailable — check skipped." >&2
  echo '{"decision":"allow"}'
  exit 0
fi

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')

if [[ -z "$FILE_PATH" ]]; then
  echo '{"decision":"allow"}'
  exit 0
fi

# Match any .planning/** path under the repo (Option B: planning state must live in worktree only).
if [[ "$FILE_PATH" != *"/.planning/"* ]] && [[ "$FILE_PATH" != ".planning/"* ]]; then
  echo '{"decision":"allow"}'
  exit 0
fi

CWD="$PWD"

# Allow only when cwd is inside .worktrees/gsd-<task-slug>/.
if [[ "$CWD" == *"/.worktrees/gsd-"* ]]; then
  echo '{"decision":"allow"}'
  exit 0
fi

REASON="GSD cwd-guard BLOCK: '.planning/' write attempted outside Option B sandbox.
  file_path     = $FILE_PATH
  current_cwd   = $CWD
  expected_cwd  = .worktrees/gsd-<task-slug>/ (per external-plugin-policy.md §3 C 룰 2)

To proceed, create a sandbox worktree first:
  git worktree add .worktrees/gsd-<task-slug> <agent>/gsd-<task-slug>
  cd .worktrees/gsd-<task-slug>

Decision rule: ~/.claude/plans/snazzy-stargazing-hartmanis.md (Option B Worktree-격리 sandbox 한정)."

# security-violations.jsonl sink (security-guards.md SOT 정합) — guard 0 (정책 외 영역, .planning leak)
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_FILE="$ROOT/.claude/logs/security-violations.jsonl"
mkdir -p "$ROOT/.claude/logs" 2>/dev/null || true
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SID="${AGENT_SESSION_ID:-main}"
printf '{"ts":"%s","guard":0,"hook":"gsd-cwd-guard.sh","file_path":%s,"cwd":%s,"reason":".planning/ leak outside sandbox","session_id":"%s","decision":"deny"}\n' \
  "$TS" \
  "$(printf '%s' "$FILE_PATH" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$FILE_PATH\"")" \
  "$(printf '%s' "$CWD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$CWD\"")" \
  "$SID" \
  >> "$LOG_FILE" 2>/dev/null || true
# work-feed broadcast (R13 — blocked event, multi-agent visibility)
[[ -x "$ROOT/scripts/infra/agent-session.sh" ]] && \
  "$ROOT/scripts/infra/agent-session.sh" broadcast blocked \
    "[security] gsd-cwd-guard.sh: .planning/ leak outside sandbox" >/dev/null 2>&1 || true

python3 - "$REASON" <<'PY'
import json, sys
print(json.dumps({"decision": "deny", "reason": sys.argv[1]}, ensure_ascii=False))
PY
