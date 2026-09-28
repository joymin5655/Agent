#!/usr/bin/env python3
"""Merge Agent's Codex native hooks into a hooks.json without touching others.

Usage: merge-hooks.py <hooks.json.template> <framework-root> <target hooks.json>

Other tools register hooks in the same ~/.codex/hooks.json, so this never
overwrites it: every hook entry whose command runs adapters/codex/adapter.sh
(any checkout path) is Agent-owned and replaced by the rendered template; all
other entries, groups, and top-level keys are kept in place. A group left empty
by the removal is dropped. Prints one status line; exits 1 on unreadable input.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

OWNED_MARKER = "/adapters/codex/adapter.sh"
# The root lands inside a double-quoted shell word in each hook command.
UNSAFE_ROOT_CHARS = set('"`$\\\n')


def _owned(hook: dict) -> bool:
    return OWNED_MARKER in str(hook.get("command", ""))


def merge(existing: dict, rendered: dict) -> dict:
    out = dict(existing)
    hooks = {ev: list(groups) for ev, groups in (existing.get("hooks") or {}).items()}
    for ev, groups in list(hooks.items()):
        kept = []
        for g in groups:
            rest = [h for h in g.get("hooks", []) if not _owned(h)]
            if rest:
                kept.append(dict(g, hooks=rest))
            elif not g.get("hooks"):
                kept.append(g)
        hooks[ev] = kept
    for ev, groups in rendered["hooks"].items():
        hooks.setdefault(ev, []).extend(groups)
    out["hooks"] = {ev: groups for ev, groups in hooks.items() if groups}
    return out


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    template, root, target = sys.argv[1:]
    if UNSAFE_ROOT_CHARS & set(root):
        print(f"  ERROR: checkout path {root!r} contains a shell-active character; move the "
              "checkout to a plain path — hooks.json left untouched", file=sys.stderr)
        return 1
    with open(template) as f:
        rendered = json.loads(f.read())
    for groups in rendered["hooks"].values():
        for g in groups:
            for h in g["hooks"]:
                h["command"] = h["command"].replace("{{FRAMEWORK_ROOT}}", root)
    existing: dict = {}
    if os.path.exists(target):
        try:
            with open(target) as f:
                existing = json.load(f)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"  ERROR: {target} is not valid JSON ({exc}); left untouched", file=sys.stderr)
            return 1
        if not isinstance(existing, dict):
            print(f"  ERROR: {target} is not a JSON object; left untouched", file=sys.stderr)
            return 1
    rendered.pop("description", None)
    merged = merge(existing, rendered)
    if merged == existing:
        print(f"  up-to-date: {target}")
        return 0
    # Write through a symlinked hooks.json (dotfile setups) atomically.
    real = os.path.realpath(target)
    os.makedirs(os.path.dirname(real) or ".", exist_ok=True)
    if existing:
        shutil.copy2(real, target + ".bak")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real) or ".", prefix=".hooks.json.")
    with os.fdopen(fd, "w") as f:
        json.dump(merged, f, indent=2)
        f.write("\n")
    os.replace(tmp, real)
    kept = sum(1 for gs in merged["hooks"].values() for g in gs for h in g.get("hooks", []) if not _owned(h))
    note = f" (kept {kept} non-Agent hook(s); backup {os.path.basename(target)}.bak)" if existing else ""
    print(f"  installed: {target}{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
