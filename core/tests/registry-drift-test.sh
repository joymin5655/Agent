#!/usr/bin/env bash
# registry-drift-test.sh — prove core/tests/registry-drift.sh is NON-VACUOUS: for
# each of the drift classes it is meant to catch, plant exactly that defect in
# an isolated fixture copy of the repo's registry-relevant files and assert the gate
# FAILs (exit 1) AND names the defect; and assert a clean fixture PASSes (exit 0).
#
# A gate that always-passes (or always-fails) would make these cases FAIL — the
# defect-injection cases require exit 1 + a specific message, the clean case
# requires exit 0. That two-sided contract is what makes the gate non-vacuous.
#
# The six classes (1-4 mirror the CI validate-plugin job the gate extracts;
# 5-6 are the O-1 orchestration-contract guards):
#   (1) plugin.json missing a required field
#   (2) hooks.json referencing a non-existent core/hooks file
#   (3) an agents/*.md missing name: frontmatter
#   (4) registry model != agent .md model
#   (5) review/verify agent whose toolset is not read-only (or unbounded)
#   (6) skills/supervise shipping without a delegation-contract **model**: field
#   (7) a shipped SKILL.md description without a "NOT " negative-trigger (T-3)
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
echo "=== (5) review/verify agent with a write-capable tool -> FAIL + named ==="
FX=$(build_fixture)
python3 - "$FX/agents/code-reviewer.md" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# arm the reviewer with Write — exactly what the read-only guard must catch
s = re.sub(r"(?m)^tools:.*$", "tools: [Read, Grep, Glob, Write]", s, count=1)
open(p, "w", encoding="utf-8").write(s)
PY
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "reviewer-write-tool-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'read-only guard'; check "reviewer-write-tool-named" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'Write'; check "reviewer-write-tool-names-the-tool" $?

echo
echo "=== (5b) review/verify agent with NO tools allowlist -> FAIL (all-tools default) ==="
FX=$(build_fixture)
python3 - "$FX/agents/security-reviewer.md" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r"(?m)^tools:.*\n", "", s, count=1)   # drop the allowlist entirely
open(p, "w", encoding="utf-8").write(s)
PY
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "reviewer-no-allowlist-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'no tools: allowlist'; check "reviewer-no-allowlist-named" $?

echo
echo "=== (5c) review/verify agent with a read-only MULTILINE tools list -> PASS ==="
FX=$(build_fixture)
printf -- '---\nname: style-verifier\nmodel: sonnet\ntools:\n  - Read\n  - Grep\n---\n# style-verifier\n' > "$FX/agents/style-verifier.md"
python3 - "$FX/agents/master-registry.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["agents"].append({"id": "style-verifier", "model": "sonnet"})
json.dump(d, open(p, "w"))
PY
run_gate "$FX"
[[ $GATE_RC -eq 0 ]]; check "multiline-readonly-passes" $?

echo
echo "=== (5d) MULTILINE tools list smuggling a write tool -> FAIL ==="
FX=$(build_fixture)
printf -- '---\nname: style-verifier\nmodel: sonnet\ntools:\n  - Read\n  - Edit\n---\n# style-verifier\n' > "$FX/agents/style-verifier.md"
python3 - "$FX/agents/master-registry.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["agents"].append({"id": "style-verifier", "model": "sonnet"})
json.dump(d, open(p, "w"))
PY
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "multiline-write-tool-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'Edit'; check "multiline-write-tool-named" $?

echo
echo "=== (6) skills/supervise present but template missing its model field -> FAIL ==="
FX=$(build_fixture)
mkdir -p "$FX/skills/supervise/templates"
printf '# Delegation contract\n\n- Goal: x\n' > "$FX/skills/supervise/templates/delegation-contract.md"
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "template-without-model-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'no **model**: field'; check "template-without-model-named" $?

echo
echo "=== (6b) skills/supervise present but template file absent -> FAIL ==="
FX=$(build_fixture)
mkdir -p "$FX/skills/supervise"
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "template-absent-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'without templates/delegation-contract.md'; check "template-absent-named" $?

echo
echo "=== (6c) template with the model field -> PASS (and no-skills fixtures stay exempt) ==="
FX=$(build_fixture)
mkdir -p "$FX/skills/supervise/templates"
printf '# Delegation contract\n\n- **model**: workhorse\n' > "$FX/skills/supervise/templates/delegation-contract.md"
run_gate "$FX"
[[ $GATE_RC -eq 0 ]]; check "template-with-model-passes" $?

echo
echo "=== (7) skill description without a negative-trigger -> FAIL + named ==="
FX=$(build_fixture)
mkdir -p "$FX/skills/demo"
printf -- '---\nname: demo\ndescription: Does a demo thing when asked.\n---\n# demo\n' > "$FX/skills/demo/SKILL.md"
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "skill-without-not-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF "no 'NOT ' negative example"; check "skill-without-not-named" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'skills/demo/SKILL.md'; check "skill-without-not-names-the-file" $?

echo
echo "=== (7b) skill description with a negative-trigger -> PASS ==="
FX=$(build_fixture)
mkdir -p "$FX/skills/demo"
printf -- '---\nname: demo\ndescription: Does a demo thing when asked. NOT for undemolike things.\n---\n# demo\n' > "$FX/skills/demo/SKILL.md"
run_gate "$FX"
[[ $GATE_RC -eq 0 ]]; check "skill-with-not-passes" $?

echo
echo "=== (7c) SKILL.md with no frontmatter at all -> FAIL + named ==="
FX=$(build_fixture)
mkdir -p "$FX/skills/demo"
printf '# demo — no frontmatter here\n' > "$FX/skills/demo/SKILL.md"
run_gate "$FX"
[[ $GATE_RC -eq 1 ]]; check "skill-no-frontmatter-fails" $?
printf '%s\n' "$GATE_OUT" | grep -qF 'has no frontmatter'; check "skill-no-frontmatter-named" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
