#!/usr/bin/env python3
"""
UserPromptSubmit Hook: 채팅 프롬프트 자동 기록
모든 사용자 프롬프트를 Obsidian 위키에 날짜별 파일로 기록.
"""

import sys
import json
import os
import pathlib
from datetime import datetime

PROJECT_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
LOG_DIR = os.path.join(PROJECT_ROOT, "Obsidian-airlens/wiki/log")

FRONTMATTER_TEMPLATE = """---
title: "채팅 로그 {date}"
type: source
created: {date}
updated: {date}
tags: [채팅로그, 자동기록]
---

# 채팅 로그 — {date}

"""


def main():
    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
        # UserPromptSubmit can have prompt at multiple locations
        prompt = (
            data.get("user_prompt", "")
            or data.get("tool_input", {}).get("user_prompt", "")
            or data.get("prompt", "")
            or data.get("input", "")
        )
    except (json.JSONDecodeError, AttributeError):
        prompt = ""

    if not prompt or not prompt.strip():
        print(raw, end="")
        return

    # skip slash commands and very short inputs
    stripped = prompt.strip()
    if stripped.startswith("/") and len(stripped) < 20:
        print(raw, end="")
        return

    now = datetime.now()
    today = now.strftime("%Y-%m-%d")
    timestamp = now.strftime("%H:%M:%S")
    filename = f"chat-log-{today}.md"
    filepath = os.path.join(LOG_DIR, filename)

    os.makedirs(LOG_DIR, exist_ok=True)

    # create file with frontmatter if new
    if not os.path.exists(filepath):
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(FRONTMATTER_TEMPLATE.format(date=today))

    # append prompt
    with open(filepath, "a", encoding="utf-8") as f:
        f.write(f"## `{timestamp}`\n\n")
        f.write(f"{stripped}\n\n---\n\n")

    # pass-through
    print(raw, end="")


if __name__ == "__main__":
    main()
