#!/usr/bin/env python3
"""AirLens — Stop hook for Claude Mem T+30d analysis.

Logs mtime + sha256 hash + size of canonical-13 protected paths to
.claude/logs/claude-mem-watch.jsonl on every session Stop event.

Purpose: Claude Mem (thedotmack/claude-mem v12.6.5) auto-capture runs
PostToolUse `*` matcher and writes via Node fs.writeFileSync, bypassing
Claude Code tool layer. PreToolUse hooks cannot intercept. This hook
provides observability — at T+30d (2026-06-05) the log is analyzed for
unauthorized modifications to inform `/plugin disable claude-mem` decision.

No alert, no block — silent observability. Output: stop hook continue.

Refs:
- Plan: ~/.claude/plans/snazzy-stargazing-hartmanis.md
- Policy: .claude/rules/external-plugin-policy.md §3 F + §7 (2) (b)
"""

import hashlib
import json
import sys
import time
from pathlib import Path

# Canonical-13 protected paths (CLAUDE.md 4 + Obsidian docs 9).
# Auto-update when canonical structure changes.
PROTECTED_PATHS = [
    "CLAUDE.md",
    "apps/web/CLAUDE.md",
    "apps/app/CLAUDE.md",
    "models/CLAUDE.md",
    "Obsidian-airlens/raw/docs/platform/PLATFORM_PRD.md",
    "Obsidian-airlens/raw/docs/platform/PLATFORM_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/web/WEB_PRD.md",
    "Obsidian-airlens/raw/docs/web/WEB_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/app/APP_PRD.md",
    "Obsidian-airlens/raw/docs/app/APP_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/ml/MODELS_PRD.md",
    "Obsidian-airlens/raw/docs/ml/MODELS_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/db/DATABASE_SCHEMA.md",
    "Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md",
]

LOG_PATH = ".claude/logs/claude-mem-watch.jsonl"


def measure(path: str) -> dict:
    p = Path(path)
    if not p.is_file():
        return {"path": path, "mtime": None, "hash": None, "size": None}
    try:
        stat = p.stat()
        h = hashlib.sha256(p.read_bytes()).hexdigest()[:8]
        return {"path": path, "mtime": int(stat.st_mtime), "hash": h, "size": stat.st_size}
    except (OSError, PermissionError):
        return {"path": path, "mtime": None, "hash": None, "size": None}


def main() -> None:
    session_id = "unknown"
    try:
        raw = sys.stdin.read()
        if raw.strip():
            ctx = json.loads(raw)
            session_id = ctx.get("session_id") or ctx.get("sessionId") or "unknown"
    except (json.JSONDecodeError, ValueError):
        pass

    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "session_id": session_id,
        "files": [measure(p) for p in PROTECTED_PATHS],
    }

    log = Path(LOG_PATH)
    try:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except (OSError, PermissionError) as exc:
        sys.stderr.write(f"claude-mem-watch: log write failed: {exc}\n")

    print(json.dumps({"continue": True, "suppressOutput": True}))


if __name__ == "__main__":
    main()
