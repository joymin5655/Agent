#!/usr/bin/env bash
# registry-drift-test.sh — prove core/tests/registry-drift.sh is NON-VACUOUS: for
# each of the four drift classes it is meant to catch, plant exactly that defect in
# an isolated fixture copy of the repo's registry-relevant files and assert the gate
# FAILs (exit 1) AND names the defect; and assert a clean fixture PASSes (exit 0).
#
# A gate that always-passes (or always-fails) would make these cases FAIL — the
# defect-injection cases require exit 1 + a specific message, the clean case
# requires exit 0. That two-sided contract is what makes the gate non-vacuous.
#
# The four classes (mirroring the CI validate-plugin job the gate extracts):
#   (1) plugin.json missing a required field
#   (2) hooks.json referencing a non-existent core/hooks file
#   (3) an agents/*.md missing name: frontmatter
#   (4) registry model != agent .md model
#
# Each case gets a FRESH fixture (mktemp -d) so a mutation never leaks into another.
# The gate is pointed at the fixture via REGISTRY_DRIFT_ROOT.
#
# Usage: bash core/tests/registry-drift-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/core/tests/registry-drift.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# build_fixture — a fresh isolated copy of the registry-relevant subtree; echoes
# its path. cp -R preserves the executable bit on core/hooks files (which check 2
# asserts), on both macOS and ubuntu.
build_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  mkdir -p "$fx/.claude-plugin" "$fx/hooks" "$fx/core"
  cp "$REPO_ROOT/.claude-plugin/plugin.json"      "$fx/.claude-plugin/"
  cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$fx/.claude-plugin/"
  cp "$REPO_ROOT/hooks/hooks.json"                "$fx/hooks/"
  cp -R "$REPO_ROOT/core/hooks"                   "$fx/core/hooks"
  cp -R "$REPO_ROOT/agents"                       "$fx/agents"
  printf '%s' "$fx"
}

# run_gate <root> — run the gate against <root>; sets GATE_RC and GATE_OUT.
GATE_OUT=""; GATE_RC=0
run_gate() { GATE_OUT="$(REGISTRY_DRIFT_ROOT="$1" bash "$GATE" 2>&1)"; GATE_RC=$?; }

echo "=== (0) clean fixture -> PASS (exit 0) ==="
FX=$(build_fixture)
run_gate "$FX"
[[ $GATE_RC -eq 0 ]]; check "clean-fixture-pass" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'PASS'; check "clean-fixture-says-PASS" $?

echo
echo "=== (1) plugin.json missing a required field -> FAIL + named ==="
FX=$(build_fixture)
python3 - "$FX/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
del d["license"]          # drop a required field
json.dump(d, open(p, "w"))
PY
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "missing-field-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'plugin.json missing license'; check "missing-field-named" $?

echo
echo "=== (2) hooks.json referencing a non-existent core/hooks file -> FAIL + named ==="
FX=$(build_fixture)
python3 - "$FX/hooks/hooks.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
# repoint the first command's core-hook filename at a file that does not exist
ev = next(iter(d["hooks"]))
c = d["hooks"][ev][0]["hooks"][0]
parts = c["command"].split()
parts[-1] = "nonexistent-ghost-hook.sh"
c["command"] = " ".join(parts)
json.dump(d, open(p, "w"))
PY
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "missing-hook-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'missing core/hooks/nonexistent-ghost-hook.sh'; check "missing-hook-named" $?

echo
echo "=== (3) an agents/*.md missing name: frontmatter -> FAIL + named ==="
FX=$(build_fixture)
# strip the name: line from one agent md (its model: line stays, so only check 3 trips)
grep -v '^name:' "$REPO_ROOT/agents/code-reviewer.md" > "$FX/agents/code-reviewer.md"
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "missing-name-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'agent without frontmatter'; check "missing-name-named" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'code-reviewer.md'; check "missing-name-names-the-file" $?

echo
echo "=== (4) registry model != agent .md model -> FAIL + named ==="
FX=$(build_fixture)
python3 - "$FX/agents/master-registry.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
# flip the first agent's registry model so it disagrees with agents/<id>.md
d["agents"][0]["model"] = "definitely-not-the-md-model"
json.dump(d, open(p, "w"))
PY
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "model-drift-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'model drift'; check "model-drift-named" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
