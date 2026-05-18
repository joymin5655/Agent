#!/usr/bin/env python3
"""
Session Indexer — FTS5 기반 과거 세션 검색 (Hermes session_search_tool.py 패턴 포팅)

Usage:
    python3 scripts/session-indexer.py --query "AOD 보정"
    python3 scripts/session-indexer.py --reindex
    python3 scripts/session-indexer.py --query "Globe 페이지" --top 5

Output: JSON array of matching sessions with relevance scores
"""

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

# Paths
PLATFORM_ROOT = Path(__file__).resolve().parent.parent
SESSIONS_DIR = PLATFORM_ROOT / "Obsidian-airlens" / "raw" / "sessions"
DB_PATH = PLATFORM_ROOT / "memory" / "sessions" / "session-index.db"
MEMORY_SHARED = PLATFORM_ROOT / "memory" / "shared"

MAX_CONTENT_CHARS = 100_000
TOP_K_DEFAULT = 3


def create_db(conn: sqlite3.Connection) -> None:
    """Create FTS5 virtual table and metadata table."""
    conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS sessions "
        "USING fts5(filename, title, content, tokenize='unicode61')"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS session_meta ("
        "  filename TEXT PRIMARY KEY,"
        "  indexed_at TEXT,"
        "  file_mtime REAL"
        ")"
    )
    conn.commit()


def parse_session_file(filepath: Path) -> dict:
    """Extract title and content from a session markdown file."""
    text = filepath.read_text(encoding="utf-8", errors="replace")
    lines = text.split("\n")

    title = filepath.stem
    for line in lines[:10]:
        if line.startswith("# "):
            title = line[2:].strip()
            break

    return {
        "filename": filepath.name,
        "title": title,
        "content": text[:MAX_CONTENT_CHARS],
    }


def needs_reindex(conn: sqlite3.Connection, filepath: Path) -> bool:
    """Check if a file needs re-indexing based on mtime."""
    row = conn.execute(
        "SELECT file_mtime FROM session_meta WHERE filename = ?",
        (filepath.name,),
    ).fetchone()
    if row is None:
        return True
    return filepath.stat().st_mtime > row[0]


def index_sessions(conn: sqlite3.Connection, force: bool = False) -> int:
    """Index all session files into FTS5. Returns count of indexed files."""
    if not SESSIONS_DIR.exists():
        return 0

    md_files = sorted(SESSIONS_DIR.glob("*.md"))
    md_files.extend(sorted(SESSIONS_DIR.glob("archive/**/*.md")))
    indexed = 0

    for filepath in md_files:
        if not force and not needs_reindex(conn, filepath):
            continue

        # Remove old entry if exists
        conn.execute(
            "DELETE FROM sessions WHERE filename = ?", (filepath.name,)
        )
        conn.execute(
            "DELETE FROM session_meta WHERE filename = ?", (filepath.name,)
        )

        parsed = parse_session_file(filepath)
        conn.execute(
            "INSERT INTO sessions (filename, title, content) VALUES (?, ?, ?)",
            (parsed["filename"], parsed["title"], parsed["content"]),
        )
        conn.execute(
            "INSERT INTO session_meta (filename, indexed_at, file_mtime) "
            "VALUES (?, ?, ?)",
            (
                filepath.name,
                datetime.now().isoformat(),
                filepath.stat().st_mtime,
            ),
        )
        indexed += 1

    conn.commit()
    return indexed


def extract_date(filename: str) -> str:
    """Extract date from filename like 2026-04-08-topic.md."""
    match = re.match(r"(\d{4}-\d{2}-\d{2})", filename)
    return match.group(1) if match else "unknown"


def summarize_match(content: str, query: str, max_chars: int = 500) -> str:
    """Extract relevant snippet around query matches."""
    content_lower = content.lower()
    query_terms = query.lower().split()

    best_pos = 0
    for term in query_terms:
        pos = content_lower.find(term)
        if pos >= 0:
            best_pos = pos
            break

    start = max(0, best_pos - max_chars // 2)
    end = min(len(content), best_pos + max_chars // 2)

    snippet = content[start:end].strip()
    if start > 0:
        snippet = "..." + snippet
    if end < len(content):
        snippet = snippet + "..."

    return snippet


def search_sessions(
    conn: sqlite3.Connection, query: str, top_k: int = TOP_K_DEFAULT
) -> list:
    """Search sessions using FTS5 and return top matches."""
    # Ensure index is up to date
    index_sessions(conn)

    rows = conn.execute(
        "SELECT filename, title, snippet(sessions, 2, '>>>', '<<<', '...', 64), "
        "rank FROM sessions WHERE sessions MATCH ? "
        "ORDER BY rank LIMIT ?",
        (query, top_k),
    ).fetchall()

    results = []
    for filename, title, snippet, rank in rows:
        results.append(
            {
                "session_id": filename.replace(".md", ""),
                "date": extract_date(filename),
                "title": title,
                "snippet": snippet,
                "relevance_score": round(-rank, 4),
            }
        )

    return results


def main() -> None:
    parser = argparse.ArgumentParser(description="Session Indexer (FTS5)")
    parser.add_argument("--query", "-q", type=str, help="Search query")
    parser.add_argument(
        "--reindex", action="store_true", help="Force full reindex"
    )
    parser.add_argument(
        "--top", "-k", type=int, default=TOP_K_DEFAULT, help="Top K results"
    )
    parser.add_argument(
        "--output", "-o", type=str, help="Output file path (default: stdout)"
    )
    args = parser.parse_args()

    # Ensure DB directory exists
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(DB_PATH))
    create_db(conn)

    if args.reindex:
        count = index_sessions(conn, force=True)
        print(json.dumps({"action": "reindex", "indexed": count}))
        conn.close()
        return

    if not args.query:
        parser.print_help()
        conn.close()
        sys.exit(1)

    results = search_sessions(conn, args.query, args.top)
    output = json.dumps(results, ensure_ascii=False, indent=2)

    if args.output:
        Path(args.output).write_text(output, encoding="utf-8")
    else:
        print(output)

    conn.close()


if __name__ == "__main__":
    main()
