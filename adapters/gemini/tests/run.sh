#!/usr/bin/env bash
# Gemini adapter smoke tests — verify translator + wrapper gate behavior.
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ADAPTER_DIR/adapter.sh"
TRANSLATOR="$ADAPTER_DIR/adapter.py"
WRAPPER="$ADAPTER_DIR/gemini-shell-wrap.sh"

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

echo "=== Gemini adapter smoke tests ==="

# T1 — translator passes through canonical
echo "[T1] translator pass-through canonical..."
OUT=$(echo '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | python3 "$TRANSLATOR")
check "T1 canonical preserved" '"tool_name": "Bash"' "$OUT"

# T2 — translator converts run_shell_command envelope
echo "[T2] translator converts run_shell_command..."
OUT=$(echo '{"name":"run_shell_command","args":{"command":"cat secrets/foo"}}' \
    | python3 "$TRANSLATOR")
check "T2 run_shell_command to Bash" '"tool_name": "Bash"' "$OUT"
check "T2 command preserved" '"command": "cat secrets/foo"' "$OUT"

# T3 — translator converts write_file envelope
echo "[T3] translator converts write_file..."
OUT=$(echo '{"name":"write_file","args":{"file_path":"/tmp/x.py","content":"x = 1"}}' \
    | python3 "$TRANSLATOR")
check "T3 write_file tool_name" '"tool_name": "Write"' "$OUT"
check "T3 file_path preserved" '"file_path": "/tmp/x.py"' "$OUT"

# T4 — translator converts replace envelope
echo "[T4] translator converts replace..."
OUT=$(echo '{"name":"replace","args":{"file_path":"/tmp/x.py","old_string":"a","new_string":"b"}}' \
    | python3 "$TRANSLATOR")
check "T4 replace tool_name" '"tool_name": "Edit"' "$OUT"

# T5 — synthetic adapter mode -> deny via pre-tool-guard.sh
echo "[T5] synthetic adapter blocks secrets path..."
OUT=$("$ADAPTER" pre-tool-guard.sh --tool Bash --command "cat secrets/foo.env" 2>&1 || true)
check "T5 deny present" "deny" "$OUT"

# T6 — wrapper blocks denied command
echo "[T6] gemini-shell-wrap.sh blocks deny..."
set +e
"$WRAPPER" -lc "cat secrets/foo.env" >/dev/null 2>/tmp/gemini-wrap-stderr.log
EXIT=$?
set -e
STDERR=$(cat /tmp/gemini-wrap-stderr.log 2>/dev/null || true)
rm -f /tmp/gemini-wrap-stderr.log
if [[ "$EXIT" -eq 100 ]]; then
    echo "  ok T6 wrapper exit 100"
    PASS=$((PASS + 1))
else
    echo "  fail T6 wrapper exit was $EXIT (expected 100)"
    FAIL=$((FAIL + 1))
fi
check "T6 stderr contains BLOCKED" "BLOCKED" "$STDERR"

# T7 — wrapper allows harmless command
echo "[T7] gemini-shell-wrap.sh allows harmless command..."
OUT=$("$WRAPPER" -lc "echo hello" 2>&1)
check "T7 harmless command executed" "hello" "$OUT"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
