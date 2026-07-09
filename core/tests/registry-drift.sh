#!/usr/bin/env bash
# registry-drift.sh — the registry/manifest structural gate, extracted verbatim
# (in behavior) from the .github/workflows/ci.yml `validate-plugin` job so the
# SAME four checks run locally, in verify-all.sh, and as the H-2 audit's registry
# item — one source of truth instead of logic living only inside CI YAML.
#
# The four drift classes (identical conditions + fail messages to the CI job):
#   1. plugin.json / marketplace.json required fields —
#        plugin.json must carry name/version/description/license;
#        marketplace.json must have a non-empty plugins[] whose first source is './'.
#   2. hooks.json command resolution — every hooks.json command's LAST token
#        (the core-hook filename) must exist under core/hooks/ AND be executable.
#   3. agents/*.md frontmatter — every agent markdown must carry a `name:` field in
#        its first 400 chars (a real, discoverable agent).
#   4. registry↔agent model drift — for every agents/master-registry.json entry,
#        agents/<id>.md must exist and its `model:` frontmatter must equal the
#        registry `model` (the two halves of the routing contract must agree).
#
# This is pillar-② (CI/CD structural enforcement) as a standalone script: the CI
# job becomes a thin caller, and the check is no longer un-runnable outside GitHub.
# Sibling self-integrity gates mirror this shape (REPO_ROOT derivation, a clear
# PASS/FAIL line, 0=clean / 1=drift): core/tests/doc-reality.sh,
# core/tests/sanitize-audit.sh, core/tests/supply-chain-scan.sh.
#
# Portability: pure python3 stdlib via a bash heredoc — no jq, no pip deps — so it
# runs identically on macOS and ubuntu. Paths are relative and resolved after a cd
# into the target root, so it works from ANY cwd (verify-all.sh runs it from a temp
# cwd; the H-2 audit runs it from wherever the agent sits).
#
# Test seam:
#   REGISTRY_DRIFT_ROOT   override the root operated on (default: the repo the
#                         script lives in). registry-drift-test.sh points this at a
#                         temp fixture to prove each drift class is actually caught.
#
# Usage:
#   bash core/tests/registry-drift.sh            # gate this repo (CI + local)
#   REGISTRY_DRIFT_ROOT=<dir> bash core/tests/registry-drift.sh   # gate a fixture
# Exit 0: manifests/hooks/agents/registry agree. Exit 1: drift found (prints each).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${REGISTRY_DRIFT_ROOT:-$REPO_ROOT}"

cd "$ROOT" || { echo "FAIL — registry-drift: cannot cd into root: $ROOT"; exit 1; }

python3 - <<'PY'
import json, os, sys, pathlib, re
fail = []

# 1) manifests are valid JSON with required fields
try:
    p = json.load(open(".claude-plugin/plugin.json"))
    for k in ("name", "version", "description", "license"):
        if not p.get(k): fail.append(f"plugin.json missing {k}")
except Exception as e:
    fail.append(f"plugin.json unreadable: {e}")

try:
    m = json.load(open(".claude-plugin/marketplace.json"))
    if not m.get("plugins"): fail.append("marketplace.json has no plugins[]")
    if m.get("plugins", [{}])[0].get("source") != "./":
        fail.append("marketplace.json plugin source must be './'")
except Exception as e:
    fail.append(f"marketplace.json unreadable: {e}")

# 2) every hooks.json command resolves to an existing executable core hook
try:
    h = json.load(open("hooks/hooks.json"))
    for event, groups in h["hooks"].items():
        for g in groups:
            for c in g["hooks"]:
                hook = c["command"].split()[-1]            # e.g. pre-tool-guard.sh
                path = pathlib.Path("core/hooks") / hook
                if not path.exists():
                    fail.append(f"hooks.json -> missing core/hooks/{hook}")
                elif not os.access(path, os.X_OK):
                    fail.append(f"hooks.json -> not executable core/hooks/{hook}")
except Exception as e:
    fail.append(f"hooks.json unreadable: {e}")

# 3) every agents/*.md carries a name: frontmatter (real, discoverable agents)
for a in pathlib.Path("agents").glob("*.md"):
    head = a.read_text(encoding="utf-8")[:400]
    if "name:" not in head:
        fail.append(f"agent without frontmatter: {a}")

# 4) registry model == agent .md model (drift guard — the two halves of
#    the routing contract must agree)
try:
    reg = json.load(open("agents/master-registry.json"))
    for entry in reg.get("agents", []):
        aid, rmodel = entry.get("id"), entry.get("model")
        md = pathlib.Path("agents") / f"{aid}.md"
        if not md.exists():
            fail.append(f"registry id '{aid}' has no agents/{aid}.md"); continue
        parts = md.read_text(encoding="utf-8").split("---", 2)
        mm = re.search(r"(?m)^model:\s*(\S+)", parts[1]) if len(parts) >= 3 else None
        mdmodel = mm.group(1) if mm else None
        if rmodel != mdmodel:
            fail.append(f"model drift: registry '{aid}'={rmodel} but agents/{aid}.md={mdmodel}")
except Exception as e:
    fail.append(f"master-registry.json unreadable: {e}")

if fail:
    print("FAIL — registry/manifest drift:")
    for f in fail: print("  -", f)
    sys.exit(1)
print("PASS — plugin manifests, hook refs, agent frontmatter, and registry↔agent models agree")
PY
