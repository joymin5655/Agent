#!/usr/bin/env python3
"""PostToolUse Bash hook — broadcast committed/pr_opened events.

Plan: ~/.claude/plans/session-awareness-hook-gaps.md (Phase 3, G4).

Reads the PostToolUse JSON from stdin, inspects `tool_input.command`, and when
it matches `git commit` (with a successful tool_response) or `gh pr create`,
calls `agent-session.sh broadcast committed|pr_opened ...`.

Silent + best-effort: never blocks claude. Skips when the lock script is
missing (gitignored hooks dir), command does not match, or tool_response
indicates failure.

Wire-up (`.claude/settings.local.json`):
  PostToolUse Bash matcher → `python3 scripts/hooks/broadcast-on-bash.py`
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SESSION_SH = REPO_ROOT / "scripts" / "infra" / "agent-session.sh"

# `git commit` matchers — exclude `--amend` (would double-broadcast) and
# pre-commit autofixes (`git commit --fixup ...`). Allow short and long forms.
GIT_COMMIT_RE = re.compile(
    r"\bgit\s+(?:-c\s+\S+\s+)*commit\b(?!.*\s(?:--amend|--fixup|--squash)\b)"
)

# `gh pr create` matcher — also catches `gh pr edit` if invoked with create-like
# flags? No, keep narrow.
GH_PR_CREATE_RE = re.compile(r"\bgh\s+pr\s+create\b")


def _read_stdin() -> dict:
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _broadcast(event: str, message: str, files: list[str] | None = None) -> None:
    if not SESSION_SH.is_file() or not os.access(SESSION_SH, os.X_OK):
        return
    args = [str(SESSION_SH), "broadcast", event, message]
    if files:
        args += ["--files", ",".join(files)]
    try:
        subprocess.run(
            args,
            cwd=str(REPO_ROOT),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        pass


def _last_commit_oneline() -> str:
    """Best-effort: return short SHA + subject of HEAD. Used as the
    `committed` message body."""
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "log", "-1", "--pretty=format:%h %s"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        return out.stdout.strip() or "(no log)"
    except (subprocess.TimeoutExpired, OSError):
        return "(no log)"


def _last_commit_files() -> list[str]:
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "show", "--name-only", "--format=", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        return [
            line.strip()
            for line in out.stdout.splitlines()
            if line.strip()
        ][:20]  # cap files for jsonl size
    except (subprocess.TimeoutExpired, OSError):
        return []


def _gh_pr_url_from_response(response: dict) -> str | None:
    """`gh pr create` typically prints the PR URL on its last line. The
    PostToolUse payload's tool_response usually includes that stdout."""
    if not isinstance(response, dict):
        return None
    body = response.get("output") or response.get("stdout") or ""
    if not isinstance(body, str):
        return None
    for line in reversed(body.splitlines()):
        line = line.strip()
        if line.startswith("https://github.com/") and "/pull/" in line:
            return line
    return None


def _looks_successful(payload: dict) -> bool:
    """Treat hook payload as success unless it explicitly says otherwise."""
    response = payload.get("tool_response")
    if isinstance(response, dict):
        # Anthropic's PostToolUse uses `interrupted`/`is_error` keys.
        if response.get("is_error") or response.get("interrupted"):
            return False
    return True


def main() -> int:
    payload = _read_stdin()
    if not payload:
        return 0

    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command:
        return 0

    if not _looks_successful(payload):
        return 0

    if GIT_COMMIT_RE.search(command):
        _broadcast("committed", _last_commit_oneline(), _last_commit_files())
        return 0

    if GH_PR_CREATE_RE.search(command):
        response = payload.get("tool_response") or {}
        url = _gh_pr_url_from_response(response) or "(url not captured)"
        _broadcast("pr_opened", url)
        return 0

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Best-effort hook — never block claude on internal error.
        sys.exit(0)
