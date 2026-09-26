#!/usr/bin/env bash
# launcher-test.sh — contract battery for adapters/claude-code/launchers/.
#
# Every case drives a STUBBED `claude` (and, for claude-ox, a stubbed
# `security`) on PATH — no real session is started. The battery asserts on
# the ARGV/env each launcher hands to `claude`, because that argv is the
# entire point of a purpose launcher (adapters/claude-code/launchers/README.md):
# a named, visible session-start choice, not a runtime switch.
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

command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not installed (claude-ox.template requires it)"; exit 2; }

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"   # canonicalize — claude-ox resolves its cwd via
                                # `pwd -P` (symlinks followed); macOS mktemp
                                # lands under a /var/folders symlink to
                                # /private/var/folders, so an unresolved
                                # fixture path here would never match.
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
RECORD="$TMP/record"

cat > "$STUB_DIR/claude" <<STUB
#!/usr/bin/env bash
{
  printf 'argv:'; printf ' %q' "\$@"; printf '\n'
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR:-<unset>}"
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
echo "=== claude-ox — Keychain + isolation + sensitive-cwd guard ==="
OXHOME="$TMP/home"
mkdir -p "$OXHOME"
cat > "$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
echo "STUB-OX-KEY-99"
STUB
chmod +x "$STUB_DIR/security"

mkdir -p "$OXHOME/.config/agent-harness"
BLOCKED_DIR="$TMP/blocked-client-project"
mkdir -p "$BLOCKED_DIR/sub"
printf '%s\n' "$BLOCKED_DIR" > "$OXHOME/.config/agent-harness/sensitive-paths"

: > "$RECORD"
out="$(cd "$OXHOME" && env PATH="$STUB_DIR:/usr/bin:/bin" HOME="$OXHOME" USER="${USER:-tester}" \
    zsh "$LAUNCHERS_DIR/claude-ox.template" hi 2>&1)"
rc=$?
check "ox-allowed-cwd-exits-0" 0 "$rc"
grep -q "CLAUDE_CONFIG_DIR=$OXHOME/.claude-ox" "$RECORD"; check "ox-isolates-config-dir" 0 $?
grep -q -- '--strict-mcp-config' "$RECORD"; check "ox-strips-mcp-by-default" 0 $?
grep -q -- '--permission-mode manual' "$RECORD"; check "ox-forces-manual-permission-mode" 0 $?

: > "$RECORD"
out="$(cd "$BLOCKED_DIR/sub" && env PATH="$STUB_DIR:/usr/bin:/bin" HOME="$OXHOME" USER="${USER:-tester}" \
    zsh "$LAUNCHERS_DIR/claude-ox.template" hi 2>&1)"
rc=$?
check "ox-blocked-cwd-refuses" 1 "$rc"
[[ ! -s "$RECORD" ]]; check "ox-blocked-cwd-never-calls-claude" 0 $?
printf '%s' "$out" | grep -qi "차단된 경로"; check "ox-blocked-cwd-message" 0 $?

: > "$RECORD"
out="$(cd "$BLOCKED_DIR/sub" && env PATH="$STUB_DIR:/usr/bin:/bin" HOME="$OXHOME" USER="${USER:-tester}" \
    CLAUDE_OX_FORCE=1 zsh "$LAUNCHERS_DIR/claude-ox.template" hi 2>&1)"
rc=$?
check "ox-force-override-bypasses-guard" 0 "$rc"

echo
echo "=== claude-ox — missing Keychain entry -> fail-closed ==="
cat > "$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/security"
: > "$RECORD"
out="$(cd "$OXHOME" && env PATH="$STUB_DIR:/usr/bin:/bin" HOME="$OXHOME" USER="${USER:-tester}" \
    zsh "$LAUNCHERS_DIR/claude-ox.template" hi 2>&1)"
rc=$?
check "ox-missing-keychain-refuses" 1 "$rc"
[[ ! -s "$RECORD" ]]; check "ox-missing-keychain-never-calls-claude" 0 $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
