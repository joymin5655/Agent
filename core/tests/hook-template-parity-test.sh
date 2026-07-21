#!/usr/bin/env bash
# hook-template-parity-test.sh — battery for hook-template-parity.sh
#
# Covers: the real repo pair passes; a hook missing from one matcher fails and
# names the event/matcher/hook; identical inventories behind different path
# prefixes pass (normalization proof); a matcher group present on only one side
# fails; unparseable JSON fails loud. Fixtures are mktemp files — never the
# real manifests.
#
# Usage: bash core/tests/hook-template-parity-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook-template-parity.sh"

PASS=0; FAIL=0
ok() { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
no() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

DIR="$(mktemp -d)"
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

# fixture <file> <prefix> <stop_hooks_json_array> [extra_event_json]
fixture() {
  local file="$1" prefix="$2" stop="$3" extra="${4:-}"
  cat > "$file" <<JSON
{
  "hooks": {
    "Stop": [
      { "matcher": "*", "hooks": [ $stop ] }
    ]$extra
  }
}
JSON
}

h() { # h <prefix> <name> — one hook entry
  printf '{ "type": "command", "command": "%s/adapter.sh %s" }' "$1" "$2"
}

# --- (a) real repo pair -> PASS ---
if OUT="$(bash "$GATE")"; then
  ok "a: real repo manifests match"
else
  no "a: real repo manifests match" "expected exit 0, got: $OUT"
fi

# --- (b) hook missing from one matcher -> FAIL naming event/matcher/hook ---
fixture "$DIR/a.json" "/p" "$(h /p one.py), $(h /p two.py)"
fixture "$DIR/b.json" "/p" "$(h /p one.py)"
if OUT="$(bash "$GATE" "$DIR/a.json" "$DIR/b.json")"; then
  no "b: missing hook fails" "expected exit 1, got pass"
else
  if grep -q "Stop" <<<"$OUT" && grep -q "two.py" <<<"$OUT"; then
    ok "b: missing hook fails naming event + hook"
  else
    no "b: missing hook fails naming event + hook" "diff not named in: $OUT"
  fi
fi

# --- (c) same inventory, different path prefixes -> PASS (normalization) ---
fixture "$DIR/c1.json" '${CLAUDE_PLUGIN_ROOT}' "$(h '${CLAUDE_PLUGIN_ROOT}' one.py), $(h '${CLAUDE_PLUGIN_ROOT}' two.sh)"
fixture "$DIR/c2.json" "{{FRAMEWORK_ROOT}}" "$(h "{{FRAMEWORK_ROOT}}" one.py), $(h "{{FRAMEWORK_ROOT}}" two.sh)"
if bash "$GATE" "$DIR/c1.json" "$DIR/c2.json" >/dev/null; then
  ok "c: differing prefixes normalize to equal"
else
  no "c: differing prefixes normalize to equal" "expected exit 0"
fi

# --- (d) matcher group on only one side -> FAIL ---
fixture "$DIR/d1.json" "/p" "$(h /p one.py)" ',
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ '"$(h /p guard.sh)"' ] } ]'
fixture "$DIR/d2.json" "/p" "$(h /p one.py)"
if bash "$GATE" "$DIR/d1.json" "$DIR/d2.json" >/dev/null; then
  no "d: one-sided matcher group fails" "expected exit 1, got pass"
else
  ok "d: one-sided matcher group fails"
fi

# --- (e) order matters within a matcher -> FAIL ---
fixture "$DIR/e1.json" "/p" "$(h /p one.py), $(h /p two.py)"
fixture "$DIR/e2.json" "/p" "$(h /p two.py), $(h /p one.py)"
if bash "$GATE" "$DIR/e1.json" "$DIR/e2.json" >/dev/null; then
  no "e: reordered chain fails" "expected exit 1, got pass"
else
  ok "e: reordered chain fails"
fi

# --- (f) unparseable JSON -> FAIL loud (never a silent pass) ---
echo '{ not json' > "$DIR/f.json"
if bash "$GATE" "$DIR/f.json" "$DIR/e2.json" >/dev/null; then
  no "f: bad JSON fails loud" "expected exit 1, got pass"
else
  ok "f: bad JSON fails loud"
fi

echo ""
echo "=== hook-template-parity-test: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
