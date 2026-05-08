#!/bin/bash
# AirLens — TDD Guard (PreToolUse: Write|Edit)
# Warns when modifying implementation files without corresponding test files.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    fp = data.get('tool_input', {}).get('file_path', '')
    print(fp)
except:
    print('')
" 2>/dev/null)

# Skip if no file path
[ -z "$FILE_PATH" ] && exit 0

# Only check apps/web/src/ files (post 2026-04-30 monorepo)
echo "$FILE_PATH" | grep -qE 'apps/web/src/.*\.(ts|tsx)$' || exit 0

# Skip test files, type files, config, styles, declarations
echo "$FILE_PATH" | grep -qE '\.(test|spec)\.(ts|tsx)$' && exit 0
echo "$FILE_PATH" | grep -qE '(types/|config/|constants/|locales/|styles/)' && exit 0
echo "$FILE_PATH" | grep -qE '\.(css|scss|json|d\.ts)$' && exit 0
echo "$FILE_PATH" | grep -qE '(index\.ts$|vite-env)' && exit 0

# Extract base name and directory
BASENAME=$(basename "$FILE_PATH" | sed -E 's/\.(ts|tsx)$//')
DIRPATH=$(dirname "$FILE_PATH")

# Look for corresponding test file in same dir or __tests__/
FOUND=0
for PATTERN in "${DIRPATH}/${BASENAME}.test.ts" \
               "${DIRPATH}/${BASENAME}.test.tsx" \
               "${DIRPATH}/${BASENAME}.spec.ts" \
               "${DIRPATH}/${BASENAME}.spec.tsx" \
               "${DIRPATH}/__tests__/${BASENAME}.test.ts" \
               "${DIRPATH}/__tests__/${BASENAME}.test.tsx"; do
    [ -f "$PATTERN" ] && FOUND=1 && break
done

if [ "$FOUND" -eq 0 ]; then
    RELATIVE=$(echo "$FILE_PATH" | sed 's|.*/apps/web/||')
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"TDD Guard: ${RELATIVE} has no test file. Consider writing tests first (TDD). Expected: ${BASENAME}.test.ts(x)\"}}"
fi

exit 0
