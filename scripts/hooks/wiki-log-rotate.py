#!/usr/bin/env python3
"""SessionStart Hook: Obsidian log.md 월별 자동 로테이션.

log.md 가 임계 (≥ 5,000 줄 OR ≥ 200 KB) 초과 시 직전 월 이전 항목을
wiki/log/log-YYYY-MM.md 로 이동. log.md 는 *현재 + 직전 월* 만 유지.

추가 동작:
- index.md.pre-slim-*.md 30일+ → wiki/_attic/ 자동 이동.

best-effort + idempotent + silent. 임계 미달 시 즉시 no-op.

Refs:
- Plan: ~/.claude/plans/inherited-wobbling-frog.md (Phase 1.A)
- Pattern: scripts/hooks/wiki-auto-index.py (log.md 형식 정합)
- Policy: .claude/rules/external-plugin-policy.md C2 (정본 영역 외 작업)
"""

from __future__ import annotations

import os
import re
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path

DRY_RUN = os.environ.get("WIKI_LOG_ROTATE_DRY_RUN") == "1"

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _resolve_wiki_root() -> Path:
    """worktree 의 경우 .git 파일을 따라 메인 트리의 Obsidian-airlens/ 를 찾는다."""
    candidate = PROJECT_ROOT / "Obsidian-airlens"
    if candidate.exists():
        return candidate
    git_marker = PROJECT_ROOT / ".git"
    if git_marker.is_file():
        try:
            for line in git_marker.read_text().splitlines():
                if line.startswith("gitdir:"):
                    gitdir = Path(line.split(":", 1)[1].strip())
                    # gitdir = <main>/.git/worktrees/<wt> → parents[2] = <main>
                    fallback = gitdir.parents[2] / "Obsidian-airlens"
                    if fallback.exists():
                        return fallback.resolve()
        except (OSError, IndexError):
            pass
    return candidate  # may not exist → main() returns no-op


WIKI_ROOT = _resolve_wiki_root()
LOG_PATH = WIKI_ROOT / "log.md"
WIKI_LOG_DIR = WIKI_ROOT / "wiki" / "log"
ATTIC_DIR = WIKI_ROOT / "wiki" / "_attic"

LINE_THRESHOLD = 5000
BYTE_THRESHOLD = 200 * 1024  # 200 KB
ATTIC_AGE_DAYS = 30

DATE_HEADER_RE = re.compile(r"^##\s*\[(\d{4})-(\d{2})-(\d{2})\]")


def needs_rotation() -> bool:
    if not LOG_PATH.exists():
        return False
    try:
        size = LOG_PATH.stat().st_size
        if size >= BYTE_THRESHOLD:
            return True
        with LOG_PATH.open("rb") as f:
            line_count = sum(1 for _ in f)
        return line_count >= LINE_THRESHOLD
    except OSError:
        return False


def parse_log() -> tuple[list[str], list[tuple[str, list[str]]]]:
    """Returns (preamble_lines, [(YYYY-MM-DD, full_section_lines)])."""
    text = LOG_PATH.read_text(encoding="utf-8")
    lines = text.split("\n")

    preamble: list[str] = []
    sections: list[tuple[str, list[str]]] = []
    current_date: str | None = None
    current_lines: list[str] = []

    for line in lines:
        m = DATE_HEADER_RE.match(line)
        if m:
            if current_date is not None:
                sections.append((current_date, current_lines))
            current_date = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
            current_lines = [line]
        else:
            if current_date is None:
                preamble.append(line)
            else:
                current_lines.append(line)

    if current_date is not None:
        sections.append((current_date, current_lines))

    return preamble, sections


def cutoff_month() -> tuple[int, int]:
    """현재 월 미만은 archive. log.md 는 현재 월만 유지."""
    today = datetime.now()
    return today.year, today.month


