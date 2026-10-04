#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_GLOBAL_INSTRUCTIONS="$WORK/CLAUDE.md"
export CODEX_GLOBAL_AGENTS="$WORK/AGENTS.md"
printf 'personal Claude\n' > "$CLAUDE_GLOBAL_INSTRUCTIONS"
printf 'personal Codex\n' > "$CODEX_GLOBAL_AGENTS"
if bash "$ROOT/setup.sh" --instructions-only --dry-run > "$WORK/check.log"; then
    echo 'FAIL: missing managed block must report drift'; exit 1
fi
[[ "$(cat "$CLAUDE_GLOBAL_INSTRUCTIONS")" == 'personal Claude' ]]
bash "$ROOT/setup.sh" --instructions-only > "$WORK/apply.log"
bash "$ROOT/setup.sh" --instructions-only --dry-run > "$WORK/current.log"
grep -q 'personal Claude' "$CLAUDE_GLOBAL_INSTRUCTIONS"
grep -q 'personal Codex' "$CODEX_GLOBAL_AGENTS"
if bash "$ROOT/setup.sh" --instructions-only --gemini > "$WORK/reject.log" 2>&1; then
    echo 'FAIL: mixed installation mode must be rejected'; exit 1
fi
echo 'PASS: read-only drift, both targets, personal text, repeat check, mode isolation'
