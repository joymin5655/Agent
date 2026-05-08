#!/usr/bin/env python3
"""
PostToolUse Hook: 작업 활동 자동 기록
Write/Edit/Bash 도구 사용 시마다 활동을 Obsidian wiki/log에 날짜별 기록.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
from datetime import datetime

PROJECT_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
LOG_DIR = os.path.join(PROJECT_ROOT, "Obsidian-airlens/wiki/log")

FRONTMATTER_TEMPLATE = """---
title: "활동 로그 {date}"
type: source
created: {date}
updated: {date}
tags: [활동로그, 자동기록]
---

# 활동 로그 — {date}

"""

# Bash 명령 중 기록에서 제외할 패턴 (보안/노이즈)
SKIP_COMMANDS = frozenset([
    "echo",
    "cat",
    "true",
    "false",
    ":",
])

# 민감 정보가 포함될 수 있는 명령 패턴
SENSITIVE_PATTERNS = (
    "export ",
    "API_KEY",
    "SECRET",
    "TOKEN",
    "PASSWORD",
    "SUPABASE_",
)


def sanitize_command(cmd: str) -> str:
    """민감 정보가 포함된 명령은 마스킹."""
    for pattern in SENSITIVE_PATTERNS:
        if pattern in cmd.upper():
            return f"{cmd.split()[0]} [REDACTED]"
    # 긴 명령은 잘라냄
    if len(cmd) > 200:
        return cmd[:200] + "..."
    return cmd


def extract_activity(data: dict) -> tuple[str, str] | None:
    """stdin JSON에서 도구명과 활동 설명 추출.

    Returns (tool_name, description) or None if skip.
    """
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})

    if tool_name in ("Write", "Edit"):
        file_path = tool_input.get("file_path", "")
        if not file_path:
            return None
        # 프로젝트 루트 기준 상대 경로로 변환
        project_root = PROJECT_ROOT.rstrip("/") + "/"
        display_path = file_path
        if file_path.startswith(project_root):
            display_path = file_path[len(project_root):]
        action = "생성" if tool_name == "Write" else "수정"
        return tool_name, f"`{display_path}` ({action})"

    if tool_name == "Bash":
        command = tool_input.get("command", "")
        if not command or not command.strip():
            return None
        first_word = command.strip().split()[0] if command.strip() else ""
        if first_word in SKIP_COMMANDS:
            return None
        safe_cmd = sanitize_command(command.strip())
        return tool_name, f"`{safe_cmd}`"

    return None


def main():
    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print(raw, end="")
        return

    activity = extract_activity(data)
    if not activity:
        print(raw, end="")
        return

    tool_name, description = activity

    now = datetime.now()
    today = now.strftime("%Y-%m-%d")
    timestamp = now.strftime("%H:%M:%S")
    filename = f"activity-{today}.md"
    filepath = os.path.join(LOG_DIR, filename)

    os.makedirs(LOG_DIR, exist_ok=True)

    # 새 파일이면 frontmatter 포함하여 생성
    if not os.path.exists(filepath):
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(FRONTMATTER_TEMPLATE.format(date=today))

    # 활동 추가
    with open(filepath, "a", encoding="utf-8") as f:
        f.write(f"## `{timestamp}` — {tool_name}\n")
        f.write(f"- {description}\n\n")

    # pass-through
    print(raw, end="")


if __name__ == "__main__":
    main()