def split_by_month(
    sections: list[tuple[str, list[str]]],
    cutoff: tuple[int, int],
) -> tuple[list[tuple[str, list[str]]], dict[str, list[tuple[str, list[str]]]]]:
    """kept = current+prev month, archived = older grouped by YYYY-MM."""
    kept: list[tuple[str, list[str]]] = []
    archived: dict[str, list[tuple[str, list[str]]]] = {}
    cy, cm = cutoff

    for date_str, content in sections:
        y, m = int(date_str[:4]), int(date_str[5:7])
        if (y, m) >= (cy, cm):
            kept.append((date_str, content))
        else:
            archived.setdefault(f"{y:04d}-{m:02d}", []).append((date_str, content))

    return kept, archived


def archive_frontmatter(month: str) -> str:
    today = datetime.now().strftime("%Y-%m-%d")
    return (
        "---\n"
        "type: log-archive\n"
        f"month: {month}\n"
        f"created: {today}\n"
        "auto_rotated: true\n"
        "---\n\n"
        f"# log archive {month}\n\n"
        "Obsidian-airlens/log.md 에서 자동 분할된 일별 작업 기록.\n"
    )


def write_archive(month: str, month_sections: list[tuple[str, list[str]]]) -> None:
    archive_path = WIKI_LOG_DIR / f"log-{month}.md"
    is_new = not archive_path.exists()
    body = "\n".join("\n".join(content) for _, content in month_sections)

    if DRY_RUN:
        sys.stderr.write(
            f"[dry-run] would {'create' if is_new else 'append'} "
            f"{archive_path} ({len(month_sections)} day(s), {len(body)}B)\n"
        )
        return

    archive_path.parent.mkdir(parents=True, exist_ok=True)
    if is_new:
        archive_path.write_text(archive_frontmatter(month) + body + "\n", encoding="utf-8")
    else:
        existing = archive_path.read_text(encoding="utf-8").rstrip()
        archive_path.write_text(existing + "\n\n" + body + "\n", encoding="utf-8")


def write_kept(preamble: list[str], kept: list[tuple[str, list[str]]]) -> None:
    parts: list[str] = []
    if preamble:
        parts.append("\n".join(preamble))
    for _, content in kept:
        parts.append("\n".join(content))
    new_text = "\n".join(parts).rstrip() + "\n"

    if DRY_RUN:
        sys.stderr.write(
            f"[dry-run] would shrink {LOG_PATH} to {len(new_text)}B "
            f"({len(kept)} day(s) kept)\n"
        )
        return

    LOG_PATH.write_text(new_text, encoding="utf-8")


def attic_old_backups() -> int:
    """Move *.pre-slim-*.md older than ATTIC_AGE_DAYS to wiki/_attic/."""
    if not WIKI_ROOT.exists():
        return 0
    cutoff_ts = (datetime.now() - timedelta(days=ATTIC_AGE_DAYS)).timestamp()
    moved = 0
    for path in WIKI_ROOT.glob("*.pre-slim-*.md"):
        try:
            if path.stat().st_mtime >= cutoff_ts:
                continue
            if DRY_RUN:
                sys.stderr.write(f"[dry-run] would attic {path.name}\n")
                moved += 1
                continue
            ATTIC_DIR.mkdir(parents=True, exist_ok=True)
            target = ATTIC_DIR / path.name
            if target.exists():
                target.unlink()
            shutil.move(str(path), str(target))
            moved += 1
        except OSError:
            continue
    return moved


def main() -> None:
    try:
        sys.stdin.read()
    except OSError:
        pass

    try:
        attic_old_backups()
    except OSError:
        pass

    if not needs_rotation():
        return

    try:
        _preamble, sections = parse_log()
    except OSError:
        return

    if not sections:
        return

    kept, archived = split_by_month(sections, cutoff_month())

    if not archived:
        return

    try:
        for month, month_sections in sorted(archived.items()):
            write_archive(month, month_sections)
        write_kept(_preamble, kept)
    except OSError as exc:
        sys.stderr.write(f"wiki-log-rotate: write failed: {exc}\n")


if __name__ == "__main__":
    main()
