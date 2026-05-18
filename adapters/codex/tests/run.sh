#!/usr/bin/env bash
# Codex adapter smoke tests — verify translator + wrapper gate behavior.
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ADAPTER_DIR/adapter.sh"
TRANSLATOR="$ADAPTER_DIR/adapter.py"
WRAPPER="$ADAPTER_DIR/codex-shell-wrap.sh"

PASS=0
FAIL=0

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo "  ok $name"
        PASS=$((PASS + 1))
    else
        echo "  fail $name"
        echo "    expected: $expected"
        echo "    got:      $actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Codex adapter smoke tests ==="

# T1 — translator passes through canonical
echo "[T1] translator pass-through canonical event..."
OUT=$(echo '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | python3 "$TRANSLATOR")
check "T1 canonical preserved" '"tool_name": "Bash"' "$OUT"

# T2 — translator converts shell_call envelope
echo "[T2] translator converts shell_call..."
OUT=$(echo '{"type":"shell_call","arguments":{"command":["bash","-lc","cat secrets/foo"]}}' \
    | python3 "$TRANSLATOR")
check "T2 shell_call to Bash" '"tool_name": "Bash"' "$OUT"
check "T2 command unwrapped" '"command": "cat secrets/foo"' "$OUT"

# T3 — translator converts file_write envelope
echo "[T3] translator converts file_write..."
OUT=$(echo '{"type":"file_write","path":"/tmp/x.py","content":"x = 1"}' \
    | python3 "$TRANSLATOR")
check "T3 file_write tool_name" '"tool_name": "Write"' "$OUT"

# T4 — synthetic adapter mode -> deny via pre-tool-guard.sh
echo "[T4] synthetic adapter blocks secrets path..."
OUT=$("$ADAPTER" pre-tool-guard.sh --tool Bash --command "cat secrets/foo.env" 2>&1 || true)
check "T4 deny present" "deny" "$OUT"

# T5 — wrapper blocks denied command
echo "[T5] codex-shell-wrap.sh blocks deny..."
set +e
"$WRAPPER" -lc "cat secrets/foo.env" >/dev/null 2>/tmp/codex-wrap-stderr.log
EXIT=$?
set -e
STDERR=$(cat /tmp/codex-wrap-stderr.log 2>/dev/null || true)
rm -f /tmp/codex-wrap-stderr.log
if [[ "$EXIT" -eq 100 ]]; then
    echo "  ok T5 wrapper exit 100"
    PASS=$((PASS + 1))
else
    echo "  fail T5 wrapper exit was $EXIT (expected 100)"
    FAIL=$((FAIL + 1))
fi
check "T5 stderr contains BLOCKED" "BLOCKED" "$STDERR"

# T6 — wrapper allows harmless command
echo "[T6] codex-shell-wrap.sh allows harmless command..."
OUT=$("$WRAPPER" -lc "echo hello" 2>&1)
check "T6 harmless command executed" "hello" "$OUT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
