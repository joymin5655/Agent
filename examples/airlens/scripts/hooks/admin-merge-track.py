#!/usr/bin/env python3
"""PostToolUse Bash hook — track `gh pr merge --admin` evidence.

Policy SOT: `.claude/rules/policy/actions-billing-admin-merge.md` §"evidence jsonl".

Appends one record per successful admin-merge dispatch to
`.claude/logs/admin-merge.jsonl` (gitignored). Used for T+30d (2026-06-12)
PRIVATE → PUBLIC re-transition decision when Actions billing pattern can be
deprecated.

Silent + best-effort: never blocks claude.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
LOG_PATH = REPO_ROOT / ".claude" / "logs" / "admin-merge.jsonl"

ADMIN_MERGE_RE = re.compile(r"\bgh\s+pr\s+merge\s+(?:#)?(\d+)\b[^\n]*?\s--admin\b")


def _read_stdin() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _looks_successful(payload: dict) -> bool:
    response = payload.get("tool_response")
    if isinstance(response, dict):
        if response.get("is_error") or response.get("interrupted"):
            return False
    return True


def _session_id(payload: dict) -> str:
    sid = payload.get("session_id")
    if isinstance(sid, str) and sid:
        return sid
    return os.environ.get("CLAUDE_SESSION_ID") or "unknown"


def main() -> int:
    payload = _read_stdin()
    if not payload:
        return 0

    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str):
        return 0

    first_line = command.split("\n", 1)[0]
    match = ADMIN_MERGE_RE.search(first_line)
    if not match:
        return 0

    if not _looks_successful(payload):
        return 0

    record = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pr": int(match.group(1)),
        "command": first_line[:500],
        "session_id": _session_id(payload),
        "schema_version": "1.1.0",
    }

    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
