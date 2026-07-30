#!/usr/bin/env python3
"""PostToolUse hook — Circuit Breaker

Detects repeated Bash failures within a sliding window and emits an `additionalContext`
warning advising the AI to change strategy. Prevents infinite retry loops on the same
broken command.

Threshold: 3 failures within 60 seconds (configurable via env vars).
State file: /tmp/agent-circuit-breaker.json (per-machine, ephemeral)

Hook protocol: reads canonical event JSON from stdin. Writes additionalContext JSON to
stdout when threshold crossed. Empty stdout otherwise. Exit always 0.

Failure classification — what the runtime actually gives us
-----------------------------------------------------------
MEASURED 2026-07-30 against the live installed hook: Claude Code's PostToolUse
payload carries **no exit status**. A probe pair proved it — `exit 3` with quiet
output was NOT recorded, while `exit 0` printing "0 errors" WAS recorded as a
failure. So two things follow:

1. An exit status is honoured when a runtime supplies one, and resolution keys
   off **presence**, not truthiness. The previous `result.get("exit_code") or
   result.get("exitCode")` discarded a successful `0` as falsy and fell through
   to the text heuristic — that is how a passing command got counted as a
   failure. When a status IS present it is the ONLY signal; text is not consulted.
2. On this runtime the text heuristic is the only live signal, so it is narrowed:
   zero-count phrasings ("0 errors", "no failures", "errors: 0") are scrubbed
   before failure vocabulary is matched, and matching is word-bounded rather
   than substring.

Known limitation, stated rather than papered over: with no exit status, a
failure that prints nothing recognisable is invisible here. This hook is an
advisory nudge and never a gate, so a miss costs a missing hint — not a wrong
block. Closing it properly needs an exit status from the runtime (backlog X-3
adds a sink so the residual false-positive/negative rate can be measured).
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

STATE_FILE = Path(os.environ.get("AGENT_CIRCUIT_BREAKER_STATE", "/tmp/agent-circuit-breaker.json"))
WINDOW_SECONDS = int(os.environ.get("AGENT_CIRCUIT_BREAKER_WINDOW", "60"))
THRESHOLD = int(os.environ.get("AGENT_CIRCUIT_BREAKER_THRESHOLD", "3"))


def load_state() -> list:
    if not STATE_FILE.exists():
        return []
    try:
        data = json.loads(STATE_FILE.read_text())
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def save_state(records: list) -> None:
    try:
        STATE_FILE.write_text(json.dumps(records))
    except OSError:
        pass


# Zero-count phrasings a PASSING run prints. Scrubbed before failure matching so
# "0 errors" / "no failures" / "errors: 0" cannot read as a failure.
_ZERO_COUNT_RE = re.compile(
    r"(?i)\b(?:0|no|zero)\s+(?:errors?|failures?|failed|warnings?)\b"
    r"|\b(?:errors?|failures?)\s*[:=]\s*0\b"
)
# Failure vocabulary. Word-bounded: the old substring test matched "error" inside
# unrelated words, and it missed both `Traceback` and `command not found`.
_FAILURE_RE = re.compile(
    r"(?i)traceback"
    r"|command not found"
    r"|no such file or directory"
    r"|syntaxerror"
    r"|\berror(?:s|ed)?\b"
    r"|\bfail(?:s|ed|ure|ures)?\b"
)


def resolve_exit_status(result) -> int | None:
    """Exit status from the event, or None when the runtime supplied none.

    Keys off PRESENCE: a successful command reports `0`, and an `or` chain would
    discard that `0` as falsy and silently fall through to the text heuristic.
    A bool is rejected — `True`/`False` is a success flag, not an exit status.
    """
    if not isinstance(result, dict):
        return None
    for key in ("exit_code", "exitCode"):
        if key in result:
            value = result[key]
            if isinstance(value, bool):
                continue
            if isinstance(value, int):
                return value
            if isinstance(value, str):
                text = value.strip()
                if text.lstrip("-").isdigit():
                    return int(text)
    return None


def looks_like_failure(result_text: str) -> bool:
    """Last-resort text signal, consulted ONLY when no exit status is available."""
    head = result_text[:500]
    if not head.strip():
        return False
    return bool(_FAILURE_RE.search(_ZERO_COUNT_RE.sub(" ", head)))


def extract_error_signature(result_text: str) -> str:
    lines = result_text.strip().split("\n")
    for line in reversed(lines):
        stripped = line.strip()
        if stripped and len(stripped) > 10:
            return stripped[:120]
    return result_text[:120] if result_text else "unknown"


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        return

    tool_name = data.get("tool_name", "")
    if tool_name != "Bash":
        return

    result = data.get("tool_result") or data.get("tool_response") or {}
    result_text = ""
    if isinstance(result, dict):
        result_text = result.get("stderr", "") or result.get("stdout", "")
    elif isinstance(result, str):
        result_text = result

    # A machine-reported exit status is authoritative and exclusive; text is a
    # fallback only. See the module docstring for why both paths exist.
    exit_status = resolve_exit_status(result)
    if exit_status is not None:
        is_error = exit_status != 0
    else:
        is_error = looks_like_failure(result_text)

    now = time.time()

    if not is_error:
        records = load_state()
        records = [r for r in records if now - r.get("ts", 0) < WINDOW_SECONDS]
        save_state(records)
        return

    signature = extract_error_signature(result_text)
    records = load_state()
    records = [r for r in records if now - r.get("ts", 0) < WINDOW_SECONDS]
    records.append({"ts": now, "sig": signature})
    save_state(records)

    if len(records) >= THRESHOLD:
        short_sig = signature[:60]
        similar = sum(1 for r in records if r.get("sig", "")[:60] == short_sig)

        if similar >= THRESHOLD:
            msg = (
                f"Circuit Breaker: same error repeated {similar} times in {WINDOW_SECONDS}s. "
                f"Change your approach — the current strategy is not working. "
                f"Error pattern: {short_sig}..."
            )
        else:
            msg = (
                f"Circuit Breaker: {len(records)} errors in {WINDOW_SECONDS}s. "
                f"Multiple failures detected — consider a different approach."
            )

        output = {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": msg,
            }
        }
        print(json.dumps(output))
        save_state([])


if __name__ == "__main__":
    main()
