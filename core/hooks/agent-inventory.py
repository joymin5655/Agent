#!/usr/bin/env python3
"""Agent-inventory reconciler — the session-start truth pass for specialist providers.

Evidence-first (rules/policy/evidence-first.md): nothing downstream may demand a
specialist that has no in-session provider. The CI drift guard
(core/tests/registry-drift.sh, check 4) enforces `registry id -> agents/<id>.md`
for the *shipped* repo, but a consumer project can override the registry
(.claude/agents/master-registry.json / .agent/agents/registry.json) with entries
CI never saw. That is exactly how a ghost specialist reaches a live session and
deadlocks it: a gate requires an agent the runtime can't dispatch.

This module reconciles the *active* registry against the agent `*.md` providers
actually sitting next to it, every session start:

  - real       : registry ids WITH a sibling <id>.md (a dispatchable provider)
  - ghost       : registry ids WITHOUT one (quarantined — never demandable)
  - discovered : <id>.md files present but NOT in the registry (unwired providers)

It writes the verdict to .agent/state/agent-inventory.json (gitignored runtime
state — never shipped, never git churn, no drift-guard conflict). supervisor.py
consumes the `ghost` set as an extra quarantine source, fail-open.

Hybrid auto-correct (opt-in): with --sync (or AGENT_REGISTRY_AUTOSYNC=1) the
reconciler additively wires discovered providers into the registry, copying each
`model:` straight from the agent's own frontmatter — so the additive write can
never introduce the model drift that check 4 forbids. It only ADDS; it never
removes or rewrites an existing entry.

Usable three ways:
  1. imported by session-init.py (SessionStart) — reconcile + write inventory
  2. imported by supervisor.py — load_ghost_set() for dispatch-time quarantine
  3. CLI: `python3 core/hooks/agent-inventory.py [--sync]` — manual report / sync

Fail-open everywhere: a broken registry, unreadable frontmatter, or an
unwritable state dir must never break a session (return empties, exit 0).
Python 3.9 compatible; stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Dict, List, Optional

MODEL_RE = re.compile(r"(?m)^model:\s*(\S+)")


def repo_root() -> pathlib.Path:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return pathlib.Path(out)
    except Exception:
        return pathlib.Path.cwd()


def find_registry(root: pathlib.Path) -> Optional[pathlib.Path]:
    """Locate the active registry — same precedence supervisor.py uses."""
    for p in (
        root / "agents" / "master-registry.json",
        root / ".claude" / "agents" / "master-registry.json",
        root / ".agent" / "agents" / "registry.json",
    ):
        if p.is_file():
            return p
    return None


def load_registry(path: pathlib.Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {"agents": []}


def frontmatter_model(md_path: pathlib.Path) -> Optional[str]:
    """The `model:` value from an agent .md frontmatter, or None."""
    try:
        parts = md_path.read_text(encoding="utf-8").split("---", 2)
    except Exception:
        return None
    if len(parts) < 3:
        return None
    m = MODEL_RE.search(parts[1])
    return m.group(1) if m else None


def is_provider(md_path: pathlib.Path) -> bool:
    """A provider is a .md that actually *defines an agent* — i.e. carries YAML
    frontmatter. Filename alone is not evidence: a README.md or NOTES.md sitting
    in the registry dir is not a dispatchable agent, and treating it as one would
    (a) mark a registry id "real" that the runtime cannot dispatch — the very
    ghost-specialist deadlock this module exists to prevent — and (b) let --sync
    wire the stray file into the registry as a bogus agent.

    Unreadable or frontmatter-less -> False, which routes the id to `ghost`
    (quarantined, never demanded). Erring toward ghost is the fail-open direction.
    """
    try:
        text = md_path.read_text(encoding="utf-8")
    except Exception:
        return False
    return text.lstrip().startswith("---") and len(text.split("---", 2)) >= 3


def reconcile(registry_path: pathlib.Path) -> Dict[str, List[str]]:
    """Classify the active registry against the provider .md files beside it.

    Returns sorted lists: real (id has a sibling .md), ghost (id has none),
    discovered (a .md exists that no registry id claims).
    """
    reg = load_registry(registry_path)
    reg_dir = registry_path.parent
    registry_ids = [
        a.get("id", "") for a in reg.get("agents", []) if a.get("id")
    ]
    provider_ids = {
        p.stem for p in reg_dir.glob("*.md") if p.stem and is_provider(p)
    }

    real = sorted(i for i in registry_ids if i in provider_ids)
    ghost = sorted(i for i in registry_ids if i not in provider_ids)
    discovered = sorted(provider_ids - set(registry_ids))
    return {"real": real, "ghost": ghost, "discovered": discovered}


def inventory_path(root: pathlib.Path) -> pathlib.Path:
    return root / ".agent" / "state" / "agent-inventory.json"


def write_inventory(root: pathlib.Path, result: Dict[str, List[str]]) -> bool:
    """Atomically persist the reconcile verdict. Returns False on any failure."""
    p = inventory_path(root)
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "real": result["real"],
        "ghost": result["ghost"],
        "discovered": result["discovered"],
    }
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, p)  # atomic — a torn write must never corrupt the truth file
        return True
    except Exception:
        return False


def load_ghost_set(root: pathlib.Path) -> set:
    """Ghost ids from the last reconcile — supervisor.py's extra quarantine source.

    Fail-open: absent/broken inventory yields an empty set, so a session with no
    inventory behaves exactly as before this module existed.
    """
    try:
        data = json.loads(inventory_path(root).read_text(encoding="utf-8"))
        return set(data.get("ghost") or [])
    except Exception:
        return set()


def sync_registry(
    registry_path: pathlib.Path, discovered: List[str]
) -> List[str]:
    """Additively wire discovered providers into the registry (opt-in).

    Adds a minimal entry per discovered <id>.md, copying `model:` from the agent's
    own frontmatter so no model drift is introduced. Never removes or edits an
    existing entry. Returns the ids actually added. Fail-open: returns [] on error.
    """
    if not discovered:
        return []
    try:
        reg = load_registry(registry_path)
        existing = {a.get("id") for a in reg.get("agents", [])}
        added: List[str] = []
        for aid in discovered:
            if aid in existing:
                continue
            model = frontmatter_model(registry_path.parent / (aid + ".md"))
            entry = {
                "id": aid,
                "description": "(auto-synced from agents/{}.md)".format(aid),
                "matches": {"keywords": [], "tools": [], "file_globs": []},
                "aliases": [],
                "memory_scope": "local",
            }
            if model:
                entry["model"] = model
            reg.setdefault("agents", []).append(entry)
            added.append(aid)
        if not added:
            return []
        tmp = registry_path.with_name(registry_path.name + ".tmp")
        tmp.write_text(json.dumps(reg, indent=2) + "\n", encoding="utf-8")
        os.replace(tmp, registry_path)
        return added
    except Exception:
        return []


def run(root: pathlib.Path, do_sync: bool) -> Dict[str, List[str]]:
    """Session-start entry point: reconcile, optionally auto-sync, persist truth.

    Returns the (post-sync) reconcile verdict. Safe to call when no registry
    exists — yields empty lists and writes nothing.
    """
    registry_path = find_registry(root)
    if registry_path is None:
        empty: Dict[str, List[str]] = {"real": [], "ghost": [], "discovered": []}
        return empty

    result = reconcile(registry_path)
    if do_sync and result["discovered"]:
        added = sync_registry(registry_path, result["discovered"])
        if added:
            result = reconcile(registry_path)  # re-classify after the additive write
    write_inventory(root, result)
    return result


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reconcile the agent registry against real .md providers."
    )
    parser.add_argument(
        "--sync",
        action="store_true",
        help="additively wire discovered providers into the registry (opt-in)",
    )
    args = parser.parse_args(argv)

    do_sync = args.sync or os.environ.get("AGENT_REGISTRY_AUTOSYNC") == "1"
    root = repo_root()
    try:
        result = run(root, do_sync)
    except Exception as exc:
        # Fail-open, as the module docstring promises. A malformed consumer
        # registry (e.g. a bare string where an agent object belongs) must not
        # make the reconciler the thing that breaks the session.
        print("agent-inventory: reconcile failed ({}) — no quarantine written".format(exc),
              file=sys.stderr)
        return 0

    print("agent-inventory @ {}".format(root))
    print("  real       ({}): {}".format(len(result["real"]), ", ".join(result["real"]) or "-"))
    print("  ghost      ({}): {}".format(len(result["ghost"]), ", ".join(result["ghost"]) or "-"))
    print("  discovered ({}): {}".format(len(result["discovered"]), ", ".join(result["discovered"]) or "-"))
    if result["ghost"]:
        print("  -> ghost ids are quarantined: nothing will demand them (evidence-first).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
