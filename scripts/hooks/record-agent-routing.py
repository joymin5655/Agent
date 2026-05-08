#!/usr/bin/env python3
"""PostToolUse [Agent] — 에이전트 호출 추적 기록.

Agent 도구 호출 시마다 Obsidian wiki/log에 라우팅 기록.
어떤 에이전트가, 언제, 어떤 목적으로 호출됐는지 추적.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
from datetime import datetime

PROJECT_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
LOG_DIR = os.path.join(PROJECT_ROOT, "Obsidian-airlens/wiki/log")
STRUCTURED_LOG = os.path.join(PROJECT_ROOT, ".claude/logs/agent-routing.jsonl")
ANALYSIS_FLAG = "/tmp/airlens-supervisor-analysis.json"

FRONTMATTER_TEMPLATE = """---
title: "에이전트 라우팅 {date}"
type: source
created: {date}
updated: {date}
tags: [에이전트, 라우팅, 자동기록]
---

# 에이전트 라우팅 — {date}

"""


def load_supervisor_analysis():
    try:
        with open(ANALYSIS_FLAG, "r", encoding="utf-8") as f:
            data = json.loads(f.read())
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, OSError):
        pass
    return {}


def normalize_artifact(raw, producer: str, created_at: str) -> dict | None:
    if not isinstance(raw, dict):
        return None
    path = raw.get("path") or raw.get("file_path") or raw.get("filepath")
    if not path:
        return None
    return {
        "path": str(path),
        "kind": str(raw.get("kind") or raw.get("type") or "artifact"),
        "producer": str(raw.get("producer") or producer),
        "created_at": str(raw.get("created_at") or created_at),
        "retention": str(raw.get("retention") or "session"),
    }


def extract_artifacts(data: dict, subagent_type: str, created_at: str) -> list[dict]:
    candidates = []
    for source in (data.get("tool_input"), data, data.get("tool_response"), data.get("result")):
        if isinstance(source, dict):
            raw_artifacts = source.get("artifacts")
            if isinstance(raw_artifacts, list):
                candidates.extend(raw_artifacts)

    artifacts = []
    seen = set()
    for raw in candidates:
        artifact = normalize_artifact(raw, subagent_type, created_at)
        if not artifact:
            continue
        key = (artifact["path"], artifact["kind"], artifact["producer"])
        if key in seen:
            continue
        seen.add(key)
        artifacts.append(artifact)
    return artifacts


def main():
    raw = sys.stdin.read()

    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        print(raw, end="")
        return

    tool_name = data.get("tool_name", "")
    if tool_name != "Agent":
        print(raw, end="")
        return

    tool_input = data.get("tool_input", {})
    subagent_type = tool_input.get("subagent_type", "general-purpose")
    description = tool_input.get("description", "N/A")
    prompt_preview = tool_input.get("prompt", "")[:120]
    if len(tool_input.get("prompt", "")) > 120:
        prompt_preview += "..."
    model = tool_input.get("model", "inherit")
    isolation = tool_input.get("isolation", "none")
    background = tool_input.get("run_in_background", False)
    analysis = load_supervisor_analysis()

    now = datetime.now()
    created_at = now.isoformat()
    artifacts = extract_artifacts(data, subagent_type, created_at)
    today = now.strftime("%Y-%m-%d")
    timestamp = now.strftime("%H:%M:%S")
    filename = f"agent-routing-{today}.md"
    filepath = os.path.join(LOG_DIR, filename)

    os.makedirs(LOG_DIR, exist_ok=True)

    # 새 파일이면 frontmatter 포함
    if not os.path.exists(filepath):
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(FRONTMATTER_TEMPLATE.format(date=today))

    # 라우팅 기록 추가
    artifact_lines = ""
    if artifacts:
        artifact_lines = "- **산출물**:\n" + "".join(
            f"  - `{artifact['path']}` ({artifact['kind']}, producer={artifact['producer']}, retention={artifact['retention']})\n"
            for artifact in artifacts
        )

    entry = (
        f"## `{timestamp}` — {subagent_type}\n"
        f"- **요약**: {description}\n"
        f"- **모델**: {model} | **격리**: {isolation} | **백그라운드**: {background}\n"
        f"- **라우팅**: intent={analysis.get('intent', 'unknown')} | "
        f"risk={analysis.get('risk', 'unknown')} | "
        f"workflow={analysis.get('workflow', 'none')}\n"
        f"- **근거**: {analysis.get('rationale', 'N/A')}\n"
        f"- **작업 범위**: {prompt_preview}\n"
        f"{artifact_lines}\n"
    )

    with open(filepath, "a", encoding="utf-8") as f:
        f.write(entry)

    # 에이전트 디스패치 완료 플래그 기록 — agent-dispatch-enforcer.py가 참조
    dispatched_flag = "/tmp/airlens-dispatched-agents"
    try:
        existing = []
        if os.path.exists(dispatched_flag):
            with open(dispatched_flag, "r", encoding="utf-8") as f:
                existing = json.loads(f.read())
        existing.append(subagent_type)
        with open(dispatched_flag, "w", encoding="utf-8") as f:
            f.write(json.dumps(list(set(existing))))
    except (json.JSONDecodeError, OSError):
        with open(dispatched_flag, "w", encoding="utf-8") as f:
            f.write(json.dumps([subagent_type]))

    try:
        os.makedirs(os.path.dirname(STRUCTURED_LOG), exist_ok=True)
        structured = {
            "ts": created_at,
            "subagent_type": subagent_type,
            "description": description,
            "model": model,
            "isolation": isolation,
            "background": background,
            "intent": analysis.get("intent"),
            "risk": analysis.get("risk"),
            "matched_agents": analysis.get("matched_agents", []),
            "reference_agents": analysis.get("reference_agents", []),
            "workflow": analysis.get("workflow"),
            "reason": analysis.get("rationale"),
            "artifacts": artifacts,
        }
        with open(STRUCTURED_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(structured, ensure_ascii=False) + "\n")
    except OSError:
        pass

    # pass-through
    print(raw, end="")


if __name__ == "__main__":
    main()
