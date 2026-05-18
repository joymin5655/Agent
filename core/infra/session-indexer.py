#!/usr/bin/env python3
"""Session Indexer — FTS5-backed search across saved session markdown files.

Usage:
    python3 core/infra/session-indexer.py --query "auth refactor"
    python3 core/infra/session-indexer.py --reindex
    python3 core/infra/session-indexer.py --query "globe page" --top 5

Output: JSON array of matching sessions with relevance scores.

Configuration (env vars):
    AGENT_SESSIONS_DIR  — directory containing session *.md files
                          (default: $REPO_ROOT/wiki/sessions)
    AGENT_SESSIONS_DB   — SQLite db path
                          (default: $REPO_ROOT/.agent/state/session-index.db)
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def _repo_root() -> Path:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            return Path(result.stdout.strip())
    except FileNotFoundError:
        pass
    return Path.cwd()


REPO_ROOT = _repo_root()
SESSIONS_DIR = Path(
    os.environ.get("AGENT_SESSIONS_DIR", REPO_ROOT / "wiki" / "sessions")
)
DB_PATH = Path(
    os.environ.get("AGENT_SESSIONS_DB", REPO_ROOT / ".agent" / "state" / "session-index.db")
)

MAX_CONTENT_CHARS = 100_000
TOP_K_DEFAULT = 3


def create_db(conn: sqlite3.Connection) -> None:
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
    row = conn.execute(
        "SELECT file_mtime FROM session_meta WHERE filename = ?",
        (filepath.name,),
    ).fetchone()
    if row is None:
        return True
    return filepath.stat().st_mtime > row[0]


def index_sessions(conn: sqlite3.Connection, force: bool = False) -> int:
    if not SESSIONS_DIR.exists():
        return 0

    md_files = sorted(SESSIONS_DIR.glob("*.md"))
    md_files.extend(sorted(SESSIONS_DIR.glob("archive/**/*.md")))
    indexed = 0

    for filepath in md_files:
        if not force and not needs_reindex(conn, filepath):
            continue

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
    match = re.match(r"(\d{4}-\d{2}-\d{2})", filename)
    return match.group(1) if match else "unknown"


def search_sessions(
    conn: sqlite3.Connection, query: str, top_k: int = TOP_K_DEFAULT
) -> list:
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
