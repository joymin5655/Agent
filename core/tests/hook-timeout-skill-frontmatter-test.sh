#!/usr/bin/env bash
# hook-timeout-skill-frontmatter-test.sh — pin two manifest properties:
#   (1) every command hook in hooks/hooks.json has a positive numeric `timeout`, so none falls back
#       to the 600 s host default (docs/hook-protocol.md section 14);
#   (2) every skills/*/SKILL.md frontmatter parses as YAML (an unparseable block makes the host
#       ignore its keys, e.g. disable-model-invocation), and the user-invoked-only skills carry
#       `disable-model-invocation: true`.
# The YAML parse needs PyYAML; without it that half prints a SKIP line and the rest still runs.
#
# Usage: bash core/tests/hook-timeout-skill-frontmatter-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

echo "=== (1) hooks.json: every command hook has a numeric timeout ==="
OUT="$(python3 - "$REPO_ROOT/hooks/hooks.json" <<'PY'
import json, sys
bad = []
for event, groups in json.load(open(sys.argv[1], encoding="utf-8"))["hooks"].items():
    for g in groups:
        for h in g.get("hooks", []):
            if h.get("type") == "command":
                t = h.get("timeout")
                if isinstance(t, bool) or not isinstance(t, (int, float)) or t <= 0:
                    bad.append(f"{event}:{h.get('command', '')[-40:]}")
print("OK" if not bad else "BAD " + "; ".join(bad))
PY
)"
[[ "$OUT" == OK ]]; check "all-hooks-have-timeout" $?
[[ "$OUT" == OK ]] || echo "    $OUT"

echo
echo "=== (2) SKILL.md frontmatter: valid YAML, user-invoked-only flag ==="
OUT="$(python3 - "$REPO_ROOT/skills" <<'PY'
import pathlib, re, sys
try:
    import yaml
except ImportError:
    print("NOYAML"); sys.exit()
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*/SKILL.md")):
    m = re.match(r"---\n(.*?)\n---\n", f.read_text(encoding="utf-8"), re.S)
    if not m:
        bad.append(f"{f.parent.name}: no frontmatter"); continue
    try:
        meta = yaml.safe_load(m.group(1))
    except yaml.YAMLError as e:
        bad.append(f"{f.parent.name}: {type(e).__name__}"); continue
    if not isinstance(meta, dict) or "name" not in meta:
        bad.append(f"{f.parent.name}: not a mapping with name")
print("OK" if not bad else "BAD " + "; ".join(bad))
PY
)"
if [[ "$OUT" == NOYAML ]]; then
  echo "  skip [frontmatter-parses] PyYAML not installed"
else
  [[ "$OUT" == OK ]]; check "frontmatter-parses" $?
  [[ "$OUT" == OK ]] || echo "    $OUT"
fi
for s in worker-setup reorg-sync; do
  grep -qE '^disable-model-invocation: true$' "$REPO_ROOT/skills/$s/SKILL.md"; check "$s-user-invoked-only" $?
done
for s in wrap council-review supervise; do
  ! grep -q '^disable-model-invocation:' "$REPO_ROOT/skills/$s/SKILL.md"; check "$s-stays-model-invocable" $?
done

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
