#!/usr/bin/env bash
# hook-template-parity.sh — the hook-manifest drift gate.
#
# Usage:
#   bash core/tests/hook-template-parity.sh                       # gate this repo
#   bash core/tests/hook-template-parity.sh <hooks.json> <tmpl>   # arbitrary pair (test seam)
#
# Exit 0: inventories match. Exit 1: drift (prints per-event/matcher diff).
#
# Why: the same hook chain ships twice — hooks/hooks.json (plugin install path,
# ${CLAUDE_PLUGIN_ROOT} prefix) and adapters/claude-code/settings.json.template
# (shell install path, {{FRAMEWORK_ROOT}} prefix). Before this gate the two had
# silently diverged by six hooks (spec-gate, plan-scope-allow,
# model-routing-observer, rubric-commit-judge, secret-content-scan on the
# WebFetch/MCP matcher, and a stale plan-gate on UserPromptSubmit), so the two
# install paths enforced different chains. hooks/hooks.json is the SSOT.
#
# Normalization: for every wired hook, take the command's LAST whitespace token
# and strip its directory — the core-hook filename the adapter dispatches. This
# erases both path-prefix conventions identically (same extraction the doctor's
# hooks.json check uses). Comparison is exact per (event, matcher), including
# hook ORDER within a matcher — chain order is behavior (e.g. quality gate
# before session close).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_JSON="${1:-$REPO_ROOT/hooks/hooks.json}"
TEMPLATE="${2:-$REPO_ROOT/adapters/claude-code/settings.json.template}"

python3 - "$HOOKS_JSON" "$TEMPLATE" <<'EOF'
import json, sys

def inventory(path):
    with open(path) as f:
        data = json.load(f)
    inv = {}
    for event, groups in data.get("hooks", {}).items():
        if event.startswith("_"):
            continue
        for g in groups:
            matcher = g.get("matcher", "*")
            # Assumes every wired command is "<prefixed-adapter-path> <hook-name>"
            # with no trailing args (true for the whole current chain); a future
            # entry with trailing flags would need a smarter extraction.
            names = [
                h.get("command", "").split()[-1].rsplit("/", 1)[-1].strip('"')
                for h in g.get("hooks", [])
            ]
            inv.setdefault(event, {})[matcher] = names
    return inv

try:
    plugin = inventory(sys.argv[1])
    template = inventory(sys.argv[2])
except (OSError, json.JSONDecodeError) as e:
    print(f"FAIL — cannot read/parse manifest: {e}")
    sys.exit(1)

if plugin == template:
    total = sum(len(v) for ev in plugin.values() for v in ev.values())
    print(f"PASS — hook inventories match ({total} wirings across {len(plugin)} events)")
    sys.exit(0)

print("FAIL — hook inventory drift between plugin manifest and settings template:")
for ev in sorted(set(plugin) | set(template)):
    pa, ta = plugin.get(ev, {}), template.get(ev, {})
    for m in sorted(set(pa) | set(ta)):
        if pa.get(m) != ta.get(m):
            print(f"  [{ev}] matcher: {m}")
            print(f"    hooks.json        : {pa.get(m)}")
            print(f"    settings template : {ta.get(m)}")
print("")
print("hooks/hooks.json is the SSOT — mirror the change into the template (or vice versa).")
sys.exit(1)
EOF
