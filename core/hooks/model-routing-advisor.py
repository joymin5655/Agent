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

W6 effort note (docs/model-routing.md "The effort axis"): Claude's Agent tool
guidance is to set `effort` only when a user, skill or CLAUDE.md asks for it, so
a missing `effort` is NOT nudged on its own (that would train callers to ignore
this hook, including the real model-leak note). Only when the description or the
first 500 chars of the prompt names one of the five documented risk areas
(security, auth, concurrency, storage/database, migration) and `effort` is
missing/invalid does it add one short note: use `effort: high` if an effort
policy applies. Missing `model` + risk wording is ONE combined object, never
two. Registry-pinned specialists and Plan stay silent. Still advisory only: no
decision key, exit 0. The per-wave default table lives in skills/supervise.

Fail-safe: any exception is swallowed, malformed/empty stdin is silent, exit
is always 0 — a broken advisor must not tax or block a dispatch.

Seams: AGENT_REGISTRY_PATH (default <repo>/agents/master-registry.json).
Registered in docs/gate-registry.md (GATE model-routing-advisor).
"""

import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DISPATCH_TOOLS = {"Task", "Agent"}
# Plan's inherit is the documented default (docs/model-routing.md "Built-in
# agents": planning/architecture judgment), not the leak this advisor flags.
INTENTIONAL_INHERIT = {"Plan"}

EFFORT_LEVELS = {"low", "medium", "high", "xhigh", "max"}
# The five documented risk areas: security, auth, concurrency, storage/database,
# migration. Word boundaries so "author" is not "auth".
RISK_RE = re.compile(
    r"\b(security|auth|authentication|authorization|"
    r"concurrency|concurrent|race[ -]conditions?|deadlocks?|"
    r"storage|database|migrations?)\b",
    re.IGNORECASE,
)
PROMPT_SCAN_CHARS = 500

MODEL_PART = (
    "this dispatch has no call-time `model` override and "
    "subagent_type isn't a registry-pinned specialist.\n"
    "WHY: unpinned dispatches inherit the session's top model — "
    "docs/model-routing.md prices most work below TOP (implementation=MID, "
    "fan-out/lookups=LOW); a 2026-07-11 audit found 7/7 dispatches inheriting "
    "it silently.\n"
    "FIX: add `model` to the Task/Agent call for MID/LOW work, or proceed if "
    "session-top inherit is intended (e.g. Plan-shaped judgment)."
)
EFFORT_NOTE = (
    "`effort`: this dispatch names a risk area (security/auth/concurrency/"
    "storage/migration). If your plan, skill or CLAUDE.md sets an effort "
    "policy, use `effort: high`; otherwise ignore."
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


def emit_advisory(text):
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": text,
        }
    }
    sys.stdout.write(json.dumps(out))


def risk_text(tool_input):
    desc = tool_input.get("description", "")
    prompt = tool_input.get("prompt", "")
    desc = desc if isinstance(desc, str) else ""
    prompt = prompt if isinstance(prompt, str) else ""
    return desc + "\n" + prompt[:PROMPT_SCAN_CHARS]


def main():
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        return
    if event.get("tool_name") not in DISPATCH_TOOLS:
        return
    tool_input = event.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        return
    subagent_type = tool_input.get("subagent_type", "")
    if not isinstance(subagent_type, str) or not subagent_type.strip():
        return

    bare = subagent_type.rsplit(":", 1)[-1]
    if bare in INTENTIONAL_INHERIT:
        return  # Plan: inherit is the documented default, not a leak
    if bare in registry_ids():
        return  # registry-pinned specialist — frontmatter owns model + effort

    model = tool_input.get("model", "")
    model = model if isinstance(model, str) else ""
    effort = tool_input.get("effort", "")
    effort = effort.strip().lower() if isinstance(effort, str) else ""

    parts = []
    if not model.strip():
        parts.append(MODEL_PART)
    if effort not in EFFORT_LEVELS and RISK_RE.search(risk_text(tool_input)):
        parts.append(EFFORT_NOTE)
    if parts:
        emit_advisory("model-routing: " + "\n\n".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # advisor failure must never tax or block the dispatch
    sys.exit(0)
