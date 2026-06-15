#!/usr/bin/env python3
"""PostToolUse hook — Circuit Breaker

Detects repeated Bash failures within a sliding window and emits an `additionalContext`
warning advising the AI to change strategy. Prevents infinite retry loops on the same
broken command.

Threshold: 3 failures within 60 seconds (configurable via env vars).
State file: /tmp/agent-circuit-breaker.json (per-machine, ephemeral)

Hook protocol: reads canonical event JSON from stdin. Writes additionalContext JSON to
stdout when threshold crossed. Empty stdout otherwise. Exit always 0.
"""

import json
import os
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

    exit_code = None
    if isinstance(result, dict):
        exit_code = result.get("exit_code") or result.get("exitCode")

    is_error = False
    if exit_code is not None and exit_code != 0:
        is_error = True
    elif "error" in result_text.lower()[:500] or "Error" in result_text[:500]:
        is_error = True
    elif "FAILED" in result_text[:500] or "failed" in result_text[:200]:
        is_error = True

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
