#!/usr/bin/env python3
"""PostToolUse hook — Plan-mode approval flag.

When the AI uses ExitPlanMode (Claude Code) OR completes a Plan-class Agent
dispatch, write a /tmp flag so subsequent Write/Edit can be permitted by the
supervisor enforcer.

Hook protocol: reads canonical event JSON from stdin, writes empty stdout (allow).
Side-effect: writes /tmp/agent-plan-approved with timestamp.
"""

import json
import pathlib
import sys
from datetime import datetime

PLAN_FLAG = pathlib.Path("/tmp/agent-plan-approved")

# Agent subagent_type values considered "plan-class"
PLAN_AGENT_TYPES = {"Plan", "plan", "Explore", "explore", "planner"}

# Description / prompt keyword heuristics (multilingual)
PLAN_DESCRIPTION_KEYWORDS = (
    "plan", "design", "architecture", "blueprint", "implementation",
    "구현 계획", "설계", "아키텍처", "구조",
)


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
        now = datetime.now().isoformat()
        try:
            PLAN_FLAG.write_text(f"approved at {now}", encoding="utf-8")
        except OSError:
            pass
        return

    # Agent tool — check if it's plan-class
    if tool_name != "Agent":
        return

    if is_plan_agent(data):
        now = datetime.now().isoformat()
        try:
            PLAN_FLAG.write_text(f"approved at {now}", encoding="utf-8")
        except OSError:
            pass


if __name__ == "__main__":
    main()
