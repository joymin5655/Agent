#!/usr/bin/env python3
"""model-routing-advisor.py — decision-time nudge for the model-tier convention.

Matcher: PreToolUse Task|Agent (fires on the way OUT of the dispatch, unlike
model-routing-observer.py's PostToolUse, which measures after the fact).

model-routing-observer.py measures the leak this advisor exists to interrupt:
a 2026-07-11 transcript audit found 7/7 subagent dispatches at inherit_top —
no call-time `model` override, no registry pin, the session's top model used
silently for work docs/model-routing.md prices at MID or LOW (implementation,
fan-out). Post-hoc measurement doesn't change behavior; a reminder at the
decision point might.

Emits ONE line of hookSpecificOutput.additionalContext when a dispatch is
about to leak: no `model` override on this call, subagent_type does not
resolve to a registry-pinned specialist, and subagent_type isn't "Plan"
(Plan's inherit is the documented exception — docs/model-routing.md "Built-in
agents": planning/architecture judgment is meant to inherit TOP). Every other
case is silent.

Deliberately NOT enforcement: never sets permissionDecision, never blocks,
never switches a model, and writes no log of its own — model-routing-observer's
sink stays the sole record (a second, divergent count would just be more
noise). This sits inside the line docs/model-routing.md draws in "What this
policy deliberately does not do": a runtime model-switcher was evaluated and
rejected; a deterministic reminder at the decision point, with the decision
still made by the caller, is not that.

Fail-safe: any exception is swallowed, malformed/empty stdin is silent, exit
is always 0 — a broken advisor must not tax or block a dispatch.

Seams: AGENT_REGISTRY_PATH (default <repo>/agents/master-registry.json).
Registered in docs/gate-registry.md (GATE model-routing-advisor).
"""

import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DISPATCH_TOOLS = {"Task", "Agent"}
# Plan's inherit is the documented default (docs/model-routing.md "Built-in
# agents": planning/architecture judgment), not the leak this advisor flags.
INTENTIONAL_INHERIT = {"Plan"}

ADVISORY = (
    "model-routing: this dispatch has no call-time `model` override and "
    "subagent_type isn't a registry-pinned specialist.\n"
    "WHY: unpinned dispatches inherit the session's top model — "
    "docs/model-routing.md prices most work below TOP (implementation=MID, "
    "fan-out/lookups=LOW); a 2026-07-11 audit found 7/7 dispatches inheriting "
    "it silently.\n"
    "FIX: add `model` to the Task/Agent call for MID/LOW work, or proceed if "
    "session-top inherit is intended (e.g. Plan-shaped judgment)."
)


def registry_ids():
    path = os.environ.get("AGENT_REGISTRY_PATH") or os.path.join(
        REPO_ROOT, "agents", "master-registry.json"
    )
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        agents = data.get("agents", data) if isinstance(data, dict) else data
        return {a.get("id", "") for a in agents if isinstance(a, dict)} - {""}
    except Exception:
        return set()


def emit_advisory():
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": ADVISORY,
        }
    }
    sys.stdout.write(json.dumps(out))


def main():
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        return
    if event.get("tool_name") not in DISPATCH_TOOLS:
        return
    tool_input = event.get("tool_input") or {}
    subagent_type = tool_input.get("subagent_type", "")
    if not isinstance(subagent_type, str) or not subagent_type.strip():
        return
    model = tool_input.get("model", "")
    model = model if isinstance(model, str) else ""
    if model.strip():
        return  # explicit override — caller already made the tier call

    bare = subagent_type.rsplit(":", 1)[-1]
    if bare in INTENTIONAL_INHERIT:
        return  # Plan: inherit is the documented default, not a leak
    if bare in registry_ids():
        return  # registry-pinned specialist — frontmatter owns the tier

    emit_advisory()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # advisor failure must never tax or block the dispatch
    sys.exit(0)
