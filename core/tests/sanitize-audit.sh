#!/usr/bin/env bash
# Sanitize audit — verify no AirLens / prior-project taint outside legacy/
#
# Usage: bash core/tests/sanitize-audit.sh
# Exit 0: clean. Exit 1: taint found (prints offending files).
#
# Scope: git-visible content only — tracked files (working-tree state) plus
# untracked-but-not-ignored files (anything that could reach a commit).
# Gitignored runtime state (.claude/locks/, .omc/, /CLAUDE.md, *.jsonl, ...)
# is never scanned: it never ships.
#
# The grep pattern below is intentionally split into separate tokens to
# avoid the audit script itself triggering its own pattern when committed.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "FAIL — not a git work tree (audit scans git-tracked scope)"
  exit 1
}

# Build pattern from per-token args (avoids self-match — audit's own regex
# is constructed at runtime from these tokens, not stored as a literal in a file).
TOKENS=(
  "AirLens"
  "airlens"
  "PM2\\.5"
  "AOD"
  "DQSS"
  "Obsidian-airlens"
  "Glass-box"
  "/Volumes/WD_BLACK"
  "ML Uncertainty"
  "Edge Fn"
)

# Join with |  (multi-word tokens are fine: the joined pattern is passed as a
# single quoted ERE argument, where a space is a literal).
JOINED="$(IFS='|'; echo "${TOKENS[*]}")"

# Pathspec excludes mirror the CI sanitize job (.github/workflows/ci.yml):
# legacy/ is the intentional archive; this script and ci.yml hold the
# forbidden tokens as literals (runtime-joined here, grep pattern there).
TAINT=$(git grep -I -l -i -E --untracked -e "$JOINED" -- \
  ':!legacy' \
  ':!core/tests/sanitize-audit.sh' \
  ':!.github/workflows/ci.yml' \
  || true)

if [[ -n "$TAINT" ]]; then
  echo "FAIL — taint detected in files outside legacy/:"
  echo "$TAINT" | sed 's/^/  /'
  echo ""
  echo "Sanitize before commit. See AGENTS.md § 2 (sanitize discipline)."
  exit 1
fi

echo "PASS — no taint detected (scope: tracked + untracked-unignored; excluded legacy/, self, ci.yml)"
exit 0
