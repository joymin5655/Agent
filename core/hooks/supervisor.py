#!/usr/bin/env python3
"""UserPromptSubmit + PreToolUse + PostToolUse hook — Supervisor v0.2 (minimal dispatcher).

Dispatch, not advise. A prompt is a request the AI is free to ignore — the 218-event
audit measured ~98% ignore rate on advisory routing hints — so the routing decision is
made by the hook, not suggested to the model. This dispatcher:

  1. UserPromptSubmit — matches the prompt against each registry agent's
     `matches.keywords` (word-boundary, case-insensitive). A real match records a
     short-lived intent (30-min TTL) in .agent/state/supervisor-intent.json.
  2. PreToolUse (Write/Edit/MultiEdit) — if a fresh, un-asked intent exists, returns a
     `permissionDecision: "ask"` naming the specialist (once per intent, no repeat nag).
     A separate security matcher asks on `matches.file_globs` for the tool, independent
     of intent, once per path.
  3. PostToolUse (Task/Agent) — dispatching the matched specialist (namespace-agnostic:
     `x:code-reviewer` resolves `code-reviewer`) clears the intent.

Ghost fallback (rules/policy/specialist-routing.md, Lesson 2): a registry id with no
sibling `<id>.md` next to the registry file has no in-session provider. Such matches
never `ask` — they emit a one-line stderr hint recommending the executor fallback and
log `{"action":"ghost"}` only. Never ask the user to dispatch a phantom.

Escape hatch: `AGENT_SUPERVISOR_MODE=observe` downgrades every `ask` to a stderr hint
(default `dispatch`). `.agent/` internal edits are skipped (meta-work false-positive guard).

Protocol (docs/hook-protocol.md): reads canonical event JSON on stdin. Only PreToolUse
`ask` writes a decision JSON to stdout; every other path writes zero bytes (§3 Critical
rule — never `null`/`{}`/raw). Any exception is fail-open (exit 0, empty stdout): routing
must never break a session. Python 3.9 compatible.

The full registry-aware orchestrator (the 54KB original) remains future work — this is the
minimal dispatcher that turns the routing contract from a prompt into an enforced gate.
"""

from __future__ import annotations

import fnmatch
import json
import os
import pathlib
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

INTENT_TTL = timedelta(minutes=30)


def repo_root() -> pathlib.Path:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return pathlib.Path(out)
    except Exception:
        return pathlib.Path.cwd()


def find_registry(root: pathlib.Path):
    for p in (
        root / "agents" / "master-registry.json",
        root / ".claude" / "agents" / "master-registry.json",
        root / ".agent" / "agents" / "registry.json",
    ):
        if p.is_file():
            return p
    return None


def load_registry(path: pathlib.Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {"agents": []}


def is_real_agent(registry_path: pathlib.Path, agent_id: str) -> bool:
    """A specialist is real iff a sibling <id>.md sits next to the registry file."""
    if not agent_id:
        return False
    return (registry_path.parent / (agent_id + ".md")).is_file()


def agent_by_id(reg: dict, agent_id: str):
    for a in reg.get("agents", []):
        if a.get("id") == agent_id:
            return a
    return None


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

def state_path(root: pathlib.Path) -> pathlib.Path:
    return root / ".agent" / "state" / "supervisor-intent.json"


def load_state(root: pathlib.Path) -> dict:
    try:
        return json.loads(state_path(root).read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(root: pathlib.Path, state: dict) -> None:
    p = state_path(root)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(state), encoding="utf-8")
    except Exception:
        pass


def delete_state(root: pathlib.Path) -> None:
    try:
        state_path(root).unlink()
    except Exception:
        pass


def intent_expired(state: dict) -> bool:
    ts = state.get("ts")
    if not ts:
        return True
    try:
        dt = datetime.fromisoformat(ts)
    except Exception:
        return True
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - dt) > INTENT_TTL


def has_fresh_intent(state: dict) -> bool:
    return bool(state.get("specialist")) and not intent_expired(state)


# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------

def log_event(root: pathlib.Path, event: str, tool: str, **extra) -> None:
    log_dir = root / ".agent" / "logs"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        return
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "tool_name": tool,
        "session_id": os.environ.get("AGENT_SESSION_ID", "main"),
    }
    rec.update(extra)
    try:
        with open(log_dir / "supervisor.jsonl", "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# matching
# ---------------------------------------------------------------------------

def match_keyword(reg: dict, prompt: str):
    """First (agent_id, keyword) whose keyword hits a word-boundary match. None if no hit."""
    for agent in reg.get("agents", []):
        for kw in (agent.get("matches") or {}).get("keywords") or []:
            if not kw:
                continue
            if re.search(r"\b" + re.escape(kw) + r"\b", prompt, re.IGNORECASE):
                return agent.get("id", ""), kw
    return None


def is_meta_path(file_path: str) -> bool:
    """Skip edits to the harness's own .agent/ state — meta-work, not user work."""
    if not file_path:
        return False
    return ".agent" in pathlib.PurePath(file_path).parts


def decision_ask(reason: str) -> bytes:
    return json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }).encode("utf-8")


def ghost_hint(agent_id: str) -> str:
    return (
        "[supervisor] '{aid}' matched but has no in-session provider (ghost) — "
        "use the executor fallback for this work.".format(aid=agent_id)
    )


# ---------------------------------------------------------------------------
# event handlers — each returns the bytes to write to stdout (b"" = pass-through)
# ---------------------------------------------------------------------------

