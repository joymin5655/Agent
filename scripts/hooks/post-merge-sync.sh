#!/usr/bin/env bash
# AirLens — PostToolUse Bash hook for post-merge cleanup observability.
#
# Trigger: PostToolUse Bash matcher.
# Watches for `git merge` / `git pull` commands. After successful merge
# of a `claude/*` or `gsd-*` branch into main, logs a cleanup hint to
# .claude/logs/post-merge-sync.jsonl listing:
#   - merged branch (if extractable)
#   - active worktrees still bound to that branch
#   - canonical-13 paths whose §History likely needs updating
#
# Silent observability — no auto-deletion, no auto-commit. Just records
# the post-merge state so the operator can run cleanup deliberately.
#
# Refs:
#   - Plan: ~/.claude/plans/wondrous-sprouting-riddle.md (P1)
#   - Pattern: scripts/hooks/claude-mem-watch.py (silent jsonl)
#   - Policy: .claude/rules/multi-agent-worktree.md §R5 + §R7

set -euo pipefail

LOG_PATH=".claude/logs/post-merge-sync.jsonl"
PROJECT_ROOT="/Volumes/WD_BLACK SN770M 2TB/AirLens-platform"

# Always pass-through. We never block PostToolUse.
emit_continue() {
  printf '{"continue":true,"suppressOutput":true}\n'
  exit 0
}

# Read stdin (Claude tool envelope).
STDIN_RAW=$(/bin/cat 2>/dev/null || true)

if [[ -z "${STDIN_RAW// }" ]]; then
  emit_continue
fi

# Extract command. Use python3 — jq may not be present.
CMD=$(printf '%s' "${STDIN_RAW}" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || echo "")

# Only act on merge / pull / push (after-merge cleanup signals).
case "${CMD}" in
  *"git merge"*|*"git pull"*|*"gh pr merge"*) ;;
  *) emit_continue ;;
esac

cd "${PROJECT_ROOT}" 2>/dev/null || emit_continue

# Detect current branch (typically `main` after merge).
CURRENT_BRANCH=$(/usr/bin/git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# List local branches that look stale (claude/*, gsd-*, codex/*, gemini/*).
STALE_BRANCHES=$(/usr/bin/git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
  | /usr/bin/grep -E '^(claude|codex|gemini|gsd)/' || true)

# List worktrees still pointing to claude/* / codex/* / gemini/* / gsd-* branches.
# Use python for safe path-with-space handling.
WORKTREES=$(/usr/bin/git worktree list --porcelain 2>/dev/null | python3 -c '
import sys, re
cur = None
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "):
        cur = line[len("worktree "):]
    elif line.startswith("branch refs/heads/"):
        b = line[len("branch refs/heads/"):]
        if re.match(r"^(claude|codex|gemini|gsd)/", b) and cur:
            out.append(f"{b}\t{cur}")
print("\n".join(out))
' 2>/dev/null || true)

# Canonical-13 paths whose §History should be reviewed after merge.
CANONICAL_HISTORY_HINT=(
  "Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md"
  ".claude/rules/external-plugin-policy.md"
  ".claude/rules/multi-agent-worktree.md"
)

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$(dirname "${LOG_PATH}")"

# Build JSON line via python3 for safe escaping.
python3 - "${TS}" "${CMD}" "${CURRENT_BRANCH}" "${STALE_BRANCHES}" "${WORKTREES}" "${CANONICAL_HISTORY_HINT[@]}" <<'PY' >> "${LOG_PATH}" 2>/dev/null || true
import json, sys
ts, cmd, branch, stale_raw, wt_raw, *hints = sys.argv[1:]
stale = [b for b in stale_raw.split("\n") if b.strip()]
worktrees = [w for w in wt_raw.split("\n") if w.strip()]
entry = {
    "ts": ts,
    "trigger": "post-merge-sync",
    "current_branch": branch,
    "merge_command_excerpt": cmd[:200],
    "stale_local_branches": stale,
    "active_agent_worktrees": worktrees,
    "history_review_hint": hints,
}
print(json.dumps(entry, ensure_ascii=False))
PY

emit_continue
