#!/usr/bin/env python3
"""Stop Hook: 정본 13체계 변경 시 wiki supersede 후보 자동 탐지.

claude-mem-watch.py 가 .claude/logs/claude-mem-watch.jsonl 에 기록한 정본 13체계
mtime + sha256 history 를 분석. last-run marker 이후 *hash 가 바뀐* 정본 path 를
찾아, 그 키워드가 등장하는 wiki/architecture/ + wiki/concepts/ 페이지를
`Obsidian-airlens/wiki/_supersede-suggestions.md` 에 후보로 append.

opt-in 설계 — 후보 *제안* 만, 자동 마커 추가 X. /wiki-supersede-apply skill 이
사용자 confirm 후 후보 → 실제 마커 적용.

best-effort + idempotent + silent. last-run marker 로 중복 후보 회피.

Refs:
- Plan: ~/.claude/plans/inherited-wobbling-frog.md (Phase 2.C)
- Source: scripts/hooks/claude-mem-watch.py (Stop hook, jsonl 작성)
- Policy: .claude/rules/external-plugin-policy.md C2 (정본 13체계 본문 자동 갱신 차단)
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

_HERE = Path(__file__).resolve().parents[2]


def _resolve_main_root() -> Path:
    """worktree → 메인 트리 root resolve. 메인 트리는 그대로."""
    if (_HERE / "Obsidian-airlens").exists():
        return _HERE
    git_marker = _HERE / ".git"
    if git_marker.is_file():
        try:
            for line in git_marker.read_text().splitlines():
                if line.startswith("gitdir:"):
                    gitdir = Path(line.split(":", 1)[1].strip())
                    return gitdir.parents[2].resolve()
        except (OSError, IndexError):
            pass
    return _HERE


MAIN_ROOT = _resolve_main_root()
JSONL_PATH = MAIN_ROOT / ".claude/logs/claude-mem-watch.jsonl"
MARKER_PATH = MAIN_ROOT / ".claude/logs/wiki-supersede-last-run.txt"
WIKI_ROOT = MAIN_ROOT / "Obsidian-airlens"
SUGGEST_PATH = WIKI_ROOT / "wiki" / "_supersede-suggestions.md"
SCAN_DIRS = [
    WIKI_ROOT / "wiki" / "architecture",
    WIKI_ROOT / "wiki" / "concepts",
]


def parse_iso(ts: str) -> int:
    """ISO timestamp → epoch seconds. 0 on failure."""
    try:
        return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
    except (ValueError, AttributeError):
        return 0


def read_marker() -> int:
    try:
        return int(MARKER_PATH.read_text().strip())
    except (OSError, ValueError):
        return 0


def write_marker(ts: int) -> None:
    try:
        MARKER_PATH.parent.mkdir(parents=True, exist_ok=True)
        MARKER_PATH.write_text(f"{ts}\n", encoding="utf-8")
    except OSError:
        pass


def load_entries(since: int) -> list[dict]:
    """jsonl entries with ts > since (epoch)."""
    if not JSONL_PATH.exists():
        return []
    entries: list[dict] = []
    try:
        with JSONL_PATH.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts_epoch = parse_iso(obj.get("ts", ""))
                if ts_epoch > since:
                    obj["_ts_epoch"] = ts_epoch
                    entries.append(obj)
    except OSError:
        return []
    return entries


def detect_changed_canonicals(entries: list[dict]) -> list[str]:
    """Return canonical paths whose hash changed within the entry window."""
    history: dict[str, list[str]] = {}
    for entry in sorted(entries, key=lambda e: e.get("_ts_epoch", 0)):
        for f in entry.get("files", []):
            path = f.get("path", "")
            h = f.get("hash")
            if not path or h is None:
                continue
            history.setdefault(path, []).append(h)

    # need *baseline* hash before window — read full jsonl to get pre-window
    # Simplified: any path with multiple distinct hashes within window = changed
    changed = []
    for path, hashes in history.items():
        unique = {h for h in hashes if h}
        if len(unique) > 1 and "raw/docs/" in path:
            changed.append(path)
    return changed


def keywords_for(canonical_path: str) -> list[str]:
    """Derive grep keywords from canonical path stem.

    e.g. 'Obsidian-airlens/raw/docs/web/WEB_PRD.md' →
         ['WEB_PRD', 'WEB PRD', 'Web PRD', 'web/WEB_PRD']
    """
    stem = Path(canonical_path).stem  # 'WEB_PRD'
    spaced = stem.replace("_", " ")
    return list({stem, spaced, spaced.title(), f"{Path(canonical_path).parent.name}/{stem}"})


def scan_wiki(canonicals: list[str]) -> list[tuple[Path, str, list[str]]]:
    """Find wiki pages mentioning canonical keywords WITHOUT existing supersede marker.

    Returns [(wiki_path, canonical_path, matched_keywords)].
    """
    candidates: list[tuple[Path, str, list[str]]] = []
    for canonical in canonicals:
        kws = keywords_for(canonical)
        for scan_dir in SCAN_DIRS:
            if not scan_dir.exists():
                continue
            for wiki_path in scan_dir.rglob("*.md"):
                try:
                    text = wiki_path.read_text(encoding="utf-8")
                except OSError:
                    continue
                if "superseded_by:" in text:
                    continue
                matched = [kw for kw in kws if kw and kw in text]
                if matched:
                    candidates.append((wiki_path, canonical, matched))
    return candidates


def append_suggestions(
    candidates: list[tuple[Path, str, list[str]]],
    run_ts: int,
) -> None:
    if not candidates:
        return

    is_new = not SUGGEST_PATH.exists()
    when = datetime.fromtimestamp(run_ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    parts: list[str] = []

    if is_new:
        parts.append(
            "---\n"
            "type: supersede-suggestions\n"
            "auto_appended: true\n"
            "---\n\n"
            "# Supersede 후보 (auto-appended)\n\n"
            "정본 13 체계 변경 시 `wiki-supersede-suggest.py` 가 자동 탐지한 후보 누적.\n"
            "각 항목은 *제안*. `/wiki-supersede-apply` 로 사용자 confirm 후 실 마커 적용.\n"
        )

    parts.append(f"\n## {when}\n")
    for wiki_path, canonical, matched in candidates:
        try:
            rel_wiki = wiki_path.relative_to(WIKI_ROOT)
        except ValueError:
            rel_wiki = wiki_path
        parts.append(
            f"- [[{rel_wiki}]] — canonical changed: `{canonical}` "
            f"(keywords: {', '.join(repr(m) for m in matched)})"
        )

    SUGGEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    if is_new:
        SUGGEST_PATH.write_text("\n".join(parts) + "\n", encoding="utf-8")
    else:
        existing = SUGGEST_PATH.read_text(encoding="utf-8").rstrip()
        SUGGEST_PATH.write_text(existing + "\n" + "\n".join(parts) + "\n", encoding="utf-8")


def main() -> None:
    try:
        sys.stdin.read()
    except OSError:
        pass

    since = read_marker()
    now = int(datetime.now(tz=timezone.utc).timestamp())

    entries = load_entries(since=since)
    if not entries:
        write_marker(now)
        return

    canonicals = detect_changed_canonicals(entries)
    if not canonicals:
        write_marker(now)
        return

    candidates = scan_wiki(canonicals)
    if candidates:
        append_suggestions(candidates, now)

    write_marker(now)


if __name__ == "__main__":
    main()
