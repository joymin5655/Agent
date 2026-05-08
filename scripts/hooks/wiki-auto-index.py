#!/usr/bin/env python3
"""
PostToolUse Hook: 위키 페이지 자동 인덱싱
Write/Edit로 Obsidian-airlens/wiki/ 하위 파일이 생성/수정되면
index.md와 log.md를 자동 갱신한다.

트리거: PostToolUse (Write|Edit)
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
WIKI_ROOT = PROJECT_ROOT / "Obsidian-airlens"
WIKI_DIR = WIKI_ROOT / "wiki"
INDEX_PATH = WIKI_ROOT / "index.md"
LOG_PATH = WIKI_ROOT / "log.md"

# wiki/log/ 하위는 자동 인덱싱 대상이 아님 (별도 훅이 관리)
SKIP_DIRS = {"log"}

# 카테고리 → index.md 섹션 헤더 매핑
CATEGORY_HEADERS: dict[str, str] = {
    "entities": "## Entities",
    "concepts": "## Concepts",
    "sources": "## Sources",
    "synthesis": "## Synthesis",
    "comparisons": "## Comparisons",
    "references": "## References",
}


def parse_frontmatter(filepath: Path) -> dict[str, str]:
    """YAML frontmatter에서 title, type 추출."""
    result: dict[str, str] = {}
    try:
        text = filepath.read_text(encoding="utf-8")
    except OSError:
        return result

    if not text.startswith("---"):
        return result

    end = text.find("---", 3)
    if end < 0:
        return result

    fm_block = text[3:end]
    for line in fm_block.strip().split("\n"):
        if ":" in line:
            key, _, val = line.partition(":")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key in ("title", "type"):
                result[key] = val

    return result


def get_relative_wiki_path(filepath: Path) -> str:
    """wiki/ 기준 상대 경로 반환."""
    try:
        return str(filepath.relative_to(WIKI_ROOT))
    except ValueError:
        return str(filepath)


def is_in_index(index_text: str, filepath: Path, title: str) -> bool:
    """index.md에 이미 등록되어 있는지 확인."""
    basename = filepath.stem
    rel_path = get_relative_wiki_path(filepath)

    # 파일명, 경로, 제목 중 하나라도 매치되면 등록된 것으로 판단
    checks = [basename]
    if title:
        checks.append(title)
        # 괄호 이전 부분도 체크 (e.g., "인과 추론 (Causal Inference)" → "인과 추론")
        short = re.sub(r"\s*\(.*\)$", "", title)
        if short != title:
            checks.append(short)

    index_lower = index_text.lower()
    for check in checks:
        if check.lower() in index_lower:
            return True

    if rel_path in index_text:
        return True

    return False


def find_insert_position(
    lines: list[str], category: str
) -> int:
    """카테고리에 해당하는 섹션의 마지막 항목 위치를 찾는다."""
    header = CATEGORY_HEADERS.get(category, "")
    if not header:
        # 서브디렉토리 (sources/anthropic 등)는 Sources 섹션에 추가
        for parent_cat in ("sources", "synthesis", "concepts", "entities"):
            if category.startswith(parent_cat):
                header = CATEGORY_HEADERS[parent_cat]
                break

    if not header:
        return -1

    header_lower = header.lower()
    in_section = False
    last_item_line = -1

    for i, line in enumerate(lines):
        stripped = line.strip()
        # 섹션 헤더 찾기 (## Entities, ## Concepts 등)
        if stripped.lower().startswith(header_lower):
            in_section = True
            last_item_line = i
            continue

        if in_section:
            # 새로운 ## 섹션 시작이면 멈춤
            if stripped.startswith("## ") and not stripped.lower().startswith(
                header_lower
            ):
                break
            # 항목 라인이면 위치 갱신
            if stripped.startswith("- [["):
                last_item_line = i

    return last_item_line


def add_to_index(filepath: Path, title: str, category: str) -> bool:
    """index.md에 새 항목 추가. 추가되면 True 반환."""
    if not INDEX_PATH.exists():
        return False

    index_text = INDEX_PATH.read_text(encoding="utf-8")

    if is_in_index(index_text, filepath, title):
        return False

    rel_path = get_relative_wiki_path(filepath)
    display_title = title or filepath.stem
    entry = f"- [[{display_title}|{rel_path}]] — (자동 등록)"

    lines = index_text.split("\n")
    insert_pos = find_insert_position(lines, category)

    if insert_pos < 0:
        # 적절한 섹션을 못 찾으면 파일 끝에 추가
        lines.append("")
        lines.append(entry)
    else:
        lines.insert(insert_pos + 1, entry)

    INDEX_PATH.write_text("\n".join(lines), encoding="utf-8")
    return True


def add_to_log(filepath: Path, title: str, action: str) -> None:
    """log.md에 작업 기록 추가."""
    if not LOG_PATH.exists():
        return

    log_text = LOG_PATH.read_text(encoding="utf-8")
    now = datetime.now()
    date_str = now.strftime("%Y-%m-%d")
    time_str = now.strftime("%H:%M")
    display_title = title or filepath.stem
    rel_path = get_relative_wiki_path(filepath)

    log_entry = (
        f"- [{time_str}] auto-index | {action} "
        f"[[{display_title}|{rel_path}]]"
    )

    # 오늘 날짜 헤더가 있는지 확인
    date_header = f"## [{date_str}]"
    if date_header not in log_text:
        # 오늘 날짜 헤더를 최상단 (frontmatter 다음)에 추가
        lines = log_text.split("\n")
        insert_after = 0
        for i, line in enumerate(lines):
            if line.strip() == "---" and i > 0:
                insert_after = i + 1
                break
            if line.startswith("# "):
                insert_after = i + 1

        # 빈 줄 건너뛰기
        while insert_after < len(lines) and not lines[insert_after].strip():
            insert_after += 1

        lines.insert(insert_after, "")
        lines.insert(insert_after + 1, f"{date_header} auto-index | 자동 인덱싱")
        lines.insert(insert_after + 2, "")
        lines.insert(insert_after + 3, log_entry)
        LOG_PATH.write_text("\n".join(lines), encoding="utf-8")
    else:
        # 기존 날짜 헤더 아래에 추가
        lines = log_text.split("\n")
        for i, line in enumerate(lines):
            if date_header in line:
                # 헤더 바로 다음 줄에 삽입
                j = i + 1
                while j < len(lines) and not lines[j].strip():
                    j += 1
                lines.insert(j, log_entry)
                break
        LOG_PATH.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        return

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return

    # tool_input에서 파일 경로 추출
    tool_input = data.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    if not file_path:
        return

    filepath = Path(file_path)

    # wiki/ 하위 파일인지 확인
    try:
        rel = filepath.relative_to(WIKI_DIR)
    except ValueError:
        return

    # wiki/log/ 등 스킵 대상 확인
    parts = rel.parts
    if not parts:
        return
    if parts[0] in SKIP_DIRS:
        return
    # underscore/dot prefix 파일 skip (template, hidden) — 2026-04-29 추가
    if parts[-1].startswith("_") or parts[-1].startswith("."):
        return

    # 카테고리 결정 (첫 번째 디렉토리)
    category = str(Path(*parts[:-1])) if len(parts) > 1 else "root"

    # frontmatter 파싱
    fm = parse_frontmatter(filepath)
    title = fm.get("title", "")

    # 신규 생성인지 수정인지 판별
    tool_name = data.get("tool_name", "")
    action = "create" if tool_name == "Write" else "update"

    # index.md 갱신
    added = add_to_index(filepath, title, category)

    # log.md 갱신 (신규 등록 시에만)
    if added:
        add_to_log(filepath, title, action)


if __name__ == "__main__":
    main()
