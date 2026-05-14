#!/bin/bash
# check-cross-store.sh — PostToolUse hook
# Detect cross-store imports in Zustand store files.
# ECS Principle: System A must not call System B directly.
#
# Reads tool input from stdin (JSON with tool_input.file_path).
# Exits 0 (pass) or prints warning to stderr.

set -euo pipefail

# Read stdin for tool input
INPUT=$(cat)

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    fp = data.get('tool_input', {}).get('file_path', '')
    print(fp)
except:
    print('')
" 2>/dev/null)

# Only check store files
if [[ "$FILE_PATH" != *"/src/store/"* ]]; then
    exit 0
fi

BASENAME=$(basename "$FILE_PATH" .ts)

# Find imports of other stores within this store file
VIOLATIONS=$(grep -n "from '\./.*Store'" "$FILE_PATH" 2>/dev/null | grep -v "export" || true)

if [[ -n "$VIOLATIONS" ]]; then
    echo "[ECS] Cross-store import detected in $BASENAME:" >&2
    echo "$VIOLATIONS" >&2
    echo "" >&2
    echo "Store files must not import other stores. See rules/ecs-architecture.md" >&2
    echo "Move the dependency to a Hook that orchestrates both stores." >&2
    # Warning only (exit 0), not blocking — until refactoring is complete
    exit 0
fi

exit 0
