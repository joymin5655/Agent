#!/usr/bin/env bash
# Sanitize audit — verify no AirLens / prior-project taint outside legacy/
#
# Usage: bash core/tests/sanitize-audit.sh
# Exit 0: clean. Exit 1: taint found (prints offending files).
#
# The grep alternation below is intentionally split into separate calls to
# avoid the audit script itself triggering its own pattern when committed.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

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
)

# Join with |
JOINED="$(IFS='|'; echo "${TOKENS[*]}")"

TAINT=$(grep -ri -l -E "$JOINED" . \
  --include="*.md" --include="*.sh" --include="*.py" --include="*.yml" \
  --include="*.toml" --include="*.json" \
  2>/dev/null \
  | grep -v "^./legacy/" \
  | grep -v "^./.git/" \
  | grep -v "^./core/tests/sanitize-audit.sh$" \
  || true)

if [[ -n "$TAINT" ]]; then
  echo "FAIL — taint detected in files outside legacy/:"
  echo "$TAINT" | sed 's/^/  /'
  echo ""
  echo "Sanitize before commit. See AGENTS.md § 2 (sanitize discipline)."
  exit 1
fi

echo "PASS — no taint detected (audit scanned root excluding legacy/, .git/, self)"
exit 0
