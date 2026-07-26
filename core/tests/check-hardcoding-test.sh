#!/usr/bin/env bash
# check-hardcoding-test.sh — verify core/hooks/check-hardcoding.py (T-1 + 3-mode).
#
# Feeds canonical PreToolUse event JSON (Write tool_input) to the hook via
# stdin and asserts the emitted decision per mode. Covers:
#   - block mode: the 4 hardcoding fixtures -> deny (+ WHY/FIX teaching tags)
#   - dryrun mode (DEFAULT): same fixtures -> advisory (additionalContext),
#     NEVER a deny — design-taste gate must not hard-block by default
#   - off mode: no output at all
#   - exempt path (config.ts / .test.) with the same content -> allow
#   - benign component content -> allow
#   - sink instrumentation: firing appends a jsonl record with guard/hook/
#     mode fields and reproduce_test:true under AGENT_REPRODUCE_TEST=1
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

SINK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hardcoding-test.XXXXXX")"
trap 'rm -rf "$SINK_DIR"' EXIT
SINK="$SINK_DIR/hardcoding.jsonl"

PASS=0
FAIL=0

# run_case <name> <mode> <file_path> <content> <expect: deny|advisory|allow>
run_case() {
  local name="$1" mode="$2" fpath="$3" content="$4" expect="$5"
  local event out got
  event=$(FP="$fpath" CT="$content" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":os.environ["FP"],"content":os.environ["CT"]}}))')
  out=$(printf '%s' "$event" | AGENT_HARDCODING_MODE="$mode" AGENT_HARDCODING_SINK="$SINK" AGENT_REPRODUCE_TEST=1 python3 "$HOOK" 2>/dev/null || true)
  got="allow"
  [[ "$out" == *'additionalContext'* ]] && got="advisory"
  [[ "$out" == *'"permissionDecision": "deny"'* || "$out" == *'"permissionDecision":"deny"'* ]] && got="deny"
  if [[ "$got" == "$expect" ]]; then
    echo "  ok   [$name] mode=$mode expected=$expect"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] mode=$mode expected=$expect got=$got :: $out"
    FAIL=$((FAIL + 1))
  fi
  # T-1 teaching contract: every deny/advisory reason carries WHY: and FIX: tags.
  if [[ "$expect" == "deny" || "$expect" == "advisory" ]]; then
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

echo "=== block mode: hardcoding patterns in scanned paths -> deny ==="
run_case "color-segment-array-deny" block "src/components/Legend.tsx" "$COLOR_ARR" deny
run_case "css-gradient-deny"        block "src/components/Bar.tsx"    "$GRADIENT"  deny
run_case "tick-array-deny"          block "src/pages/Chart.tsx"       "$TICKS"     deny
run_case "component-modes-deny"     block "src/components/Map.tsx"    "$MODES"     deny

echo
echo "=== dryrun mode (default): same fixtures -> advisory, never deny ==="
run_case "color-segment-array-dryrun" dryrun "src/components/Legend.tsx" "$COLOR_ARR" advisory
run_case "css-gradient-dryrun"        dryrun "src/components/Bar.tsx"    "$GRADIENT"  advisory

# Default-mode contract: with NO mode env set, the hook behaves as dryrun.
event=$(FP="src/components/Legend.tsx" CT="$COLOR_ARR" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":os.environ["FP"],"content":os.environ["CT"]}}))')
OUT=$(printf '%s' "$event" | env -u AGENT_HARDCODING_MODE AGENT_HARDCODING_SINK="$SINK" AGENT_REPRODUCE_TEST=1 python3 "$HOOK" 2>/dev/null || true)
if [[ "$OUT" == *'additionalContext'* && "$OUT" != *'"deny"'* ]]; then
  echo "  ok   [unset-mode-defaults-to-dryrun]"; PASS=$((PASS + 1))
else
  echo "  FAIL [unset-mode-defaults-to-dryrun] :: $OUT"; FAIL=$((FAIL + 1))
fi

echo
echo "=== off mode: no output ==="
OUT=$(printf '%s' "$event" | AGENT_HARDCODING_MODE=off AGENT_HARDCODING_SINK="$SINK" python3 "$HOOK" 2>/dev/null || true)
if [[ -z "$OUT" ]]; then
  echo "  ok   [off-mode-silent]"; PASS=$((PASS + 1))
else
  echo "  FAIL [off-mode-silent] :: $OUT"; FAIL=$((FAIL + 1))
fi

echo
echo "=== allow: exempt paths and benign content (block mode = strictest) ==="
run_case "exempt-config-allow" block "src/config.ts" "$COLOR_ARR" allow
run_case "exempt-test-allow"   block "src/components/Legend.test.tsx" "$COLOR_ARR" allow
run_case "benign-component-allow" block "src/components/Card.tsx" \
  'import { theme } from "../config"; export const Card = () => null' allow
run_case "modes-outside-component-dir-allow" block "src/lib/state.ts" "$MODES" allow

echo
echo "=== sink instrumentation: firings logged with guard/hook/mode ==="
if [[ -f "$SINK" ]]; then
  REC_CHECK=$(SINK="$SINK" python3 - <<'PYEOF'
import json, os
ok = deny = dry = 0
with open(os.environ["SINK"], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if (r.get("guard") == "hardcoding" and r.get("hook") == "check-hardcoding.py"
                and r.get("reproduce_test") is True and r.get("schema_version") == "2.0.0"):
            ok += 1
        if r.get("mode") == "block" and r.get("decision") == "denied":
            deny += 1
        if r.get("mode") == "dryrun" and r.get("decision") == "would_deny":
            dry += 1
print(f"{ok} {deny} {dry}")
PYEOF
)
  read -r N_OK N_DENY N_DRY <<< "$REC_CHECK"
  if [[ "$N_OK" -ge 6 && "$N_DENY" -ge 4 && "$N_DRY" -ge 2 ]]; then
    echo "  ok   [sink-records] $N_OK well-formed ($N_DENY denied, $N_DRY would_deny)"; PASS=$((PASS + 1))
  else
    echo "  FAIL [sink-records] ok=$N_OK denied=$N_DENY would_deny=$N_DRY"; FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL [sink-records] sink never created: $SINK"; FAIL=$((FAIL + 1))
fi

echo
echo "=== fail-safe: empty / malformed stdin -> allow, exit 0 ==="
OUT=$(printf '' | AGENT_HARDCODING_SINK="$SINK" python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  echo "  ok   [empty-stdin-failsafe]"; PASS=$((PASS + 1))
else
  echo "  FAIL [empty-stdin-failsafe] rc=$RC out=$OUT"; FAIL=$((FAIL + 1))
fi
OUT=$(printf 'not json' | AGENT_HARDCODING_SINK="$SINK" python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  echo "  ok   [malformed-stdin-failsafe]"; PASS=$((PASS + 1))
else
  echo "  FAIL [malformed-stdin-failsafe] rc=$RC out=$OUT"; FAIL=$((FAIL + 1))
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
