#!/usr/bin/env python3
"""
tdd-guard PostToolUse Bash hook (Phase 1.2).

Detects vitest/test invocations from user shell commands and spawns
tdd-guard-refresh.sh in background (fully detached).

Triggers on: (npm|npx|pnpm|yarn) (run )?(test|test:run|vitest)
Skips: --reporter=json (avoid loop), test:e2e, test:visual, test:coverage, playwright.

Silent. Returns immediately after spawn (background subprocess inherits no FDs).
Plan: ~/.claude/plans/tdd-guard-self-strengthen-frosted-mason.md §1.2
"""
import sys
import json
import re
import os
import subprocess

TRIGGER_RE = re.compile(
    r"\b(npm|npx|pnpm|yarn)\s+(run\s+)?(test(:run)?|vitest)\b"
)
SKIP_KEYWORDS = [
    "--reporter=json",
    "test:e2e",
    "test:visual",
    "test:coverage",
    "playwright",
]


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        sys.exit(0)

    cmd = data.get("tool_input", {}).get("command", "") or ""
    if not cmd or not TRIGGER_RE.search(cmd):
        sys.exit(0)
    if any(kw in cmd for kw in SKIP_KEYWORDS):
        sys.exit(0)

    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        sys.exit(0)

    refresh = os.path.join(root, "scripts/hooks/tdd-guard-refresh.sh")
    if not os.path.isfile(refresh):
        sys.exit(0)

    try:
        subprocess.Popen(
            ["bash", refresh],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