def handle_ups(root: pathlib.Path, data: dict) -> bytes:
    prompt = data.get("user_prompt") or data.get("prompt") or ""
    if not prompt:
        return b""
    registry_path = find_registry(root)
    if not registry_path:
        return b""
    reg = load_registry(registry_path)
    hit = match_keyword(reg, prompt)
    if not hit:
        return b""
    agent_id, keyword = hit

    if not is_real_agent(registry_path, agent_id):
        # Ghost: never ask, never record intent — advisory stderr + log only.
        print(ghost_hint(agent_id), file=sys.stderr)
        log_event(root, "UserPromptSubmit", "", action="ghost",
                  specialist=agent_id, keyword=keyword)
        return b""

    state = load_state(root)  # preserve any security_asked_paths already tracked
    state["ts"] = datetime.now(timezone.utc).isoformat()
    state["specialist"] = agent_id
    state["keyword"] = keyword
    state["asked"] = False
    save_state(root, state)
    log_event(root, "UserPromptSubmit", "", action="match",
              specialist=agent_id, keyword=keyword)
    return b""


def handle_pre(root: pathlib.Path, data: dict) -> bytes:
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}
    file_path = tool_input.get("file_path", "") or ""

    if is_meta_path(file_path):
        return b""

    mode = os.environ.get("AGENT_SUPERVISOR_MODE", "dispatch")
    state = load_state(root)

    # Expire a stale intent before reading it (keep any security_asked_paths).
    if state.get("ts") and intent_expired(state):
        for k in ("ts", "specialist", "keyword", "asked"):
            state.pop(k, None)
        save_state(root, state)

    # (a) intent-based ask — once per intent. Intent was ghost-filtered at UPS time.
    if has_fresh_intent(state) and not state.get("asked"):
        specialist = state.get("specialist", "")
        keyword = state.get("keyword", "")
        state["asked"] = True
        save_state(root, state)
        reason = (
            "Specialist '{s}' matches this request (keyword: '{k}'). Dispatch it via "
            "the Task/Agent tool, or approve to proceed without it.".format(s=specialist, k=keyword)
        )
        if mode == "observe":
            print("[supervisor] (observe) " + reason, file=sys.stderr)
            log_event(root, "PreToolUse", tool, action="observe-intent", specialist=specialist)
            return b""
        log_event(root, "PreToolUse", tool, action="ask-intent", specialist=specialist)
        return decision_ask(reason)

    # (b) security file-glob matcher — independent of intent, once per path.
    registry_path = find_registry(root)
    if registry_path and file_path:
        reg = load_registry(registry_path)
        asked_paths = state.get("security_asked_paths") or []
        for agent in reg.get("agents", []):
            matches = agent.get("matches") or {}
            globs = matches.get("file_globs") or []
            tools = matches.get("tools") or []
            if not globs or tool not in tools:
                continue
            if not any(fnmatch.fnmatch(file_path, g) for g in globs):
                continue
            agent_id = agent.get("id", "")
            if not is_real_agent(registry_path, agent_id):
                print(ghost_hint(agent_id), file=sys.stderr)
                log_event(root, "PreToolUse", tool, action="ghost", specialist=agent_id)
                continue
            if file_path in asked_paths:
                return b""
            asked_paths.append(file_path)
            state["security_asked_paths"] = asked_paths
            save_state(root, state)
            reason = (
                "Specialist '{s}' guards this path ({p}). Dispatch it via the Task/Agent "
                "tool, or approve to proceed without it.".format(s=agent_id, p=file_path)
            )
            if mode == "observe":
                print("[supervisor] (observe) " + reason, file=sys.stderr)
                log_event(root, "PreToolUse", tool, action="observe-security", specialist=agent_id)
                return b""
            log_event(root, "PreToolUse", tool, action="ask-security", specialist=agent_id)
            return decision_ask(reason)

    return b""


def handle_post(root: pathlib.Path, data: dict) -> bytes:
    tool = data.get("tool_name", "")
    if tool not in ("Task", "Agent"):
        return b""
    subagent = (data.get("tool_input") or {}).get("subagent_type", "") or ""
    if not subagent:
        return b""

    state = load_state(root)
    specialist = state.get("specialist")
    if not specialist:
        return b""

    targets = {specialist}
    registry_path = find_registry(root)
    if registry_path:
        agent = agent_by_id(load_registry(registry_path), specialist)
        if agent:
            targets.update(agent.get("aliases") or [])

    sub_norm = subagent.split(":")[-1]  # namespace-agnostic: x:code-reviewer -> code-reviewer
    if sub_norm in targets or subagent in targets:
        delete_state(root)
        log_event(root, "PostToolUse", tool, action="dispatched", specialist=specialist)
    return b""


# ---------------------------------------------------------------------------

def classify_event(data: dict) -> str:
    ev = data.get("event") or data.get("hook_event_name") or ""
    if ev:
        return ev
    if data.get("user_prompt") is not None or data.get("prompt") is not None:
        return "UserPromptSubmit"
    if "tool_response" in data:
        return "PostToolUse"
    if data.get("tool_name"):
        return "PreToolUse"
    return ""


def main() -> None:
    out = b""
    try:
        raw = sys.stdin.buffer.read()
        if raw.strip():
            data = json.loads(raw)
            root = repo_root()
            event = classify_event(data)
            if event == "UserPromptSubmit":
                out = handle_ups(root, data)
            elif event == "PostToolUse":
                out = handle_post(root, data)
            elif event == "PreToolUse":
                out = handle_pre(root, data)
    except Exception:
        # Fail-open: a routing bug must never break the session (protocol §3 + Lesson 3).
        out = b""
    if out:
        try:
            sys.stdout.buffer.write(out)
        except Exception:
            pass
    sys.exit(0)


if __name__ == "__main__":
    main()
