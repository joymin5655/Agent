#!/usr/bin/env python3
"""PostToolUse hook — verification observer.

Records that a verification command was INVOKED in this session. Nothing else.
The Stop gate (core/hooks/session-quality-gate.py) reads these records and, when
the session diff carries code changes but no verification command was ever
invoked, emits an advisory note.

Why this exists
---------------
`session.completion_tests` (P3-1) only enforces where a project declares it.
docs/hook-config.md is explicit: "Unset/empty => the gate does nothing". The gate
registry already recorded the consequence — `quality-completion` shows zero
firings locally because no consumer declares completion_tests — so a session can
rewrite code from end to end, run nothing, and end clean. This observer closes
that specific hole with the one signal that needs no project config: did the
session run anything at all.

What it deliberately does NOT do
--------------------------------
It never claims a verification PASSED. Claude Code's PostToolUse payload carries
no exit status (measured 2026-07-30 — see core/hooks/circuit-breaker.py for the
probe pair and the narrowed text heuristic it forced). Inferring pass/fail from
output text is exactly the misclassification that defect was: a passing command
printing "0 errors" read as a failure. So the record is presence-only —
"a verification command was invoked, family X" — and the advisory wording never
asserts an outcome.

It also stores no command text. A command line can carry a token or a URL with
credentials; a family label ("tests", "lint", "typecheck", "build", "battery")
is all the Stop gate needs, so the raw string is never written and there is no
redaction surface to get wrong.

Protocol: canonical event JSON on stdin, ALWAYS zero bytes on stdout (pure
observer — docs/hook-protocol.md §3 critical rule), always exit 0.

Env seams:
  AGENT_VERIFY_OBSERVED_SINK   override the sink path (confined to the repo's
                               .agent/logs or the system temp dir; an escaping
                               value falls back to the default)
  AGENT_REPRODUCE_TEST=1       mark records reproduce_test:true so battery-fed
                               synthetic events never inflate the fire rate
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

SCHEMA_VERSION = "1.0.0"
GUARD = "verify-observed"
HOOK_NAME = "verify-observer.py"
SINK_NAME = "verify-observed.jsonl"

# Verification families. Each pattern requires the runner token in context — a
# bare \btest\b would match `cat test.txt` and a bare \bcheck\b would match
# `git checkout`, which would silently mark an unverified session as verified.
# False negatives here are safe (they can only produce an advisory that is
# already the default posture); false positives are not, so the patterns stay
# narrow and are extended only with evidence.
_FAMILIES: tuple[tuple[str, str], ...] = (
    (
        "battery",
        r"(?:^|[\s;&|])bash\s+\S*core/tests/\S+"
        r"|(?:^|[\s;&|])\S*verify-all\.sh\b",
    ),
    (
        "tests",
        r"\bpytest\b"
        r"|\bpython[0-9.]*\s+-m\s+(?:pytest|unittest)\b"
        r"|\bgo\s+test\b"
        r"|\bcargo\s+test\b"
        r"|\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test\b"
        r"|\b(?:mvn|gradle)\s+test\b"
        r"|\b(?:rspec|vitest|jest|playwright|cypress)\b",
    ),
    (
        "typecheck",
        r"\btsc\b|--noEmit\b|\b(?:mypy|pyright)\b",
    ),
    (
        "lint",
        r"\b(?:eslint|ruff|flake8|shellcheck|golangci-lint)\b"
        r"|\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?lint\b",
    ),
    (
        "build",
        r"\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?build\b"
        r"|\bcargo\s+build\b|\bgo\s+build\b|\bmake\s+build\b",
    ),
)
_COMPILED = tuple((name, re.compile(pattern, re.IGNORECASE)) for name, pattern in _FAMILIES)


def resolve_root(event: dict) -> str:
    """Active project root — same precedence as session-quality-gate.py so both
    halves of this feature agree on which project's ledger they are touching."""
    cwd = event.get("cwd") if isinstance(event, dict) else ""
    return cwd or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def default_sink(root: str) -> str:
    return os.path.join(root, ".agent", "logs", SINK_NAME)


def resolve_sink(root: str) -> str:
    """Sink path, with an override confined to the project's own .agent/logs or
    the system temp dir. Confinement is decided on the REALPATH, so a symlink or
    a '../' segment cannot redirect writes outside those roots (a lexical prefix
    test would pass '<root>/.agent/logs/../../../etc/x')."""
    override = os.environ.get("AGENT_VERIFY_OBSERVED_SINK")
    fallback = default_sink(root)
    if not override:
        return fallback
    try:
        candidate = os.path.realpath(override)
        allowed = [
            os.path.realpath(os.path.join(root, ".agent", "logs")),
            os.path.realpath(tempfile.gettempdir()),
        ]
    except OSError:
        return fallback
    for base in allowed:
        if candidate == base or candidate.startswith(base + os.sep):
            return override
    return fallback


def match_family(command: str) -> str | None:
    """First matching verification family, or None."""
    if not command:
        return None
    for name, pattern in _COMPILED:
        if pattern.search(command):
            return name
    return None


def command_from_event(event: dict) -> str:
    tool_input = event.get("tool_input")
    if isinstance(tool_input, dict):
        value = tool_input.get("command")
        return value if isinstance(value, str) else ""
    if isinstance(tool_input, str):
        return tool_input
    return ""


def append_record(sink: str, record: dict) -> None:
    """Append one JSON line. Never raises — an unwritable sink must not turn an
    observation hook into a broken tool call."""
    try:
        os.makedirs(os.path.dirname(sink), exist_ok=True)
        with open(sink, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError, ValueError):
        return 0
    if not isinstance(event, dict):
        return 0
    if str(event.get("tool_name") or "") != "Bash":
        return 0

    family = match_family(command_from_event(event))
    if family is None:
        return 0

    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "guard": GUARD,
        "hook": HOOK_NAME,
        "schema_version": SCHEMA_VERSION,
        "session_id": str(event.get("session_id") or "no-session"),
        "event": "verification_invoked",
        "family": family,
    }
    if os.environ.get("AGENT_REPRODUCE_TEST") == "1":
        record["reproduce_test"] = True

    append_record(resolve_sink(resolve_root(event)), record)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Fail-open: an observer must never break a tool call on its own bug.
        sys.exit(0)
