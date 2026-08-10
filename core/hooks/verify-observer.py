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
import stat
import sys
import tempfile
from datetime import datetime, timezone

SCHEMA_VERSION = "1.0.0"
GUARD = "verify-observed"
HOOK_NAME = "verify-observer.py"
SINK_NAME = "verify-observed.jsonl"

# Verification families, matched at INVOCATION POSITION only.
#
# A pattern that merely contains a runner name is not enough, and the first cut
# of this hook got that wrong: `\bpytest\b` matched `pip install pytest-mock`
# (the hyphen satisfies the trailing word boundary), `\beslint\b` matched
# `which eslint`, and `\S*verify-all\.sh\b` matched `cat core/tests/verify-all.sh`.
# All eight probes in the review reproduced, i.e. eight ways to mark an
# unverified session "verified" — the one direction of error that matters here.
# So each command is split into segments and normalised to `<program> <rest>`
# (see `_invocations`), and every pattern below is anchored with `^`.
#
# Direction of error, stated once: a false NEGATIVE only produces the advisory
# that is already the default posture, so it is safe. A false POSITIVE hides the
# exact gap this hook exists to find. Exotic invocation forms are therefore left
# unmatched on purpose rather than covered by a loose pattern.
_FAMILIES: tuple[tuple[str, str], ...] = (
    (
        "battery",
        r"^(?:bash|sh|zsh)\s+\S*core/tests/\S+"
        r"|^\S*verify-all\.sh(?=\s|$)",
    ),
    (
        "tests",
        r"^pytest(?=\s|$)"
        r"|^python[0-9.]*\s+(?:-\S+\s+)*-m\s+(?:pytest|unittest)\b"
        r"|^(?:go|cargo|mvn|gradle)\s+test\b"
        r"|^(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test\b"
        r"|^(?:rspec|vitest|jest|playwright|cypress)(?=\s|$)",
    ),
    (
        "typecheck",
        r"^tsc(?=\s|$)"
        r"|^(?:mypy|pyright)(?=\s|$)"
        r"|^(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:tsc|typecheck)\b",
    ),
    (
        "lint",
        r"^(?:eslint|ruff|flake8|shellcheck|golangci-lint)(?=\s|$)"
        r"|^(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?lint\b",
    ),
    (
        "build",
        r"^(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?build\b"
        r"|^(?:cargo|go)\s+build\b"
        r"|^make\s+build\b",
    ),
)
# Case-SENSITIVE on purpose. `PYTEST -q` / `Make build` / `TSC --noEmit` are
# "command not found" on a case-sensitive filesystem — they execute nothing — yet
# an IGNORECASE match recorded them as verification (reproduced across all five
# families). Matching case-sensitively costs at most a false negative on a
# case-insensitive filesystem, where such a command really would run: the safe
# direction, per the note above.
_COMPILED = tuple((name, re.compile(pattern)) for name, pattern in _FAMILIES)

# Segment separators: a runner in `a && pytest` is invoked, one in `grep pytest x`
# is not. Splitting on these is what makes `^` anchoring meaningful.
_SEGMENT_RE = re.compile(r"(?:\|\||&&|[;\n|&()`]|\$\()")
# Leading env assignments (`FOO=bar pytest`).
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=\S*\s+")
# Wrappers that delegate to the real program; stripped so the program underneath
# lands at invocation position. Single tokens and two-token runner prefixes.
# No daemon-spawn tokens here: core/tests/supply-chain-scan.sh class 4 forbids
# them by literal in any auto-fired hook, and that gate is right — the cost of
# obeying it is one unmatched invocation form, i.e. a false negative in the
# already-safe direction. Working around the scanner instead would be the
# lint-tamper move this repo guards against.
_WRAPPERS_1 = ("sudo", "time", "env", "npx", "bunx", "xvfb-run", "command")
_WRAPPERS_2 = (
    ("pnpm", "exec"), ("pnpm", "dlx"), ("yarn", "dlx"), ("uv", "run"),
    ("poetry", "run"), ("pipenv", "run"), ("bundle", "exec"), ("npm", "exec"),
)
_MAX_COMMAND_CHARS = 8192


