#!/usr/bin/env python3
"""PostToolUse hook — Circuit Breaker

Detects repeated Bash failures within a sliding window and emits an `additionalContext`
warning advising the AI to change strategy. Prevents infinite retry loops on the same
broken command.

Threshold: 3 failures within 60 seconds (configurable via env vars).
State file: /tmp/agent-circuit-breaker.json (per-machine, ephemeral; flock-serialized
via <state>.lock, atomic rename on write)

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

import contextlib
import json
import os
import re
import sys
import time
from pathlib import Path

try:
    import fcntl
except ImportError:  # non-POSIX: run unlocked
    fcntl = None

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
    # tmp + rename so a concurrent reader never sees a half-written file.
    tmp = STATE_FILE.with_name(f"{STATE_FILE.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(json.dumps(records))
        os.replace(tmp, STATE_FILE)
    except OSError:
        with contextlib.suppress(OSError):
            tmp.unlink()


@contextlib.contextmanager
def state_lock():
    """Serialize the load->modify->save cycle: the state file is shared by
    every session on the machine, so concurrent hooks would lose updates."""
    fh = None
    if fcntl is not None:
        try:
            fh = open(f"{STATE_FILE}.lock", "a")  # noqa: SIM115 — held for the with-block
            fcntl.flock(fh, fcntl.LOCK_EX)
        except OSError:
            if fh:
                fh.close()
            fh = None
    try:
        yield
    finally:
        if fh:
            fh.close()


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


def _record_failure(signature: str, tool_use_id, now: float) -> list:
    """Append a failure record (dedup by tool_use_id when the runtime gives
    us one) and return the pruned+updated record list.

    PostToolUseFailure (Claude's explicit-failure event, added alongside the
    existing PostToolUse text/exit-status heuristic below) and a PostToolUse
    for the SAME tool call can both reach this hook once both are wired. Since
    neither the canonical event JSON (docs/hook-protocol.md) nor today's live
    PostToolUse payload is guaranteed to carry tool_use_id, dedup is
    best-effort: when a tool_use_id IS present on this call we skip if a
    record with the same id is already in the window; when it's absent (the
    common case today) we fall back to the pre-existing behavior of counting
    every classified failure, accepting a possible double-count for that one
    call as a known, documented trade-off rather than silently dropping data.
    """
    records = load_state()
    records = [r for r in records if now - r.get("ts", 0) < WINDOW_SECONDS]
    if tool_use_id:
        for r in records:
            if r.get("tool_use_id") == tool_use_id:
                save_state(records)
                return records
    entry = {"ts": now, "sig": signature}
    if tool_use_id:
        entry["tool_use_id"] = tool_use_id
    records.append(entry)
    save_state(records)
    return records


def _maybe_fire(records: list, hook_event_name: str) -> None:
    if len(records) < THRESHOLD:
        return
    signature = records[-1].get("sig", "")
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
            "hookEventName": hook_event_name,
            "additionalContext": msg,
        }
    }
    print(json.dumps(output))
    save_state([])


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        return

    tool_name = data.get("tool_name", "")
    if tool_name != "Bash":
        return

    hook_event_name = data.get("hook_event_name") or data.get("event") or ""

    if hook_event_name == "PostToolUseFailure":
        # Explicit failure event (docs: tool_name, tool_input, tool_use_id,
        # error) — the failure is a GIVEN, no exit-status/text heuristic
        # needed. Counted directly from the `error` field.
        error = data.get("error", "")
        error_text = error if isinstance(error, str) else json.dumps(error)
        signature = extract_error_signature(error_text)
        tool_use_id = data.get("tool_use_id")
        now = time.time()
        records = _record_failure(signature, tool_use_id, now)
        _maybe_fire(records, "PostToolUseFailure")
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
    tool_use_id = data.get("tool_use_id")
    records = _record_failure(signature, tool_use_id, now)
    _maybe_fire(records, "PostToolUse")


if __name__ == "__main__":
    with state_lock():
        main()
