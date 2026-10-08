#!/usr/bin/env bash
# launcher-test.sh — contract battery for adapters/claude-code/launchers/.
#
# Every case drives a STUBBED `claude` on PATH — no real session is started.
# The battery asserts on the ARGV each launcher hands to `claude`, because that
# argv is the entire point of a purpose launcher
# (adapters/claude-code/launchers/README.md): a named, visible session-start
# choice, not a runtime switch.
#
# Usage: bash adapters/claude-code/tests/launcher-test.sh
set -uo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHERS_DIR="$ADAPTER_DIR/launchers"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
RECORD="$TMP/record"

cat > "$STUB_DIR/claude" <<STUB
#!/usr/bin/env bash
{
  printf 'argv:'; printf ' %q' "\$@"; printf '\n'
} >> "$RECORD"
STUB
chmod +x "$STUB_DIR/claude"

echo "=== claude-build — plain passthrough ==="
: > "$RECORD"
env PATH="$STUB_DIR:/usr/bin:/bin" bash "$LAUNCHERS_DIR/claude-build" hello --flag >/dev/null 2>&1
grep -q "argv: hello --flag" "$RECORD"; check "build-passes-args-through" 0 $?
grep -q -- '--model' "$RECORD"; check "build-adds-no-model-flag" 1 $?

echo
echo "=== claude-quick — LOW rung (haiku) ==="
: > "$RECORD"
env PATH="$STUB_DIR:/usr/bin:/bin" bash "$LAUNCHERS_DIR/claude-quick" hello >/dev/null 2>&1
grep -q -- '--model haiku' "$RECORD"; check "quick-pins-haiku" 0 $?
grep -q "hello" "$RECORD"; check "quick-passes-args-through" 0 $?

echo
echo "=== claude-research — MID rung (sonnet) ==="
: > "$RECORD"
env PATH="$STUB_DIR:/usr/bin:/bin" bash "$LAUNCHERS_DIR/claude-research" hello >/dev/null 2>&1
grep -q -- '--model sonnet' "$RECORD"; check "research-pins-sonnet" 0 $?
grep -q -- '--effort medium' "$RECORD"; check "research-pins-medium-effort" 0 $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
