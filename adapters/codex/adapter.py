#!/usr/bin/env python3
"""Codex CLI envelope translator → canonical hook event JSON.

Reads one JSON object from stdin (newline-terminated or single message).
If it already matches the canonical shape, passes through unchanged.
Otherwise translates known Codex tool-call envelopes:

  Codex shell_call   →  PreToolUse + tool_name=Bash + tool_input.command
  Codex file_write   →  PreToolUse + tool_name=Write + tool_input.{file_path,content}
  Codex apply_patch  →  PreToolUse + tool_name=Edit + tool_input.{file_path,...}

Output: canonical event JSON to stdout, ready to pipe into a core hook.
"""
import json
import sys


def is_canonical(obj: dict) -> bool:
    return "event" in obj and "tool_name" in obj and "tool_input" in obj


def translate_codex(obj: dict) -> dict:
    """Best-effort translation from Codex tool-call envelopes."""
    out = {
        "ai": "codex",
        "event": obj.get("event", "PreToolUse"),
        "session_id": obj.get("session_id", ""),
        "cwd": obj.get("cwd", ""),
    }

    t = obj.get("type", "")

    if t == "shell_call":
        args = obj.get("arguments", {})
        cmd = args.get("command", [])
        if isinstance(cmd, list):
            # Codex usually wraps in ["bash", "-lc", "<real-cmd>"]
            if len(cmd) >= 3 and cmd[0] in ("bash", "sh", "/bin/bash", "/bin/sh") and cmd[1] in ("-lc", "-c"):
                cmd_str = cmd[2]
            else:
                cmd_str = " ".join(cmd)
        else:
            cmd_str = str(cmd)
        out["tool_name"] = "Bash"
        out["tool_input"] = {"command": cmd_str}

    elif t == "file_write":
        out["tool_name"] = "Write"
        out["tool_input"] = {
            "file_path": obj.get("path", ""),
            "content": obj.get("content", ""),
        }

    elif t in ("apply_patch", "edit", "file_edit"):
        out["tool_name"] = "Edit"
        out["tool_input"] = {
            "file_path": obj.get("path", obj.get("file_path", "")),
            "old_string": obj.get("old_string", ""),
            "new_string": obj.get("new_string", ""),
        }

    else:
        # Unknown envelope — pass through as-is with `tool_name` falling back to type.
        out["tool_name"] = obj.get("tool_name", t or "Unknown")
        out["tool_input"] = obj.get("tool_input", obj.get("arguments", {}))

    return out


def main() -> int:
    try:
        raw = sys.stdin.read()
    except Exception:
        return 0

    if not raw.strip():
        return 0

    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        # Bad JSON — silently pass empty to upstream hook
        return 0

    if not isinstance(obj, dict):
        return 0

    if is_canonical(obj):
        out = obj
    else:
        out = translate_codex(obj)

    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
