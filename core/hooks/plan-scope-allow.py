#!/usr/bin/env python3
"""plan-scope-allow.py — auto-allow accelerator for plan-approved sessions.

Matcher: PreToolUse Write|Edit|MultiEdit (registered LAST in the chain).

Once the user has approved a plan this session (plan-gate.py wrote the shared
/tmp/agent-plan-approved flag), edits to in-workspace, non-risk files are
auto-allowed (permissionDecision "allow") so the native permission prompt stops
firing on every step of the approved work.

Contract and polarity — this is the harness's first permission-WEAKENING hook:
- It emits ONLY "allow" or nothing. Never deny, never ask. On any doubt or any
  exception it stays silent (pass-through), which leaves the native prompt and
  every other hook in charge. Fail-open direction is "keep asking" — the
  opposite of the deny-gates' fail-open-allow.
- "allow" bypasses the NATIVE permission prompt only. Other hooks' deny/ask
  still bind (most-restrictive-wins); this hook is also registered last so a
  short-circuiting deny earlier in the chain runs first.
- Reader hardcodes the flag path (no env override) — it must stay coupled to
  plan-gate.py's writer, same one-path-one-contract rule as spec-gate.py.
- Opt-in via env only: AGENT_PLAN_ALLOW_MODE=on (default off — ships dark; flip
  after telemetry). Deliberately NOT a hook-config.yml key: repo config is
  additive/stricter-only, and a weakening toggle must not be editable by the
  agent itself.

Never-allow screens (hit -> silent, their own guards + native prompt decide):
spec-gate GUARD_PATTERNS verbatim (migrations/*.sql, secrets/ + .env,
functions/*/index.ts|js, billing/) plus self-tamper surfaces (.agent/
hook-config.yml, .git/). Workspace containment is realpath-based (symlink and
../ escapes resolve outside and go silent).

Telemetry: each emitted allow appends one line to
.agent/logs/plan-scope-allow.jsonl (override: AGENT_PLAN_ALLOW_SINK).
Registered in docs/gate-registry.md (GATE plan-scope-allow).
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

# Shared flag — hardcoded on purpose (writer: plan-gate.py; cleared by
# session-init.py at SessionStart and session-close.sh at Stop).
PLAN_FLAG = "/tmp/agent-plan-approved"

EDIT_TOOLS = {"Write", "Edit", "MultiEdit"}

# spec-gate GUARD_PATTERNS verbatim + self-tamper surfaces. IGNORECASE so a
# case-insensitive filesystem spelling can't slip past.
NEVER_ALLOW = [
    re.compile(r"(^|/)migrations/.+\.sql$", re.IGNORECASE),
    re.compile(r"(^|/)(secrets/|\.env)", re.IGNORECASE),
    re.compile(r"(^|/)functions/[^/]+/index\.(ts|js)$", re.IGNORECASE),
    re.compile(r"(^|/)billing/", re.IGNORECASE),
    re.compile(r"(^|/)\.agent/hook-config\.(yml|json)$", re.IGNORECASE),
    re.compile(r"(^|/)\.git(/|$)", re.IGNORECASE),
]


def workspace_root(event_cwd):
    """Resolve the workspace root the same way the other hooks do."""
    for env_var in ("AGENT_PROJECT_DIR", "CLAUDE_PROJECT_DIR"):
        root = os.environ.get(env_var, "").strip()
        if root and os.path.isdir(root):
            return root
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    if event_cwd and os.path.isdir(event_cwd):
        return event_cwd
    return os.getcwd()


def log_allow(root, file_path):
    sink = os.environ.get("AGENT_PLAN_ALLOW_SINK") or os.path.join(
        root, ".agent", "logs", "plan-scope-allow.jsonl"
    )
    try:
        os.makedirs(os.path.dirname(sink), exist_ok=True)
        with open(sink, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "ts": datetime.now(timezone.utc).isoformat(),
                "gate": "plan-scope-allow",
                "verdict": "allow",
                "file_path": file_path,
                "session_id": os.environ.get("AGENT_SESSION_ID", ""),
            }) + "\n")
    except Exception:
        pass  # telemetry must never block the decision


def main():
    if os.environ.get("AGENT_PLAN_ALLOW_MODE", "off").strip().lower() != "on":
        return

    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        return

    if event.get("tool_name") not in EDIT_TOOLS:
        return
    file_path = (event.get("tool_input") or {}).get("file_path", "")
    if not isinstance(file_path, str) or not file_path.strip():
        return

    if not os.path.exists(PLAN_FLAG):
        return

    for pattern in NEVER_ALLOW:
        if pattern.search(file_path):
            return

    event_cwd = event.get("cwd", "")
    root = workspace_root(event_cwd)
    base = event_cwd if (event_cwd and os.path.isdir(event_cwd)) else root
    real_root = os.path.realpath(root)
    real_target = os.path.realpath(
        file_path if os.path.isabs(file_path) else os.path.join(base, file_path)
    )
    try:
        if os.path.commonpath([real_target, real_root]) != real_root:
            return
    except ValueError:  # different drives / mixed abs-rel
        return
    # Re-screen the RESOLVED path too: a symlink may rename a guarded target.
    for pattern in NEVER_ALLOW:
        if pattern.search(real_target):
            return

    log_allow(root, file_path)
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": (
                "plan-scope-allow: plan approved this session; "
                "in-workspace non-risk edit (disable: AGENT_PLAN_ALLOW_MODE=off)"
            ),
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # weakening hook fails SILENT — native prompt keeps asking
    sys.exit(0)
