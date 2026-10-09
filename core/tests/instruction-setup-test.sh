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
if bash "$ROOT/setup.sh" --instructions-only --codex > "$WORK/reject.log" 2>&1; then
    echo 'FAIL: mixed installation mode must be rejected'; exit 1
fi
grep -q 'cannot be combined with other install modes' "$WORK/reject.log" || {
    echo 'FAIL: mixed mode must be rejected by the mode-isolation guard, not by arg parsing'; exit 1
}
# --gemini retired 2026-10-09 (legacy/lanes-2026-10/gemini/): now an unknown arg, exit 2 before any install
if bash "$ROOT/setup.sh" --gemini > "$WORK/gemini.log" 2>&1; then
    echo 'FAIL: retired --gemini flag must be rejected'; exit 1
fi
grep -q 'unknown arg: --gemini' "$WORK/gemini.log" || {
    echo 'FAIL: retired --gemini flag must report an unknown arg'; exit 1
}
echo 'PASS: read-only drift, both targets, personal text, repeat check, mode isolation, retired --gemini'
