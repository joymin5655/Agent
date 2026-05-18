#!/usr/bin/env python3
"""
UserPromptSubmit Hook: '기록해줘' 키워드 → agent-handoff-YYYY-MM-DD.md 자동 생성/append.

기존 record-chat-log.py는 모든 발화를 raw로 append하지만, 본 훅은 사용자가
명시적으로 "기록해줘" 류 키워드를 발화했을 때만 작동해서 정제된 핸드오프
문서를 만듭니다.

내용 구성:
- frontmatter (title, type, sources)
- 세션 통계 (오늘 chat-log + activity-log + git 통계)
- 최근 사용자 프롬프트 10개 (chat-log 기반)
- 변경 파일 목록 (activity-log 파싱)
- git 커밋 (오늘자)
- 미커밋 변경 (git status)
- "기록해줘" 트리거된 timestamp 기록

같은 날 여러 번 트리거되면 새 섹션을 append (덮어쓰기 X).
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys
from datetime import datetime

PROJECT_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
LOG_DIR = os.path.join(PROJECT_ROOT, "Obsidian-airlens/wiki/log")

# 트리거 키워드 — 한국어 명시 발화만 (영어는 raw 채팅에서 충분)
KEYWORD_PATTERNS = [
    r"기록해\s*줘",
    r"기록\s*하자",
    r"이번\s*세션\s*기록",
    r"핸드오프\s*기록",
    r"오늘\s*작업\s*기록",
    r"세션\s*저장",
]

FRONTMATTER_TEMPLATE = """---
title: "에이전트 핸드오프 {date}"
type: synthesis
created: {date}
updated: {date}
tags: [핸드오프, 자동기록]
sources: [chat-log-{date}.md, activity-{date}.md]
---

# 에이전트 핸드오프 — {date}

본 문서는 "기록해줘" 키워드 트리거 시 자동 갱신됩니다.
정제된 다음 세션 진입점 + 결정 요약 + 미해결 항목.

