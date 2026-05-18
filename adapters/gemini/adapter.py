#!/usr/bin/env python3
"""Gemini CLI envelope translator → canonical hook event JSON.

Reads one JSON object from stdin. If it already matches the canonical shape,
passes through unchanged. Otherwise translates known Gemini tool-call envelopes:

  Gemini run_shell_command  →  PreToolUse + tool_name=Bash
  Gemini write_file         →  PreToolUse + tool_name=Write
  Gemini replace            →  PreToolUse + tool_name=Edit
  Gemini read_file          →  PreToolUse + tool_name=Read

Output: canonical event JSON to stdout, ready to pipe into a core hook.
"""
import json
import sys


def is_canonical(obj: dict) -> bool:
    return "event" in obj and "tool_name" in obj and "tool_input" in obj


# Gemini name → canonical tool_name + arg-key map
GEMINI_TOOL_MAP = {
    "run_shell_command": ("Bash",  {"command": "command"}),
    "shell":             ("Bash",  {"command": "command"}),
    "write_file":        ("Write", {"file_path": "file_path", "content": "content"}),
    "replace":           ("Edit",  {"file_path": "file_path", "old_string": "old_string", "new_string": "new_string"}),
    "read_file":         ("Read",  {"file_path": "file_path"}),
    "list_directory":    ("LS",    {"path": "path"}),
    "search_file_content": ("Grep", {"pattern": "pattern", "path": "path"}),
    "glob":              ("Glob",  {"pattern": "pattern"}),
}


def translate_gemini(obj: dict) -> dict:
    out = {
        "ai": "gemini",
        "event": obj.get("event", "PreToolUse"),
        "session_id": obj.get("session_id", ""),
        "cwd": obj.get("cwd", ""),
    }

    name = obj.get("name", obj.get("tool", ""))
    args = obj.get("args", obj.get("arguments", obj.get("parameters", {})))

    if name in GEMINI_TOOL_MAP:
        canonical_tool, arg_map = GEMINI_TOOL_MAP[name]
        out["tool_name"] = canonical_tool
        out["tool_input"] = {
            canonical_key: args.get(gemini_key, "")
            for canonical_key, gemini_key in arg_map.items()
        }
    else:
        out["tool_name"] = obj.get("tool_name", name or "Unknown")
        out["tool_input"] = obj.get("tool_input", args)

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
        return 0

    if not isinstance(obj, dict):
        return 0

    out = obj if is_canonical(obj) else translate_gemini(obj)
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
