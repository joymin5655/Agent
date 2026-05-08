#!/usr/bin/env python3
"""AirLens — Circuit Breaker (PostToolUse: Bash)

Detects repeated failures within a sliding window and warns to change strategy.
Threshold: 3 failures within 60 seconds.
State file: /tmp/airlens-circuit-breaker.json
"""

import json
import sys
import time
from pathlib import Path

STATE_FILE = Path("/tmp/airlens-circuit-breaker.json")
WINDOW_SECONDS = 60
THRESHOLD = 3


def load_state() -> list:
    """Load failure records from state file."""
    if not STATE_FILE.exists():
        return []
    try:
        data = json.loads(STATE_FILE.read_text())
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def save_state(records: list) -> None:
    """Save failure records to state file."""
    try:
        STATE_FILE.write_text(json.dumps(records))
    except OSError:
        pass


def extract_error_signature(result_text: str) -> str:
    """Extract a short signature from error output for deduplication."""
    lines = result_text.strip().split("\n")
    # Take last non-empty line as error signature (most specific)
    for line in reversed(lines):
        stripped = line.strip()
        if stripped and len(stripped) > 10:
            # Truncate to 120 chars for comparison
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

    # Check if the tool result indicates failure
    result = data.get("tool_result", {})
    # PostToolUse receives stdout/stderr; check for error indicators
    result_text = ""
    if isinstance(result, dict):
        result_text = result.get("stderr", "") or result.get("stdout", "")
    elif isinstance(result, str):
        result_text = result

    # Check exit code from tool result
    exit_code = None
    if isinstance(result, dict):
        exit_code = result.get("exit_code")

    # If no clear failure signal, skip
    is_error = False
    if exit_code is not None and exit_code != 0:
        is_error = True
    elif "error" in result_text.lower()[:500] or "Error" in result_text[:500]:
        is_error = True
    elif "FAILED" in result_text[:500] or "failed" in result_text[:200]:
        is_error = True

    now = time.time()

    if not is_error:
        # On success, prune old records but don't add new ones
        records = load_state()
        records = [r for r in records if now - r.get("ts", 0) < WINDOW_SECONDS]
        save_state(records)
        return

    # Record this failure
    signature = extract_error_signature(result_text)
    records = load_state()

    # Prune records outside window
    records = [r for r in records if now - r.get("ts", 0) < WINDOW_SECONDS]
    records.append({"ts": now, "sig": signature})
    save_state(records)

    # Check if threshold exceeded
    if len(records) >= THRESHOLD:
        # Count similar errors (fuzzy match: first 60 chars)
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

        # Reset after warning to avoid spamming
        save_state([])


if __name__ == "__main__":
    main()
