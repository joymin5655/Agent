#!/usr/bin/env bash
# Cross-AI parity test — verify all 3 adapters produce the same decision
# for the same synthetic event.
#
# This is the regression guard for the "3 AI same behavior" promise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_ADAPTER="$REPO_ROOT/adapters/claude-code/adapter.sh"
CODEX_ADAPTER="$REPO_ROOT/adapters/codex/adapter.sh"
GEMINI_ADAPTER="$REPO_ROOT/adapters/gemini/adapter.sh"

PASS=0
FAIL=0

# Compare deny presence across all 3 AIs for the secrets/ scenario.
echo "=== Cross-AI parity: deny on secrets/ access ==="

CLAUDE_OUT=$(echo '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat secrets/foo.env"}}' \
    | "$CLAUDE_ADAPTER" pre-tool-guard.sh 2>&1 || true)
CODEX_OUT=$("$CODEX_ADAPTER" pre-tool-guard.sh --tool Bash --command "cat secrets/foo.env" 2>&1 || true)
GEMINI_OUT=$("$GEMINI_ADAPTER" pre-tool-guard.sh --tool Bash --command "cat secrets/foo.env" 2>&1 || true)

for ai in claude codex gemini; do
    case $ai in
        claude) out=$CLAUDE_OUT ;;
        codex)  out=$CODEX_OUT ;;
        gemini) out=$GEMINI_OUT ;;
    esac
    if [[ "$out" == *"deny"* ]]; then
        echo "  ok $ai: deny"
        PASS=$((PASS + 1))
    else
        echo "  fail $ai: missing deny (got: $out)"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "=== Cross-AI parity: allow on harmless command ==="

CLAUDE_OUT=$(echo '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
    | "$CLAUDE_ADAPTER" pre-tool-guard.sh 2>&1 || true)
CODEX_OUT=$("$CODEX_ADAPTER" pre-tool-guard.sh --tool Bash --command "ls -la" 2>&1 || true)
GEMINI_OUT=$("$GEMINI_ADAPTER" pre-tool-guard.sh --tool Bash --command "ls -la" 2>&1 || true)

for ai in claude codex gemini; do
    case $ai in
        claude) out=$CLAUDE_OUT ;;
        codex)  out=$CODEX_OUT ;;
        gemini) out=$GEMINI_OUT ;;
    esac
    if [[ "$out" != *"deny"* ]]; then
        echo "  ok $ai: allow (no deny)"
        PASS=$((PASS + 1))
    else
        echo "  fail $ai: false deny on harmless cmd"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "=== Parity results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
