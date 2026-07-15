#!/usr/bin/env python3
"""SessionStart hook — surface project agent inventory.

On new session start, reads the project agent registry (agents/master-registry.json
or .claude/agents/registry.json) and emits a brief summary to stderr so the AI
knows which specialist agents are available.

Also cleans up per-session tmpfile flags from previous sessions.

Hook protocol: reads stdin (ignored), writes empty stdout (allow). Stderr is
informational and visible in the AI transcript.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
import pathlib
import subprocess
import types
from typing import Optional


def repo_root() -> pathlib.Path:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return pathlib.Path(out)
    except Exception:
        return pathlib.Path.cwd()


def find_registry(root: pathlib.Path) -> pathlib.Path | None:
    """Locate the project agent registry. Tries multiple conventional locations."""
    candidates = [
        root / "agents" / "master-registry.json",
        root / ".claude" / "agents" / "master-registry.json",
        root / ".claude" / "agents" / "registry.json",
        root / ".agent" / "agents" / "registry.json",
    ]
    for p in candidates:
        if p.is_file():
            return p
    return None


def cleanup_flags() -> None:
    """Remove per-session tmpfile flags so old state doesn't leak across sessions."""
    flags = [
        "/tmp/agent-intent-feature",
        "/tmp/agent-plan-approved",
        "/tmp/agent-harness-mode",
        "/tmp/agent-required-agents",
        "/tmp/agent-dispatched-agents",
    ]
    for flag in flags:
        try:
            pathlib.Path(flag).unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass


def check_env() -> None:
    """Warn (stderr only) when recommended external tools are missing.

    A mini env-doctor: absent gitleaks/git degrades the secret-scan git hooks.
    Never blocks the session and never writes stdout (hook protocol).
    """
    try:
        missing = [t for t in ("gitleaks", "git") if shutil.which(t) is None]
        if missing:
            print(
                f"[agent-harness] WARN: {', '.join(missing)} not found — "
                "secret-scan git hooks will be skipped. Install: brew install gitleaks",
                file=sys.stderr,
            )
    except Exception:
        pass


def _load_inventory_module() -> Optional[types.ModuleType]:
    """Load the hyphen-named agent-inventory.py sibling (not importable by name)."""
    path = pathlib.Path(__file__).with_name("agent-inventory.py")
    if not path.is_file():
        return None
    try:
        spec = importlib.util.spec_from_file_location("agent_inventory", path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


def reconcile_inventory(root: pathlib.Path) -> None:
    """Session-start truth pass: quarantine ghost specialists, persist inventory.

    Fail-open: any error here is swallowed — reconciling the registry must never
    block a session. Auto-sync of discovered providers is opt-in
    (AGENT_REGISTRY_AUTOSYNC=1); the default is verify-and-quarantine only.
    """
    mod = _load_inventory_module()
    if mod is None:
        return
    try:
        do_sync = os.environ.get("AGENT_REGISTRY_AUTOSYNC") == "1"
        result = mod.run(root, do_sync)
    except Exception:
        return
    ghost = result.get("ghost") or []
    if ghost:
        print(
            "[agent-harness] WARN: {} registry specialist(s) have no provider "
            "and were quarantined (nothing will demand them): {}".format(
                len(ghost), ", ".join(ghost)
            ),
            file=sys.stderr,
        )
    discovered = result.get("discovered") or []
    if discovered and not os.environ.get("AGENT_REGISTRY_AUTOSYNC") == "1":
        print(
            "[agent-harness] note: {} unwired provider .md file(s) found: {} "
            "(run `python3 core/hooks/agent-inventory.py --sync` to register)".format(
                len(discovered), ", ".join(discovered)
            ),
            file=sys.stderr,
        )


def main() -> None:
    check_env()

    # Drain stdin (the AI sends event JSON; we don't need it for init)
    try:
        sys.stdin.read()
    except Exception:
        pass

    cleanup_flags()

    root = repo_root()
    reg_path = find_registry(root)
    if not reg_path:
        return

    try:
        data = json.loads(reg_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return

    agent_list = data.get("agents") or []
    if not agent_list:
        return

    names = [a.get("id", a.get("name", "?")) for a in agent_list[:12]]
    suffix = " ..." if len(agent_list) > 12 else ""
    print(
        f"[Agent session init] {len(agent_list)} agents loaded: {', '.join(names)}{suffix}",
        file=sys.stderr,
    )

    # Evidence-first: reconcile the registry against real providers, quarantine
    # ghosts, and persist .agent/state/agent-inventory.json for supervisor.py.
    reconcile_inventory(root)


if __name__ == "__main__":
    main()