# A here-document body is DATA, not commands.
# The lookarounds exclude `<<<` (here-string). Without them this regex matched
# the LAST two angle brackets of `cat <<<pytest` and opened a here-doc with the
# delimiter `pytest`, swallowing every following line — including a real
# verification run — until a line happened to equal it. Safe direction (a
# spurious advisory), but it made the comment that claimed `<<<` was excluded
# false, which is the kind of confident-and-wrong note that survives review.
_HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)-?\s*(?P<delim>['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?)")
# Token separators INSIDE a segment: ASCII blanks only. Python's str.split() also
# splits on NBSP and other unicode spaces, which a shell does not — that would
# read `\xa0pytest` (a command that cannot even run) as an invocation of pytest.
_TOKEN_WS_RE = re.compile(r"[ \t\r\f\v]+")
_ASCII_BLANKS = " \t\r\f\v\n"


def _strip_heredoc_bodies(command: str) -> str:
    """Remove here-document bodies, keeping the command lines around them.

    Without this, `cat <<EOF` / `pytest -q` / `EOF` — a session writing docs that
    happen to SHOW a test command — records as if the tests had been run.
    """
    kept: list[str] = []
    delimiter = None
    for line in command.split("\n"):
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        kept.append(line)
        found = _HEREDOC_RE.search(line)
        if found:
            delimiter = found.group("delim").strip("\"'")
    return "\n".join(kept)


def _invocations(command: str) -> list[str]:
    """Normalise a command line into one `<program> <rest>` string per segment.

    The program is reduced to its basename, so `./node_modules/.bin/jest` and
    `/usr/local/bin/pytest` land at invocation position exactly like the bare
    name. Wrapper prefixes and leading env assignments are stripped so
    `FOO=1 npx tsc --noEmit` normalises to `tsc --noEmit`.
    """
    out: list[str] = []
    # Bound the input: the command string is model-controlled and unbounded, and
    # every pattern here runs over it. A verification invocation lives at the
    # head of a segment, so truncating cannot hide one that a shorter command
    # would have matched (same reasoning as circuit-breaker's result_text[:500]).
    text = command[:_MAX_COMMAND_CHARS]
    # A backslash-newline is a line CONTINUATION, not a command boundary:
    # `pip install \` + newline + `pytest` is one `pip install pytest`, and
    # splitting on the newline would read `pytest` as an invocation.
    text = text.replace("\\\n", " ")
    text = _strip_heredoc_bodies(text)
    for raw in _SEGMENT_RE.split(text):
        seg = raw.strip(_ASCII_BLANKS)
        # Bounded loop: each iteration removes a leading token, so it cannot spin.
        for _ in range(8):
            stripped = _ASSIGN_RE.sub("", seg, count=1)
            if stripped != seg:
                seg = stripped.strip(_ASCII_BLANKS)
                continue
            parts = [t for t in _TOKEN_WS_RE.split(seg) if t]
            if len(parts) >= 3 and (parts[0].lower(), parts[1].lower()) in _WRAPPERS_2:
                seg = " ".join(parts[2:])
                continue
            if len(parts) >= 2 and parts[0].lower() in _WRAPPERS_1:
                seg = " ".join(parts[1:])
                continue
            break
        parts = [t for t in _TOKEN_WS_RE.split(seg) if t]
        if not parts:
            continue
        program = os.path.basename(parts[0])
        out.append(" ".join([program] + parts[1:]))
    return out


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
            # Return the RESOLVED path, not the override string. Returning the
            # unresolved value re-opened the symlink later, so a swap between
            # this check and the open could redirect the write to a regular file
            # anywhere (the S_ISREG guard rejects device nodes, not locations).
            return candidate
    return fallback


def match_family(command: str) -> str | None:
    """First matching verification family, or None.

    Matches only at invocation position (see `_FAMILIES`): `pytest -q` records,
    `pip install pytest-mock` does not.
    """
    if not command:
        return None
    for invocation in _invocations(command):
        for name, pattern in _COMPILED:
            if pattern.match(invocation):
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
    """Append one JSON line. Never raises, and never blocks.

    The sink must be a REGULAR FILE. A plain `open(sink, "a")` blocks forever on
    a FIFO with no reader, and this path needs no environment variable to reach:
    a project shipping a FIFO at `.agent/logs/verify-observed.jsonl` would hang
    every Bash tool call in that project (measured 2026-07-30 — the writer and
    the Stop-gate reader both hung indefinitely on the default path).

    O_NONBLOCK makes the open itself fail fast (ENXIO on a reader-less FIFO)
    instead of hanging, and the fstat is taken on the DESCRIPTOR, so a symlink
    swapped in between resolve and open cannot slip a non-regular file past the
    check the way a stat-then-open sequence could.
    """
    try:
        os.makedirs(os.path.dirname(sink), exist_ok=True)
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NONBLOCK", 0)
        fd = os.open(sink, flags, 0o600)
    except Exception:
        return
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fd = -1
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
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
