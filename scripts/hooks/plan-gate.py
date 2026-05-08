#!/usr/bin/env python3
"""PostToolUse [Agent] — Plan 완료 플래그 설정.

Agent 도구 실행 후 Plan 관련 에이전트였으면 /tmp/airlens-plan-approved 생성.
supervisor-enforcer.py가 이 플래그를 확인하여 Write/Edit 허용.
"""

import json
import os
import pathlib
import sys
from datetime import datetime

PLAN_FLAG = pathlib.Path("/tmp/airlens-plan-approved")
INTENT_FLAG = pathlib.Path("/tmp/airlens-intent-feature")

# Plan 완료로 간주하는 에이전트 타입/설명 패턴
PLAN_AGENT_TYPES = {"Plan", "plan", "Explore", "explore", "planner"}

PLAN_DESCRIPTION_KEYWORDS = (
    "plan", "설계", "구현 계획", "아키텍처", "architecture",
    "design", "구조", "blueprint",
)


def is_plan_agent(data: dict) -> bool:
    """Agent 도구 호출이 Plan 관련인지 판정."""
    tool_input = data.get("tool_input", {})

    # subagent_type으로 판정
    subagent_type = tool_input.get("subagent_type", "")
    if subagent_type in PLAN_AGENT_TYPES:
        return True

    # description으로 판정
    description = tool_input.get("description", "").lower()
    for keyword in PLAN_DESCRIPTION_KEYWORDS:
        if keyword in description:
            return True

    # prompt에 Plan 모드 진입 관련 내용 있는지
    prompt = tool_input.get("prompt", "").lower()
    if "implementation plan" in prompt or "구현 계획" in prompt:
        return True

    return False


def main() -> None:
    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print(raw, end="")
        return

    tool_name = data.get("tool_name", "")

    # ExitPlanMode = Plan Mode에서 사용자 승인 완료 → 플래그 생성
    if tool_name == "ExitPlanMode":
        now = datetime.now().isoformat()
        PLAN_FLAG.write_text(f"approved at {now}", encoding="utf-8")
        print(raw, end="")
        return

    if tool_name != "Agent":
        print(raw, end="")
        return

    if is_plan_agent(data):
        # Plan 완료 플래그 생성
        now = datetime.now().isoformat()
        PLAN_FLAG.write_text(f"approved at {now}", encoding="utf-8")

    # pass-through
    print(raw, end="")


if __name__ == "__main__":
    main()
