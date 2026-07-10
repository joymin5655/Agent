#!/usr/bin/env bash
# check-hardcoding-test.sh — verify core/hooks/check-hardcoding.py (T-1).
#
# Feeds canonical PreToolUse event JSON (Write tool_input) to the hook via
# stdin and asserts the emitted permissionDecision (deny / allow). Covers:
#   - inline color segment array in a component -> deny (+ WHY/FIX teaching tags)
#   - hardcoded CSS gradient -> deny
#   - tick/label/stop const array -> deny
#   - UI metadata array (MODES) in a components/ file -> deny
#   - exempt path (config.ts / .test.) with the same content -> allow
#   - benign component content -> allow
#   - empty / malformed stdin -> allow (fail-safe, exit 0)
#
# NOTE: fixture strings are assembled at RUNTIME via an empty ${Z} splice so no
# literal hardcoding pattern appears in this source — otherwise the live
# installed copy of the hook denies edits to this very file (same precedent as
# hook-config-test.sh building secret tokens at runtime).
#
# Usage: bash core/tests/check-hardcoding-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/check-hardcoding.py"
Z=""

PASS=0
FAIL=0

# run_case <name> <file_path> <content> <expect: deny|allow>
run_case() {
  local name="$1" fpath="$2" content="$3" expect="$4"
  local event out got
  event=$(FP="$fpath" CT="$content" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":os.environ["FP"],"content":os.environ["CT"]}}))')
  out=$(printf '%s' "$event" | python3 "$HOOK" 2>/dev/null || true)
  got="allow"
  [[ "$out" == *'"permissionDecision": "deny"'* || "$out" == *'"permissionDecision":"deny"'* ]] && got="deny"
  if [[ "$got" == "$expect" ]]; then
    echo "  ok   [$name] expected=$expect"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] expected=$expect got=$got :: $out"
    FAIL=$((FAIL + 1))
  fi
  # T-1 teaching contract: every deny reason must carry WHY: and FIX: tags.
  if [[ "$expect" == "deny" ]]; then
    if [[ "$out" == *"WHY:"* && "$out" == *"FIX:"* ]]; then
      echo "  ok   [$name/teaching] WHY+FIX present"
      PASS=$((PASS + 1))
    else
      echo "  FAIL [$name/teaching] reason lacks WHY:/FIX: :: $out"
      FAIL=$((FAIL + 1))
    fi
  fi
}

# Runtime-assembled fixture contents (see NOTE above).
COLOR_ARR="const scale = [[0,${Z} [255, 0, 0]], [50,${Z} [0, 255, 0]]]"
GRADIENT="const bg = \"linear-gradient(90deg,${Z} rgb(255,0,0), rgb(0,0,255))\""
TICKS="const XTI${Z}CKS = [\"0\", \"10\", \"20\"]"
MODES="const MO${Z}DES = [\"light\", \"dark\"]"

echo "=== deny: hardcoding patterns in scanned paths ==="
run_case "color-segment-array-deny" "src/components/Legend.tsx" "$COLOR_ARR" deny
run_case "css-gradient-deny"        "src/components/Bar.tsx"    "$GRADIENT"  deny
run_case "tick-array-deny"          "src/pages/Chart.tsx"       "$TICKS"     deny
run_case "component-modes-deny"     "src/components/Map.tsx"    "$MODES"     deny

echo
echo "=== allow: exempt paths and benign content ==="
run_case "exempt-config-allow" "src/config.ts" "$COLOR_ARR" allow
run_case "exempt-test-allow"   "src/components/Legend.test.tsx" "$COLOR_ARR" allow
run_case "benign-component-allow" "src/components/Card.tsx" \
  'import { theme } from "../config"; export const Card = () => null' allow
run_case "modes-outside-component-dir-allow" "src/lib/state.ts" "$MODES" allow

echo
echo "=== fail-safe: empty / malformed stdin -> allow, exit 0 ==="
OUT=$(printf '' | python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  echo "  ok   [empty-stdin-failsafe]"; PASS=$((PASS + 1))
else
  echo "  FAIL [empty-stdin-failsafe] rc=$RC out=$OUT"; FAIL=$((FAIL + 1))
fi
OUT=$(printf 'not json' | python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  echo "  ok   [malformed-stdin-failsafe]"; PASS=$((PASS + 1))
else
  echo "  FAIL [malformed-stdin-failsafe] rc=$RC out=$OUT"; FAIL=$((FAIL + 1))
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
