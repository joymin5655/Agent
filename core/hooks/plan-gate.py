#!/usr/bin/env python3
"""PostToolUse hook — Plan-mode approval flag.

When the AI uses ExitPlanMode (Claude Code) OR completes a Plan-class Agent
dispatch, write a /tmp flag so subsequent Write/Edit can be permitted by the
supervisor enforcer.

W-8 source-first: memory fragments are triggers, not evidence. An ExitPlanMode
plan that cites memory but carries no live-source evidence (file:line or
command output) does not get the flag; spec-gate then asks before edits.

Hook protocol: reads canonical event JSON from stdin, writes empty stdout (allow).
Side-effect: writes /tmp/agent-plan-approved with timestamp.
"""

import json
import os
import pathlib
import re
import sys
from datetime import datetime

# Approval flag path. Overridable via AGENT_PLAN_FLAG so tests can exercise the
# gate against a throwaway path instead of clobbering the live session flag that
# spec-gate.py reads. Default is the shared /tmp location spec-gate expects.
PLAN_FLAG = pathlib.Path(os.environ.get("AGENT_PLAN_FLAG", "/tmp/agent-plan-approved"))

# Agent subagent_type values considered "plan-class"
PLAN_AGENT_TYPES = {"Plan", "plan", "Explore", "explore", "planner"}

# Description / prompt keyword heuristics (multilingual)
PLAN_DESCRIPTION_KEYWORDS = (
    "plan", "design", "architecture", "blueprint", "implementation",
    "구현 계획", "설계", "아키텍처", "구조",
)


# Memory-citation phrasing. Deliberately specific: bare "memory" (memory leak,
# memory usage) must not match.
MEMORY_CITATION = re.compile(
    r"\b(per|from|according to|based on|as noted in)\s+(my\s+|the\s+)?"
    r"(memory|memories|MEMORY\.md)\b"
    r"|\bmemory (says|notes?|states?|indicates?)\b"
    r"|\bI (recall|remember)\b|\bpreviously (noted|recorded)\b"
    r"|\bMEMORY\.md\b|\bbrain_(get|search|neighbors)\b"
    r"|메모리에\s*(따르면|의하면|기록)|기억(에|하기로)|이전에 기록",
    re.IGNORECASE,
)

# Live-source evidence: path:line reference, or a shell prompt line in a fence.
LIVE_EVIDENCE = re.compile(
    r"[\w./-]+\.[A-Za-z0-9]{1,6}:\d+"
    r"|^\s*\$ \S"
    r"|```[^\n]*\n\s*\$ ",
    re.MULTILINE,
)


def memory_only_plan(plan: str) -> bool:
    return bool(MEMORY_CITATION.search(plan)) and not LIVE_EVIDENCE.search(plan)


def is_plan_agent(data: dict) -> bool:
    tool_input = data.get("tool_input", {}) or {}

    subagent_type = tool_input.get("subagent_type", "")
    if subagent_type in PLAN_AGENT_TYPES:
        return True

    description = (tool_input.get("description") or "").lower()
    for keyword in PLAN_DESCRIPTION_KEYWORDS:
        if keyword in description:
            return True

    prompt = (tool_input.get("prompt") or "").lower()
    if "implementation plan" in prompt or "구현 계획" in prompt:
        return True

    return False


def main() -> None:
    try:
        data = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        return

    tool_name = data.get("tool_name", "")

    # ExitPlanMode = user-approved plan in Claude Code → write flag
    if tool_name == "ExitPlanMode":
        plan = (data.get("tool_input", {}) or {}).get("plan") or ""
        if isinstance(plan, str) and memory_only_plan(plan):
            try:
                PLAN_FLAG.unlink()
            except OSError:
                pass
            sys.stdout.write(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": (
                        "plan-gate: plan cites memory without live-source evidence; "
                        "approval flag withheld. Memory is a trigger, not proof - "
                        "re-verify each factual claim against the source (file:line "
                        "or command output) and re-submit the plan."
                    ),
                }
            }))
            return
        now = datetime.now().isoformat()
        try:
            PLAN_FLAG.write_text(f"approved at {now}", encoding="utf-8")
        except OSError:
            pass
        return

    # Agent tool — check if it's plan-class (Task/Agent per Claude Code version)
    if tool_name not in ("Agent", "Task"):
        return

    if is_plan_agent(data):
        now = datetime.now().isoformat()
        try:
            PLAN_FLAG.write_text(f"approved at {now}", encoding="utf-8")
        except OSError:
            pass


if __name__ == "__main__":
    main()
