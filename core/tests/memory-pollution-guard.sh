#!/usr/bin/env bash
# Memory-pollution guard — verify no AI-memory context dump has leaked into a
# committable file.
#
# Usage:
#   bash core/tests/memory-pollution-guard.sh          # scan this repo
#   bash core/tests/memory-pollution-guard.sh <dir>    # scan another work tree (test seam)
#
# Exit 0: clean. Exit 1: dump markers found (prints offending files).
#
# Why: memory plugins (e.g. claude-mem) inject session-context blocks into
# instruction files at session start. Injected into a TRACKED file (observed on
# AGENTS.md, 2026-07-21), a personal session log becomes part of the next
# commit — and with autosync, part of the public repo. This gate makes that
# state un-commit-able.
#
# Scope mirrors sanitize-audit.sh: tracked files (working-tree state) plus
# untracked-but-not-ignored files (anything that could reach a commit).
# Gitignored runtime state is never scanned: it never ships.
#
# The markers are assembled at runtime from split strings so this guard (and
# its battery) never triggers itself when committed.

set -u

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "FAIL — not a git work tree (guard scans git-tracked scope)"
  exit 1
}

# Markers assembled at runtime (never stored as literals):
#   M1 — the memory plugin's context-block open tag
#   M2 — the dump's canonical heading line
M1='<claude-mem'"-context>"
M2='^# Memory'" Context$"
PATTERN="${M1}|${M2}"

EXCLUDES=(
  ':!core/tests/memory-pollution-guard.sh'
  ':!core/tests/memory-pollution-guard-test.sh'
)

HITS="$(git grep -I -l -E --untracked -e "$PATTERN" -- "${EXCLUDES[@]}" || true)"

if [[ -n "$HITS" ]]; then
  echo "FAIL — memory context dump found in committable files:"
  echo "$HITS" | sed 's/^/  /'
  echo ""
  echo "A memory plugin injected session context into a file git would commit."
  echo "Revert the injected block (git checkout -- <file>) before committing."
  exit 1
fi

echo "PASS — no memory-dump markers (scope: tracked + untracked-unignored; excluded self + battery)"
exit 0
