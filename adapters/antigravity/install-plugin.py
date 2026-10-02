#!/usr/bin/env python3
"""Install (or remove) Agent's Antigravity native-hook plugin folder.

Usage: install-plugin.py --root <framework root> [--target <plugin dir>]
                         [--uninstall | --check] [--dry-run]

agy loads hooks from a plugin folder holding plugin.json + hooks.json
(w5-design M1). The default target is $AGENT_ANTIGRAVITY_PLUGIN_DIR or
~/.gemini/config/plugins/agent-harness. This script owns exactly those two
files in that one folder: it never reads or writes ~/.gemini/config/hooks.json
or ~/.gemini/antigravity-cli/settings.json, and it refuses a folder whose
plugin.json is not ours (a small marker file keeps a folder ours after an uninstall that
left a user file behind). Writes are atomic and skipped when content is
identical. Exit: 0 ok, 1 refused/error, 2 usage. --check prints NONE,
"BROKEN <why>" or "OK" for setup.sh --doctor.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

PLUGIN_NAME = "agent-harness"
ADAPTER_REL = "adapters/antigravity/adapter.sh"
EXPECTED_EVENTS = ("PreToolUse", "PostToolUse", "Stop")
# Written next to plugin.json so a folder we half-uninstalled (a user file kept inside)
# stays recognizably ours: without it that folder is "non-empty, no plugin.json" and
# every later install / uninstall / setup.sh --antigravity refuses it forever.
MARKER = ".agent-harness-owned"
# The root lands inside a double-quoted shell word in each hook command.
UNSAFE_ROOT_CHARS = set('"`$\\')


def default_target() -> str:
    return os.environ.get("AGENT_ANTIGRAVITY_PLUGIN_DIR") or os.path.join(
        os.path.expanduser("~"), ".gemini", "config", "plugins", PLUGIN_NAME)


def check_root(root: str) -> str | None:
    """Return a refusal reason, or None when the root is safe to embed."""
    if not os.path.isabs(root):
        return f"framework root {root!r} is not an absolute path"
    if any(c in UNSAFE_ROOT_CHARS or ord(c) < 32 or ord(c) == 127 for c in root):
        return (f"framework root {root!r} contains a quote, newline or other shell-active "
                "character; move the checkout to a plain path")
    if not os.path.isfile(os.path.join(root, ADAPTER_REL)):
        return f"{os.path.join(root, ADAPTER_REL)} does not exist"
    return None


def render(root: str) -> tuple[str, str]:
    adir = os.path.join(root, "adapters", "antigravity")
    with open(os.path.join(adir, "plugin.json")) as f:
        manifest = f.read()
    with open(os.path.join(adir, "hooks.json.template")) as f:
        hooks = json.load(f)

    def sub(node):
        if isinstance(node, dict):
            return {k: sub(v) for k, v in node.items()}
        if isinstance(node, list):
            return [sub(v) for v in node]
        if isinstance(node, str):
            return node.replace("{{FRAMEWORK_ROOT}}", root)
        return node

    return manifest, json.dumps(sub(hooks), indent=2) + "\n"


def _read_json(path: str):
    with open(path) as f:
        return json.load(f)


def ownership(target: str) -> str | None:
    """None when the folder is absent/empty/ours, else the refusal reason."""
    real = os.path.realpath(target)
    if not os.path.lexists(target):
        return None
    if not os.path.isdir(real):
        return f"{target} exists and is not a directory"
    manifest = os.path.join(real, "plugin.json")
    if not os.path.exists(manifest):
        if not os.listdir(real) or os.path.exists(os.path.join(real, MARKER)):
            return None
        return f"{target} is non-empty and has no plugin.json"
    try:
        name = _read_json(manifest).get("name")
    except (OSError, ValueError, AttributeError):
        return f"{manifest} is not a readable plugin manifest"
    if name != PLUGIN_NAME:
        return f"{target} holds a foreign plugin (name {name!r}), not {PLUGIN_NAME!r}"
    return None


def _atomic_write(path: str, data: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def install(root: str, target: str, dry_run: bool) -> int:
    reason = check_root(root) or ownership(target)
    if reason:
        print(f"  ERROR: {reason}; nothing written", file=sys.stderr)
        return 1
    manifest, hooks = render(root)
    real = os.path.realpath(target)
    for fname, data in (("plugin.json", manifest), ("hooks.json", hooks), (MARKER, "")):
        path = os.path.join(real, fname)
        try:
            with open(path) as f:
                same = f.read() == data
        except OSError:
            same = False
        shown = os.path.join(target, fname)
        if same:
            print(f"  up-to-date: {shown}")
        elif dry_run:
            print(f"  would write: {shown}")
        else:
            os.makedirs(real, exist_ok=True)
            _atomic_write(path, data)
            print(f"  installed: {shown}")
    return 0


def uninstall(target: str, dry_run: bool) -> int:
    reason = ownership(target)
    if reason:
        print(f"  ERROR: {reason}; nothing removed", file=sys.stderr)
        return 1
    real = os.path.realpath(target)
    if not os.path.isdir(real):
        print(f"  not installed: {target}")
        return 0
    for fname in ("hooks.json", "plugin.json"):
        path = os.path.join(real, fname)
        if os.path.exists(path):
            print(f"  {'would remove' if dry_run else 'removed'}: {os.path.join(target, fname)}")
            if not dry_run:
                os.unlink(path)
    if dry_run:
        return 0
    marker = os.path.join(real, MARKER)
    if os.listdir(real) == [MARKER]:
        os.unlink(marker)  # nothing of the user's left: the marker goes with the folder
    if not os.listdir(real) and not os.path.islink(target):
        os.rmdir(real)
    elif os.listdir(real):
        print(f"  kept {target}: it holds files this installer does not own")
    return 0


def check(target: str) -> int:
    real = os.path.realpath(target)
    manifest = os.path.join(real, "plugin.json")
    try:
        ours = _read_json(manifest).get("name") == PLUGIN_NAME
    except (OSError, ValueError, AttributeError):
        ours = False
    if not ours:
        print("NONE")
        return 0
    try:
        sets = _read_json(os.path.join(real, "hooks.json"))[PLUGIN_NAME]
        events = {ev: sets[ev] for ev in EXPECTED_EVENTS}
    except (OSError, ValueError, KeyError, TypeError):
        print("BROKEN hooks.json missing, unreadable or without the expected events")
        return 0
    cmds: list[str] = []
    for entries in events.values():
        for e in entries if isinstance(entries, list) else []:
            for h in (e.get("hooks") or [e]) if isinstance(e, dict) else []:
                if isinstance(h, dict) and isinstance(h.get("command"), str):
                    cmds.append(h["command"])
    paths = sorted({c.split('"')[1] for c in cmds if c.count('"') >= 2})
    if len(paths) != 1:
        print("BROKEN hook commands do not point at one quoted adapter path")
        return 0
    if not (os.path.isfile(paths[0]) and os.access(paths[0], os.X_OK)):
        print(f"BROKEN {paths[0]} is missing or not executable")
        return 0
    print(f"OK {len(cmds)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root")
    ap.add_argument("--target")
    ap.add_argument("--uninstall", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    target = args.target or default_target()
    if args.check:
        return check(target)
    if args.uninstall:
        return uninstall(target, args.dry_run)
    if not args.root:
        ap.error("--root is required")
    return install(args.root, target, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
