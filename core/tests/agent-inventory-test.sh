#!/usr/bin/env bash
# agent-inventory-test.sh — reconcile suite for core/hooks/agent-inventory.py.
#
# Asserts the evidence-first inventory contract:
#   - a registry id WITH a sibling <id>.md classifies as `real`
#   - a registry id WITHOUT one classifies as `ghost` (quarantined)
#   - a <id>.md with no registry entry classifies as `discovered`
#   - run() persists .agent/state/agent-inventory.json and load_ghost_set reads it
#   - --sync additively wires discovered providers in, copying model: from
#     frontmatter (no model drift), after which they become `real`, not discovered
#   - sync NEVER removes/edits an existing entry
#   - no registry present is fail-open (empty verdict, no crash, nothing written)
#
# Every scenario runs against a throwaway dir in $(mktemp -d) with an isolated
# .agent/ — the real repo is never touched.
#
# Usage: bash core/tests/agent-inventory-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOD="$REPO_ROOT/core/hooks/agent-inventory.py"

PASS=0
FAIL=0
FIXTURES=()

cleanup() {
  local d
  for d in ${FIXTURES[@]+"${FIXTURES[@]}"}; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL — %s\n' "$1"; }

# assert_py <label> <python-body>
# The python body imports the module as `m`, has `root` (pathlib.Path) and `reg`
# (the registry path) in scope, and must print exactly "PASS" on success.
assert_py() {
  local label="$1" body="$2" root="$3" reg="$4" out
  out="$(ROOT="$root" REG="$reg" MODPATH="$MOD" python3 - <<PY 2>&1
import importlib.util, os, pathlib
spec = importlib.util.spec_from_file_location("m", os.environ["MODPATH"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = pathlib.Path(os.environ["ROOT"])
reg = pathlib.Path(os.environ["REG"])
$body
PY
)"
  if [[ "$out" == "PASS" ]]; then ok "$label"; else bad "$label ($out)"; fi
}

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

# agent_md <path> <model>
agent_md() {
  printf -- '---\nname: %s\nmodel: %s\n---\nbody\n' "$(basename "$1" .md)" "$2" > "$1"
}

make_fixture() {  # -> echoes the fixture dir
  local d; d="$(mktemp -d)"; FIXTURES+=("$d")
  mkdir -p "$d/agents"
  echo "$d"
}

# ---------------------------------------------------------------------------
# 1. clean — id with matching .md is `real`
# ---------------------------------------------------------------------------
D="$(make_fixture)"
cat > "$D/agents/master-registry.json" <<'JSON'
{"version":1,"agents":[{"id":"code-reviewer","model":"sonnet"}]}
JSON
agent_md "$D/agents/code-reviewer.md" "sonnet"
assert_py "clean: matching .md -> real" '
r = m.reconcile(reg)
print("PASS" if r["real"]==["code-reviewer"] and not r["ghost"] and not r["discovered"] else r)
' "$D" "$D/agents/master-registry.json"

# ---------------------------------------------------------------------------
# 2. ghost — id with no .md is quarantined
# ---------------------------------------------------------------------------
D="$(make_fixture)"
cat > "$D/agents/master-registry.json" <<'JSON'
{"version":1,"agents":[{"id":"ui-director","model":"opus"}]}
JSON
assert_py "ghost: id without .md -> ghost" '
r = m.reconcile(reg)
print("PASS" if r["ghost"]==["ui-director"] and not r["real"] else r)
' "$D" "$D/agents/master-registry.json"

# ---------------------------------------------------------------------------
# 3. discovered — .md present, not in registry
# ---------------------------------------------------------------------------
D="$(make_fixture)"
cat > "$D/agents/master-registry.json" <<'JSON'
{"version":1,"agents":[]}
JSON
agent_md "$D/agents/globe-specialist.md" "haiku"
assert_py "discovered: unwired .md -> discovered" '
r = m.reconcile(reg)
print("PASS" if r["discovered"]==["globe-specialist"] and not r["real"] and not r["ghost"] else r)
' "$D" "$D/agents/master-registry.json"

# ---------------------------------------------------------------------------
# 4. run() persists inventory; load_ghost_set + inventory read it back
# ---------------------------------------------------------------------------
D="$(make_fixture)"
cat > "$D/agents/master-registry.json" <<'JSON'
{"version":1,"agents":[{"id":"phantom","model":"opus"},{"id":"real-one","model":"sonnet"}]}
JSON
agent_md "$D/agents/real-one.md" "sonnet"
assert_py "run: persists inventory + ghost set" '
r = m.run(root, False)
inv = (root/".agent"/"state"/"agent-inventory.json")
gs = m.load_ghost_set(root)
print("PASS" if inv.is_file() and gs=={"phantom"} and r["real"]==["real-one"] else (r, gs, inv.is_file()))
' "$D" "$D/agents/master-registry.json"

# ---------------------------------------------------------------------------
# 5. --sync — additive wire-in copies model from frontmatter, no drift
# ---------------------------------------------------------------------------
D="$(make_fixture)"
cat > "$D/agents/master-registry.json" <<'JSON'
{"version":1,"agents":[{"id":"keep-me","model":"sonnet"}]}
JSON
agent_md "$D/agents/keep-me.md" "sonnet"
agent_md "$D/agents/new-prov.md" "opus"
assert_py "sync: additive wire-in, model from frontmatter, keeps existing" '
import json
before = json.load(open(reg))
r = m.run(root, True)   # do_sync=True
after = json.load(open(reg))
ids = {a["id"]: a.get("model") for a in after["agents"]}
kept = any(a["id"]=="keep-me" and a.get("model")=="sonnet" for a in after["agents"])
wired = ids.get("new-prov")=="opus"
reclassified = "new-prov" in r["real"] and not r["discovered"]
print("PASS" if kept and wired and reclassified and len(after["agents"])==2 else (ids, r))
' "$D" "$D/agents/master-registry.json"

# ---------------------------------------------------------------------------
# 6. fail-open — no registry anywhere -> empty verdict, no write, no crash
# ---------------------------------------------------------------------------
D="$(make_fixture)"
rm -f "$D/agents/master-registry.json" 2>/dev/null || true
assert_py "fail-open: no registry -> empty verdict" '
r = m.run(root, True)
inv = (root/".agent"/"state"/"agent-inventory.json")
empty = r=={"real":[],"ghost":[],"discovered":[]}
print("PASS" if empty and not inv.is_file() else (r, inv.is_file()))
' "$D" "$D/agents/nonexistent.json"

# ---------------------------------------------------------------------------
# 7. A filename is not evidence: only a .md with frontmatter defines an agent.
#    A stray README.md must not become `discovered` (--sync would wire it in as a
#    bogus agent), and a registry id backed by a frontmatter-less .md must land in
#    `ghost`, not `real` — the file exists, but the runtime cannot dispatch it, and
#    calling it real is exactly the ghost-specialist deadlock.
D7="$(make_fixture)"
cat > "$D7/agents/master-registry.json" <<'EOF'
{"version":1,"agents":[{"id":"hollow","description":"backed by a .md with no frontmatter"}]}
EOF
printf 'just prose, no frontmatter\n' > "$D7/agents/hollow.md"
printf '# Notes\nnot an agent\n'      > "$D7/agents/README.md"
assert_py "provider needs frontmatter: hollow -> ghost, README -> not discovered" '
r = m.reconcile(reg)
print("PASS" if r == {"real": [], "ghost": ["hollow"], "discovered": []} else r)
' "$D7" "$D7/agents/master-registry.json"

# 8. The CLI must fail open too — the module docstring promises exit 0 everywhere.
#    A malformed consumer registry (a bare string where an agent object belongs)
#    used to raise AttributeError out of reconcile(); the reconciler must never be
#    the thing that breaks the session.
D8="$(make_fixture)"
printf '{"version":1,"agents":["not an object"]}' > "$D8/agents/master-registry.json"
( cd "$D8" && git init -q . 2>/dev/null; python3 "$MOD" >/dev/null 2>&1 )
if [[ $? -eq 0 ]]; then ok "fail-open: malformed registry -> CLI exits 0"
else bad "fail-open: malformed registry -> CLI exited nonzero"; fi

# ---------------------------------------------------------------------------
printf '\nagent-inventory: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS — agent-inventory reconcile contract holds"
