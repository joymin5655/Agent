#!/usr/bin/env python3
"""AirLens — PostToolUse Write|Edit hook for wiki frontmatter consistency.

Scans newly-created (or just-updated) files under
  Obsidian-airlens/wiki/synthesis/**
  Obsidian-airlens/wiki/imports/**
  Obsidian-airlens/wiki/triage/**

If frontmatter is missing OR required keys absent (papers / authors / fetched /
license / source), prepends a default template tagged `[verify]` so the operator
can fill in real values.

NEVER overwrites existing frontmatter — only fills the gap. Files that already
have valid frontmatter are left untouched.

Refs:
  - Plan: ~/.claude/plans/wondrous-sprouting-riddle.md (P5)
  - Pattern: scripts/hooks/wiki-auto-index.py (PostToolUse Write chain)
  - Policy: .claude/rules/policy/firecrawl-policy.md §"라이선스 / 출처 표기"
            .claude/rules/policy/hugging-face-research.md §"arXiv 인용 의무"
"""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
WIKI_DIR = PROJECT_ROOT / "Obsidian-airlens/wiki"

# Subdirectories that require frontmatter. Other wiki paths are skipped.
TARGETED_PREFIXES = ("synthesis", "imports", "triage")

# Required keys per category.
REQUIRED_KEYS = {
    "synthesis": ["topic", "fetched", "papers", "license"],
    "imports": ["source", "domain", "license", "fetched"],
    "triage": ["source", "topic", "fetched", "candidate_count"],
}


def detect_category(rel: Path) -> str:
    parts = rel.parts
    if not parts:
        return ""
    return parts[0] if parts[0] in TARGETED_PREFIXES else ""


def has_frontmatter(text: str) -> bool:
    if not text.startswith("---"):
        return False
    return text.find("\n---", 3) > 0


def parse_keys(text: str):
    if not has_frontmatter(text):
        return set()
    end = text.find("\n---", 3)
    block = text[3:end]
    keys = set()
    for line in block.strip().split("\n"):
        if ":" in line and not line.lstrip().startswith("#"):
            k = line.split(":", 1)[0].strip()
            if k:
                keys.add(k)
    return keys


def build_template(category: str, today: str) -> str:
    if category == "synthesis":
        return (
            "---\n"
            "topic: [verify]\n"
            f"fetched: {today}\n"
            "papers: []  # arXiv ID list — [verify]\n"
            "authors: []  # [verify]\n"
            "license: [verify]  # CC-BY-4.0 / MIT / public-domain / site-terms\n"
            "hf_models: []\n"
            "hf_spaces: []\n"
            "---\n\n"
        )
    if category == "imports":
        return (
            "---\n"
            "source: [verify]  # full URL\n"
            "domain: [verify]  # whitelist domain\n"
            f"fetched: {today}\n"
            "license: [verify]  # CC-BY-4.0 / MIT / public-domain / site-terms\n"
            "crawled_pages: 1\n"
            "---\n\n"
        )
    if category == "triage":
        return (
            "---\n"
            "source: [verify]  # codex / gemini / tatum / grok / consultant-X\n"
            "topic: [verify]\n"
            f"fetched: {today}\n"
            "candidate_count: 0\n"
            "adopted: 0\n"
            "already_canonical: 0\n"
            "rejected: 0\n"
            "not_applicable: 0\n"
            "---\n\n"
        )
    return ""


def main() -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        return

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return

    tool_input = data.get("tool_input", {})
    file_path_raw = tool_input.get("file_path", "")
    if not file_path_raw:
        return

    file_path = Path(file_path_raw)

    try:
        rel = file_path.relative_to(WIKI_DIR)
    except ValueError:
        return

    if rel.parts and (rel.parts[-1].startswith("_") or rel.parts[-1].startswith(".")):
        return
    if not str(file_path).endswith(".md"):
        return
    if not file_path.is_file():
        return

    category = detect_category(rel)
    if not category:
        return

    try:
        text = file_path.read_text(encoding="utf-8")
    except OSError:
        return

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    required = set(REQUIRED_KEYS.get(category, []))
    existing_keys = parse_keys(text)

    # Case 1: no frontmatter → prepend template.
    if not has_frontmatter(text):
        template = build_template(category, today)
        if not template:
            return
        try:
            file_path.write_text(template + text, encoding="utf-8")
            sys.stderr.write(
                f"wiki-frontmatter-inject: prepended {category} template to {rel}\n"
            )
        except OSError as exc:
            sys.stderr.write(f"wiki-frontmatter-inject: write failed: {exc}\n")
        return

    # Case 2: frontmatter exists but missing required keys → emit reminder only.
    missing = required - existing_keys
    if missing:
        sys.stderr.write(
            f"wiki-frontmatter-inject: {rel} missing keys: {sorted(missing)}\n"
        )


if __name__ == "__main__":
    main()
