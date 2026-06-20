#!/usr/bin/env python3
"""PreToolUse + PostToolUse + UserPromptSubmit hook — Supervisor stub.

The supervisor is the orchestrator that:
  1. Classifies user intent (FEATURE / MULTI_DEPT / SIMPLE_EDIT / QUERY / etc.)
  2. Matches intent to specialist agents from agents/master-registry.json
  3. Returns `ask` if a feature-class intent lacks specialist dispatch

This is the v0.1.0 minimal stub. The full registry-aware orchestrator (54KB+)
will be ported in v0.2.0 — see core/hooks/README.md roadmap. The port MUST follow
rules/policy/specialist-routing.md (domain-anchored matchers + ghost→executor fallback).

For v0.1.0, this stub:
  - Loads agents/master-registry.json (or .claude/agents/master-registry.json) if present
  - Logs the event to .agent/logs/supervisor.jsonl for telemetry
  - Always returns allow (empty stdout)

Project-specific routing can be implemented by editing this file or by adding
custom hooks alongside it.
"""

import json
import os
import pathlib
import subprocess
import sys
from datetime import datetime, timezone


def repo_root() -> pathlib.Path:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return pathlib.Path(out)
    except Exception:
        return pathlib.Path.cwd()


def find_registry(root: pathlib.Path):
    for p in (
        root / "agents" / "master-registry.json",
        root / ".claude" / "agents" / "master-registry.json",
        root / ".agent" / "agents" / "registry.json",
    ):
        if p.is_file():
            return p
    return None


def log_event(root: pathlib.Path, event: str, tool: str, intent: str = "") -> None:
    log_dir = root / ".agent" / "logs"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        return
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "tool_name": tool,
        "intent": intent,
        "session_id": os.environ.get("AGENT_SESSION_ID", "main"),
    }
    try:
        with open(log_dir / "supervisor.jsonl", "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def main() -> None:
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit(0)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    event = data.get("event", data.get("hook_event_name", ""))
    tool_name = data.get("tool_name", "")

    # v0.1.0 stub — observation only, no decision
    root = repo_root()
    log_event(root, event, tool_name)

    # Registry presence check (informational stderr — not blocking)
    registry = find_registry(root)
    if registry and os.environ.get("AGENT_SUPERVISOR_VERBOSE"):
        try:
            data_reg = json.loads(registry.read_text(encoding="utf-8"))
            count = len(data_reg.get("agents", []))
            print(f"[supervisor] {count} agents in registry", file=sys.stderr)
        except Exception:
            pass

    # Always allow in v0.1.0
    sys.exit(0)


if __name__ == "__main__":
    main()
