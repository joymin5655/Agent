#!/usr/bin/env python3
"""PostToolUse hook that records Plan/ExitPlanMode evidence."""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import sys

PROJECT_ROOT = Path(os.environ.get("AGENT_HARNESS_PROJECT_ROOT", Path.cwd())).resolve()
PLAN_FLAG = Path(os.environ.get("AGENT_HARNESS_PLAN_FLAG", PROJECT_ROOT / ".agent-harness/state/plan-approved"))

PLAN_AGENT_TYPES = {"Plan", "plan", "Explore", "explore", "planner"}
PLAN_DESCRIPTION_KEYWORDS = ("plan", "architecture", "design", "blueprint", "implementation plan", "구현 계획", "설계")


def is_plan_agent(data: dict) -> bool:
    tool_input = data.get("tool_input", {})
    subagent_type = tool_input.get("subagent_type", "")
    if subagent_type in PLAN_AGENT_TYPES:
        return True
    haystack = f"{tool_input.get('description', '')}\n{tool_input.get('prompt', '')}".lower()
    return any(keyword.lower() in haystack for keyword in PLAN_DESCRIPTION_KEYWORDS)


def mark_plan() -> None:
    PLAN_FLAG.parent.mkdir(parents=True, exist_ok=True)
    PLAN_FLAG.write_text(f"approved at {datetime.now().isoformat()}", encoding="utf-8")


def main() -> None:
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print(raw, end="")
        return

    tool_name = data.get("tool_name", "")
    if tool_name == "ExitPlanMode" or (tool_name in {"Agent", "Task"} and is_plan_agent(data)):
        mark_plan()
    print(raw, end="")


if __name__ == "__main__":
    main()
