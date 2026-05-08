#!/usr/bin/env python3
"""
Stop Hook: 일일 요약 자동 생성
세션 종료 시 당일 chat-log + activity-log + git log를 종합하여 일일 요약 생성.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime

PROJECT_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
LOG_DIR = os.path.join(PROJECT_ROOT, "Obsidian-airlens/wiki/log")
CLAUDE_LOG_DIR = os.path.join(PROJECT_ROOT, ".claude/logs")
INDEXER_SCRIPT = os.path.join(PROJECT_ROOT, "scripts/session-indexer.py")
QUEUE_CANDIDATES_FILE = os.path.join(PROJECT_ROOT, "Obsidian-airlens/raw/plans/airlens-task-queue-candidates.json")

FRONTMATTER_TEMPLATE = """---
title: "일일 요약 {date}"
type: synthesis
created: {date}
updated: {date}
tags: [일일요약, 자동기록]
sources: [{sources}]
---

# 일일 요약 — {date}

"""


def read_file_safe(filepath: str) -> str:
    """파일이 존재하면 읽고, 없으면 빈 문자열 반환."""
    if not os.path.exists(filepath):
        return ""
    try:
        with open(filepath, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def count_prompts(chat_log: str) -> tuple[int, list[str]]:
    """chat-log에서 프롬프트 수와 주요 내용 추출."""
    if not chat_log:
        return 0, []

    # ## `HH:MM:SS` 패턴으로 프롬프트 블록 분리
    blocks = re.split(r"^## `\d{2}:\d{2}:\d{2}`", chat_log, flags=re.MULTILINE)
    # 첫 블록은 frontmatter이므로 제외
    prompt_blocks = [b.strip() for b in blocks[1:] if b.strip()]

    summaries = []
    for block in prompt_blocks:
        # ---로 분리된 내용에서 첫 줄만 추출
        lines = [ln.strip() for ln in block.split("\n") if ln.strip() and ln.strip() != "---"]
        if lines:
            summary = lines[0][:80]
            if len(lines[0]) > 80:
                summary += "..."
            summaries.append(summary)

    return len(prompt_blocks), summaries


def parse_activities(activity_log: str) -> dict:
    """activity-log에서 파일 변경 및 명령어 통계 추출."""
    result = {
        "files_created": [],
        "files_modified": [],
        "bash_commands": 0,
        "total_entries": 0,
    }
    if not activity_log:
        return result

    # ## `HH:MM:SS` — ToolName 패턴 파싱
    entries = re.findall(
        r"^## `\d{2}:\d{2}:\d{2}` — (\w+)\n- (.+)$",
        activity_log,
        re.MULTILINE,
    )

    for tool_name, description in entries:
        result["total_entries"] += 1
        if tool_name in ("Write", "Edit"):
            # `path` (생성/수정) 포맷
            match = re.match(r"`(.+?)`\s*\((\S+)\)", description)
            if match:
                path, action = match.group(1), match.group(2)
                if action == "생성":
                    result["files_created"].append(path)
                else:
                    result["files_modified"].append(path)
        elif tool_name == "Bash":
            result["bash_commands"] += 1

    return result


def parse_agent_routing(routing_log: str) -> dict:
    """agent-routing-log에서 에이전트 호출 통계 추출."""
    result: dict[str, int] = {}
    if not routing_log:
        return result

    entries = re.findall(
        r"^## `\d{2}:\d{2}:\d{2}` — (\S+)",
        routing_log,
        re.MULTILINE,
    )
    for agent_type in entries:
        result[agent_type] = result.get(agent_type, 0) + 1

    return result


def read_jsonl_for_date(filepath: str, date_str: str) -> list[dict]:
    if not os.path.exists(filepath):
        return []
    records = []
    try:
        with open(filepath, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = str(record.get("ts") or "")
                if ts.startswith(date_str):
                    records.append(record)
    except OSError:
        return []
    return records


def summarize_control_plane(today: str) -> dict:
    supervisor = read_jsonl_for_date(
        os.path.join(CLAUDE_LOG_DIR, "supervisor-routing.jsonl"),
        today,
    )
    agents = read_jsonl_for_date(
        os.path.join(CLAUDE_LOG_DIR, "agent-routing.jsonl"),
        today,
    )

    intents = Counter(str(item.get("intent") or "unknown") for item in supervisor)
    risks = Counter(str(item.get("risk") or "unknown") for item in supervisor)
    workflows = Counter(str(item.get("workflow") or "none") for item in supervisor)
    dispatched = Counter(str(item.get("subagent_type") or "unknown") for item in agents)

    high_risk = [
        item for item in supervisor
        if item.get("risk") == "HIGH" or item.get("intent") == "MULTI_DEPT"
    ]
    next_entries = []
    for item in high_risk[-3:]:
        prompt = str(item.get("prompt_first_160") or "").strip()
        matched = ", ".join(item.get("matched_agents") or [])
        next_entries.append({
            "prompt": prompt,
            "intent": item.get("intent") or "unknown",
            "risk": item.get("risk") or "unknown",
            "workflow": item.get("workflow") or "none",
            "matched_agents": matched,
            "canonical_docs": item.get("canonical_docs") or [],
            "required_checks": item.get("required_checks") or [],
        })

    artifacts = []
    for item in agents:
        for artifact in item.get("artifacts") or []:
            if isinstance(artifact, dict) and artifact.get("path"):
                artifacts.append(artifact)

    return {
        "supervisor_count": len(supervisor),
        "agent_count": len(agents),
        "intent_distribution": dict(intents),
        "risk_distribution": dict(risks),
        "workflow_distribution": dict(workflows),
        "agent_distribution": dict(dispatched),
        "high_risk_count": len(high_risk),
        "next_entries": next_entries,
        "artifacts": artifacts,
    }


def export_queue_candidates(today: str, control_plane: dict) -> dict | None:
    """Export next-session candidates without inserting them into the live queue."""
    entries = control_plane.get("next_entries") or []
    if not entries:
        return None

    candidates = []
    for index, item in enumerate(entries, 1):
        candidates.append({
            "id": f"CAND-{today.replace('-', '')}-{index:03d}",
            "source": "session-daily-summary",
            "created_at": datetime.utcnow().isoformat() + "Z",
            "prompt": item["prompt"],
            "intent": item["intent"],
            "risk": item["risk"],
            "workflow": item["workflow"],
            "matched_agents": item["matched_agents"],
            "canonical_docs": item.get("canonical_docs") or [],
            "required_checks": item.get("required_checks") or [],
            "suggested_queue_fields": {
                "priority": "P1" if item["risk"] == "HIGH" else "P2",
                "status": "pending",
                "area": "operations",
                "owner": "user" if item["risk"] == "HIGH" else "agent",
                "mode": "approval_required" if item["risk"] == "HIGH" else "suggest",
                "verify_profile": "harness-audit",
                "allowed_commands": ["harness-audit"],
            },
        })

    payload = {
        "version": 1,
        "project": "AirLens",
        "exported_at": datetime.utcnow().isoformat() + "Z",
        "policy": "Candidates are review-only. Do not auto-insert into airlens-task-queue.json.",
        "candidates": candidates,
    }

    os.makedirs(os.path.dirname(QUEUE_CANDIDATES_FILE), exist_ok=True)
    with open(QUEUE_CANDIDATES_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")

    return {
        "path": "Obsidian-airlens/raw/plans/airlens-task-queue-candidates.json",
        "kind": "queue-candidates",
        "producer": "session-daily-summary",
        "retention": "review",
    }


def get_git_commits(date_str: str) -> list[str]:
    """당일 git 커밋 목록 가져오기."""
    try:
        result = subprocess.run(
            ["git", "log", f"--since={date_str} 00:00", f"--until={date_str} 23:59",
             "--oneline", "--no-decorate"],
            capture_output=True, text=True, timeout=5,
            cwd=PROJECT_ROOT,
        )
        commits = [c.strip() for c in result.stdout.strip().split("\n") if c.strip()]
        return commits
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []


def trigger_reindex():
    """session-indexer 자동 리인덱스 (실패 무시)."""
    if not os.path.exists(INDEXER_SCRIPT):
        return
    try:
        subprocess.Popen(
            ["python3", INDEXER_SCRIPT, "--reindex"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            cwd=PROJECT_ROOT,
        )
    except OSError:
        pass


def build_summary(
    today: str,
    prompt_count: int,
    prompt_summaries: list[str],
    activities: dict,
    commits: list[str],
    agent_stats: dict | None = None,
    control_plane: dict | None = None,
) -> str:
    """일일 요약 마크다운 생성."""
    sources = []
    if prompt_count > 0:
        sources.append(f"chat-log-{today}.md")
    if activities["total_entries"] > 0:
        sources.append(f"activity-{today}.md")
    if control_plane and control_plane["supervisor_count"] > 0:
        sources.append("supervisor-routing.jsonl")
    if control_plane and control_plane["agent_count"] > 0:
        sources.append("agent-routing.jsonl")
    sources_str = ", ".join(sources)

    content = FRONTMATTER_TEMPLATE.format(date=today, sources=sources_str)

    # 세션 통계
    file_count = len(activities["files_created"]) + len(activities["files_modified"])
    content += "## 세션 통계\n"
    content += f"- 프롬프트: {prompt_count}건\n"
    content += f"- 파일 변경: {file_count}건"
    if activities["files_created"] or activities["files_modified"]:
        parts = []
        if activities["files_created"]:
            parts.append(f"생성 {len(activities['files_created'])}")
        if activities["files_modified"]:
            parts.append(f"수정 {len(activities['files_modified'])}")
        content += f" ({', '.join(parts)})"
    content += "\n"
    content += f"- Bash 명령: {activities['bash_commands']}건\n"
    content += f"- git 커밋: {len(commits)}건\n"
    if agent_stats:
        total_agents = sum(agent_stats.values())
        content += f"- 에이전트 호출: {total_agents}건\n"
    if control_plane and control_plane["supervisor_count"] > 0:
        content += f"- Supervisor 분석: {control_plane['supervisor_count']}건\n"
        content += f"- 고위험/MULTI_DEPT 후보: {control_plane['high_risk_count']}건\n"
    content += "\n"

    # 변경 파일 목록 (중복 제거)
    all_files = set()
    for path in activities["files_created"]:
        all_files.add(f"- {path} (생성)")
    for path in activities["files_modified"]:
        all_files.add(f"- {path} (수정)")
    if all_files:
        content += "## 변경 파일\n"
        for entry in sorted(all_files):
            content += f"{entry}\n"
        content += "\n"

    # git 커밋
    if commits:
        content += "## git 커밋\n"
        for commit in commits:
            content += f"- {commit}\n"
        content += "\n"

    # 에이전트 라우팅 통계
    if agent_stats:
        content += "## 에이전트 호출\n"
        for agent_type, count in sorted(agent_stats.items(), key=lambda x: -x[1]):
            content += f"- {agent_type}: {count}회\n"
        content += "\n"

    if control_plane and control_plane["supervisor_count"] > 0:
        content += "## Supervisor v6 라우팅 분포\n"
        for label, key in [
            ("Intent", "intent_distribution"),
            ("Risk", "risk_distribution"),
            ("Workflow", "workflow_distribution"),
            ("Agent", "agent_distribution"),
        ]:
            distribution = control_plane.get(key) or {}
            if distribution:
                values = ", ".join(f"{name}={count}" for name, count in sorted(distribution.items()))
                content += f"- {label}: {values}\n"
        content += "\n"

    if control_plane and control_plane.get("artifacts"):
        content += "## 산출물 Descriptor\n"
        for artifact in control_plane["artifacts"][:10]:
            content += (
                f"- `{artifact.get('path')}` "
                f"({artifact.get('kind', 'artifact')}, producer={artifact.get('producer', 'unknown')}, "
                f"retention={artifact.get('retention', 'session')})\n"
            )
        content += "\n"

    if control_plane and control_plane.get("next_entries"):
        content += "## 다음 세션 진입점 후보\n"
        content += "_자동 prompt injection 금지. 다음 세션 작업자가 읽고 선택한다._\n"
        for item in control_plane["next_entries"]:
            content += (
                f"- [{item['intent']}/{item['risk']}/{item['workflow']}] "
                f"{item['prompt']} — agents: {item['matched_agents'] or 'none'}\n"
            )
        content += "\n"

    # 주요 작업 (프롬프트 요약)
    if prompt_summaries:
        content += "## 주요 작업\n"
        for summary in prompt_summaries[:10]:
            content += f"- {summary}\n"
        content += "\n"

    return content


def main():
    # Stop 훅은 stdin을 읽어야 함
    try:
        raw = sys.stdin.read()
    except Exception:
        raw = ""

    today = datetime.now().strftime("%Y-%m-%d")

    # 소스 파일 읽기
    chat_log = read_file_safe(os.path.join(LOG_DIR, f"chat-log-{today}.md"))
    activity_log = read_file_safe(os.path.join(LOG_DIR, f"activity-{today}.md"))

    routing_log = read_file_safe(os.path.join(LOG_DIR, f"agent-routing-{today}.md"))

    prompt_count, prompt_summaries = count_prompts(chat_log)
    activities = parse_activities(activity_log)
    agent_stats = parse_agent_routing(routing_log)
    control_plane = summarize_control_plane(today)
    candidate_artifact = export_queue_candidates(today, control_plane)
    if candidate_artifact:
        control_plane.setdefault("artifacts", []).append(candidate_artifact)
    commits = get_git_commits(today)

    # 아무 활동도 없으면 스킵
    if (
        prompt_count == 0
        and activities["total_entries"] == 0
        and not commits
        and control_plane["supervisor_count"] == 0
        and control_plane["agent_count"] == 0
    ):
        print(json.dumps({}))
        return

    # 일일 요약 생성 (항상 덮어쓰기 — 최신 상태 반영)
    summary = build_summary(today, prompt_count, prompt_summaries, activities, commits, agent_stats, control_plane)

    os.makedirs(LOG_DIR, exist_ok=True)
    filepath = os.path.join(LOG_DIR, f"daily-{today}.md")
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(summary)

    print(f"[Daily Summary] {filepath} 생성 완료", file=sys.stderr)

    # session-indexer 자동 리인덱스 (비동기)
    trigger_reindex()

    # pass-through
    print(json.dumps({}))


if __name__ == "__main__":
    main()