"""


def read_safe(path: str) -> str:
    if not os.path.exists(path):
        return ""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def extract_recent_prompts(chat_log: str, limit: int = 10) -> list[tuple[str, str]]:
    """chat-log에서 timestamp + 첫 줄 추출."""
    if not chat_log:
        return []

    pattern = re.compile(r"^## `(\d{2}:\d{2}:\d{2})`\s*\n+(.+?)(?=\n##|\n---|\Z)", re.DOTALL | re.MULTILINE)
    entries = pattern.findall(chat_log)

    out = []
    for ts, body in entries[-limit:]:
        first_line = body.strip().split("\n")[0].strip()
        if len(first_line) > 100:
            first_line = first_line[:100] + "..."
        out.append((ts, first_line))
    return out


def parse_files_changed(activity_log: str) -> tuple[list[str], list[str]]:
    """activity-log에서 생성/수정 파일 목록 추출."""
    if not activity_log:
        return [], []

    created: set[str] = set()
    modified: set[str] = set()
    pattern = re.compile(r"^## `\d{2}:\d{2}:\d{2}` — (\w+)\n- (.+)$", re.MULTILINE)
    for tool_name, desc in pattern.findall(activity_log):
        if tool_name not in ("Write", "Edit"):
            continue
        match = re.match(r"`(.+?)`\s*\((\S+)\)", desc)
        if not match:
            continue
        path, action = match.group(1), match.group(2)
        if action == "생성":
            created.add(path)
        else:
            modified.add(path)

    return sorted(created), sorted(modified)


def get_git_today_commits(date_str: str) -> list[str]:
    try:
        result = subprocess.run(
            [
                "git", "log",
                f"--since={date_str} 00:00",
                f"--until={date_str} 23:59",
                "--oneline", "--no-decorate", "--all",
            ],
            capture_output=True, text=True, timeout=5,
            cwd=PROJECT_ROOT,
        )
        return [c.strip() for c in result.stdout.strip().split("\n") if c.strip()]
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []


def get_git_status_summary() -> dict[str, int]:
    try:
        result = subprocess.run(
            ["git", "status", "--short"],
            capture_output=True, text=True, timeout=5,
            cwd=PROJECT_ROOT,
        )
        modified = staged = untracked = 0
        for line in result.stdout.splitlines():
            if not line:
                continue
            tag = line[:2]
            if "?" in tag:
                untracked += 1
            elif tag[0] != " ":
                staged += 1
            elif tag[1] != " ":
                modified += 1
        return {"modified": modified, "staged": staged, "untracked": untracked}
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return {"modified": 0, "staged": 0, "untracked": 0}


def get_open_prs() -> list[str]:
    """gh pr list — 머지 대기 PR 짧은 목록."""
    try:
        result = subprocess.run(
            ["gh", "pr", "list", "--state", "open",
             "--json", "number,title,headRefName",
             "--limit", "20"],
            capture_output=True, text=True, timeout=5,
            cwd=PROJECT_ROOT,
        )
        data = json.loads(result.stdout or "[]")
        return [
            f"#{pr['number']} {pr['title']} ({pr['headRefName']})"
            for pr in data
        ]
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
        return []


def build_section(today: str, trigger_ts: str, trigger_prompt: str) -> str:
    chat = read_safe(os.path.join(LOG_DIR, f"chat-log-{today}.md"))
    activity = read_safe(os.path.join(LOG_DIR, f"activity-{today}.md"))

    recent_prompts = extract_recent_prompts(chat, limit=10)
    created, modified = parse_files_changed(activity)
    commits = get_git_today_commits(today)
    status = get_git_status_summary()
    open_prs = get_open_prs()

    out: list[str] = []
    out.append(f"## {trigger_ts} — 기록 트리거")
    out.append("")
    out.append(f"**Trigger prompt**: {trigger_prompt[:200]}")
    out.append("")

    out.append("### 세션 통계 (오늘 누적)")
    out.append(f"- 사용자 프롬프트: {len(recent_prompts)}개 표시 / 전체는 chat-log 참조")
    out.append(f"- 파일 생성: {len(created)} / 수정: {len(modified)}")
    out.append(f"- 오늘 git 커밋: {len(commits)}")
    out.append(
        f"- 워킹 트리: staged={status['staged']}, modified={status['modified']}, "
        f"untracked={status['untracked']}"
    )
    out.append("")

    if open_prs:
        out.append("### 머지 대기 PR")
        for pr in open_prs:
            out.append(f"- {pr}")
        out.append("")

    if commits:
        out.append("### 오늘 commits")
        for c in commits[:30]:
            out.append(f"- {c}")
        if len(commits) > 30:
            out.append(f"- ... 외 {len(commits) - 30}개")
        out.append("")

    if created:
        out.append(f"### 생성된 파일 ({len(created)})")
        for p in created[:20]:
            out.append(f"- {p}")
        if len(created) > 20:
            out.append(f"- ... 외 {len(created) - 20}개")
        out.append("")

    if modified:
        out.append(f"### 수정된 파일 ({len(modified)})")
        for p in modified[:20]:
            out.append(f"- {p}")
        if len(modified) > 20:
            out.append(f"- ... 외 {len(modified) - 20}개")
        out.append("")

    if recent_prompts:
        out.append("### 최근 발화 (시간순)")
        for ts, line in recent_prompts:
            out.append(f"- `{ts}` {line}")
        out.append("")

    out.append("---")
    out.append("")
    return "\n".join(out)


def main() -> None:
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
        prompt = (
            data.get("user_prompt", "")
            or data.get("tool_input", {}).get("user_prompt", "")
            or data.get("prompt", "")
            or data.get("input", "")
        )
    except (json.JSONDecodeError, AttributeError):
        prompt = ""

    # pass-through (반드시 raw 그대로 출력)
    print(raw, end="")

    if not prompt:
        return

    # 키워드 매칭
    if not any(re.search(pat, prompt) for pat in KEYWORD_PATTERNS):
        return

    now = datetime.now()
    today = now.strftime("%Y-%m-%d")
    trigger_ts = now.strftime("%H:%M:%S")
    out_path = os.path.join(LOG_DIR, f"agent-handoff-{today}.md")

    section = build_section(today, trigger_ts, prompt.strip())

    os.makedirs(LOG_DIR, exist_ok=True)
    if os.path.exists(out_path):
        with open(out_path, "a", encoding="utf-8") as f:
            f.write("\n" + section)
    else:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(FRONTMATTER_TEMPLATE.format(date=today))
            f.write(section)

    # silent — 사용자에게 stderr로 한 줄 알림
    print(f"[Handoff] {out_path} 갱신 ({trigger_ts})", file=sys.stderr)


if __name__ == "__main__":
    main()
