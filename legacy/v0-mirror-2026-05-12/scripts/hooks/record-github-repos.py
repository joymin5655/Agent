#!/usr/bin/env python3
"""
UserPromptSubmit Hook: GitHub 레포지토리 자동 기록
사용자 프롬프트에서 github.com URL을 추출하여 레지스트리에 자동 등록.
"""

import sys
import json
import re
import os
import pathlib
from datetime import date

PROJECT_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
REGISTRY = os.path.join(
    PROJECT_ROOT,
    "Obsidian-airlens/wiki/sources/github-repo-registry.md",
)

REPO_PATTERN = re.compile(
    r"https?://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"
)


def extract_repos(text: str) -> set[str]:
    matches = REPO_PATTERN.findall(text)
    cleaned = set()
    for m in matches:
        repo = m.rstrip("/").split("?")[0].split("#")[0]
        if repo.endswith(".git"):
            repo = repo[:-4]
        # skip fragments like blob/main, tree/master, etc.
        parts = repo.split("/")
        if len(parts) >= 2:
            cleaned.add(f"{parts[0]}/{parts[1]}")
    return cleaned


def main():
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
        prompt = raw

    repos = extract_repos(prompt)

    if repos and os.path.exists(REGISTRY):
        existing = open(REGISTRY, encoding="utf-8").read()
        today = date.today().isoformat()
        new_entries = []

        for repo in sorted(repos):
            if repo not in existing:
                url = f"https://github.com/{repo}"
                new_entries.append(f"| {today} | {repo} | {url} | [미분류] | — |")

        if new_entries:
            with open(REGISTRY, "a", encoding="utf-8") as f:
                f.write("\n".join(new_entries) + "\n")

    # pass-through for hook chain
    print(raw, end="")


if __name__ == "__main__":
    main()
