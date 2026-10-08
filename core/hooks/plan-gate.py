#!/usr/bin/env python3
"""PostToolUse hook — Plan-mode approval flag.

When the AI uses ExitPlanMode (Claude Code) OR completes a Plan-class Agent
dispatch, write a /tmp flag so subsequent Write/Edit can be permitted by the
supervisor enforcer.

W-8 source-first: memory fragments are triggers, not evidence. An ExitPlanMode
plan that cites memory but carries no live-source evidence (file:line or
command output) does not get the flag; spec-gate then asks before edits.

Hook protocol: reads canonical event JSON from stdin, writes empty stdout (allow).
Side-effect: writes /tmp/agent-plan-approved with timestamp.
"""

import json
import os
import pathlib
import re
import sys
from datetime import datetime

# Approval flag path. Overridable via AGENT_PLAN_FLAG so tests can exercise the
# gate against a throwaway path instead of clobbering the live session flag that
# spec-gate.py reads. Default is the shared /tmp location spec-gate expects.
PLAN_FLAG = pathlib.Path(os.environ.get("AGENT_PLAN_FLAG", "/tmp/agent-plan-approved"))

# Agent subagent_type values considered "plan-class"
PLAN_AGENT_TYPES = {"Plan", "plan", "Explore", "explore", "planner"}

# Description / prompt keyword heuristics (multilingual)
PLAN_DESCRIPTION_KEYWORDS = (
    "plan", "design", "architecture", "blueprint", "implementation",
    "구현 계획", "설계", "아키텍처", "구조",
)


# Memory-citation phrasing. Deliberately specific: bare "memory" (memory leak,
# memory usage, "read from memory instead of disk") must not match.
MEMORY_CITATION = re.compile(
    r"\b(per|from|according to|based on|as noted in)\s+(my\s+|the\s+)?"
    r"(memory|memories)\b(?!\s+(instead|pressure|usage|pool|leak|limit|footprint"
    r"|allocation|cache|only|rather|bandwidth|layout))"
    r"|\bmemory (says|notes that|states that|indicates that)\b"
    r"|(?:^|[.!?]\s+)(?:as )?I (?:recall|remember)\b"
    r"|\bMEMORY\.md\b|\bbrain_(get|search|neighbors)\b"
    r"|메모리에\s*(따르면|의하면|기록)|이전에 기록",
    re.IGNORECASE | re.MULTILINE,
)

SOURCE_EXTS = (
    "py|sh|bash|ts|tsx|js|jsx|mjs|md|yml|yaml|json|toml|sql|go|rs|java|rb|c|h"
    "|cpp|hpp|cs|swift|kt|php|html|css|ini|cfg"
)
# path:line — needs a path separator or a known source extension. URLs are
# stripped first so host:port / https://...:8080 never count as evidence.
FILE_LINE = re.compile(
    rf"(?<![\w./-])(?:[\w.-]+(?:/[\w.-]+)+|[\w-]+\.(?:{SOURCE_EXTS})):\d+\b"
)
URL = re.compile(r"\b\w+://\S+")
FENCE = re.compile(r"```[^\n]*\n(.*?)```", re.DOTALL)


def _has_command_output(plan: str) -> bool:
    """A fenced block with a `$ cmd` line followed by at least one output line."""
    for block in FENCE.findall(plan):
        lines = [ln.strip() for ln in block.splitlines() if ln.strip()]
        for idx, ln in enumerate(lines):
            if ln.startswith("$ ") and idx + 1 < len(lines) \
                    and not lines[idx + 1].startswith("$ "):
                return True
    return False


def has_live_evidence(plan: str) -> bool:
    return bool(FILE_LINE.search(URL.sub(" ", plan))) or _has_command_output(plan)


def memory_only_plan(plan: str) -> bool:
    return bool(MEMORY_CITATION.search(plan)) and not has_live_evidence(plan)


def flag_session(flag: pathlib.Path) -> str:
    try:
        m = re.search(r"session=(\S+)", flag.read_text(encoding="utf-8"))
    except OSError:
        return ""
    return m.group(1) if m else ""


def withheld_marker() -> pathlib.Path:
    return PLAN_FLAG.with_name(PLAN_FLAG.name + ".withheld")


def marker_session() -> str:
    try:
        return withheld_marker().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def write_flag(sid: str) -> None:
    try:
        PLAN_FLAG.write_text(
            f"approved at {datetime.now().isoformat()} session={sid}", encoding="utf-8"
        )
    except OSError:
        pass


def notice(message: str) -> None:
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": message}
    }))


def withhold(sid: str) -> None:
    """Memory-only plan: no flag for this session, and Agent path stays shut."""
    if sid:
        try:
            withheld_marker().write_text(sid, encoding="utf-8")
        except OSError:
            pass
    cleared = False
    if PLAN_FLAG.exists() and sid and flag_session(PLAN_FLAG) == sid:
        try:
            PLAN_FLAG.unlink()
        except OSError:
            pass
    if not PLAN_FLAG.exists():
        cleared = True
    base = (
        "plan-gate: plan cites memory without live-source evidence. Memory is a "
        "trigger, not proof - re-verify each factual claim against the source "
        "(file:line or command output) and re-submit the plan. "
    )
    if cleared:
        notice(base + "This session's approval flag is not set.")
    else:
        notice(
            base + "Could not clear the approval flag (it belongs to another session "
            "or is unowned/undeletable), so edits may still pass the spec-gate."
        )


def is_plan_agent(data: dict) -> bool:
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return False

    subagent_type = tool_input.get("subagent_type", "")
    if subagent_type in PLAN_AGENT_TYPES:
        return True

    description = (tool_input.get("description") or "").lower()
    for keyword in PLAN_DESCRIPTION_KEYWORDS:
        if keyword in description:
            return True

    prompt = (tool_input.get("prompt") or "").lower()
    if "implementation plan" in prompt or "구현 계획" in prompt:
        return True

    return False


def run() -> None:
    try:
        data = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        return
    if not isinstance(data, dict):
        return

    tool_name = data.get("tool_name", "")
    sid = str(data.get("session_id") or "")
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}

    # ExitPlanMode = user-approved plan in Claude Code → write flag
    if tool_name == "ExitPlanMode":
        plan = tool_input.get("plan")
        if isinstance(plan, str) and memory_only_plan(plan):
            withhold(sid)
            return
        if sid and marker_session() == sid:
            try:
                withheld_marker().unlink()
            except OSError:
                pass
        write_flag(sid)
        return

    # Agent tool — check if it's plan-class (Task/Agent per Claude Code version)
    if tool_name not in ("Agent", "Task"):
        return

    # A memory-only plan was withheld in this session: a plan-class dispatch must
    # not re-open the gate until an ExitPlanMode with live evidence passes.
    if sid and marker_session() == sid:
        return

    if is_plan_agent(data):
        write_flag(sid)


def main() -> None:
    try:
        run()
    except Exception:  # fail-open: a hook bug must never break the session
        return


if __name__ == "__main__":
    main()
