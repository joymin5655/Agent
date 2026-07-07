#!/usr/bin/env python3
"""spec-gate PreToolUse hook — planning-discipline enforcement.

Gates substantive implementation edits when no plan has been approved this
session. The plan-approval flag is WRITTEN by plan-gate.py (on ExitPlanMode or a
plan-class Agent dispatch) and CLEARED at SessionStart/Stop — a fresh session is
unapproved. This hook is the CONSUMER of that flag: it turns "plan first" from a
prompt suggestion into a tool-boundary gate.

Modes (AGENT_SPEC_GATE_MODE):
  - off     — skip entirely
  - dryrun  — log verdict but never block (default — observation phase)
  - block   — return permissionDecision=ask when no approved plan exists

Configuration env vars:
  - AGENT_SPEC_GATE_MODE          off | dryrun | block
  - AGENT_SPEC_GATE_SINK          dryrun jsonl sink (default .agent/logs/spec-gate.jsonl)
  - AGENT_SPEC_GATE_SCOPE_REGEX   file path regex to enforce on
        (default: (src|app|pages|lib|server|components)/….(ts|tsx|js|jsx|py), case-insensitive)

The plan-approval flag path is the shared, hardcoded /tmp/agent-plan-approved — the
SAME constant written by plan-gate.py and cleared by session-init.py/session-close.sh.
It is deliberately NOT env-overridable: a per-consumer override would let the reader
read one path while the writer wrote another, silently killing the ExitPlanMode escape.

Risk-area whitelist:
  Files matching project risk-area patterns (production data / secrets / deploy / etc.)
  are exempted — planning enforcement defers to risk-area hooks. Define in hook-config.yml.

Decision flow:
  1. Mode check
  2. Parse tool_input.file_path
  3. Plan-approval flag present → allow (plan approved this session — the flag is the dedup)
  4. Risk-area whitelist (immediate allow if matched)
  5. Scope filter (only substantive impl code)
  6. Skip patterns (tests, types, config, json, css, md, index, .agent/ meta)
  7. Verdict → dryrun jsonl + (advisory or ask based on mode)

Deny-vs-ask: this gate uses `ask` (not tdd-guard's `deny`). A planning-discipline
gate is REVERSIBLE — the edit isn't destructive and the escape is trivial (approve a
plan via ExitPlanMode, or set AGENT_SPEC_GATE_MODE=off) — so it matches the harness
escalation principle (pre-tool-guard rules 13/14, supervisor use `ask` for reversible
gates). `ask` also de-risks a false positive by leaving the user in control.

Hook protocol: reads canonical event JSON from stdin, writes decision JSON or empty.
Exit always 0. Fail-open: any exception → exit 0, never block on error.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

MODE = os.environ.get("AGENT_SPEC_GATE_MODE", "dryrun")
if MODE == "off":
    sys.exit(0)

# The shared plan-approval flag — the SAME hardcoded path written by plan-gate.py
# and cleared by session-init.py / session-close.sh. Not env-overridable on purpose:
# a per-consumer override would decouple this reader from the writer (approval would
# write one path, the gate would read another). One path, one contract.
PLAN_FLAG = "/tmp/agent-plan-approved"
DRYRUN_SINK_RELATIVE = os.environ.get(
    "AGENT_SPEC_GATE_SINK", ".agent/logs/spec-gate.jsonl"
)

# Risk-area whitelist — files matching these patterns skip planning enforcement.
# Edit this list or override via hook-config.yml: risk_areas[].paths.
# Each entry: (compiled-regex, category-label). Mirrors tdd-guard's GUARD_PATTERNS.
GUARD_PATTERNS = [
    (re.compile(r"(^|/)migrations/.+\.sql$"), "production-migration"),
    (re.compile(r"(^|/)(secrets/|\.env)"), "secret"),
    (re.compile(r"(^|/)functions/[^/]+/index\.(ts|js)$"), "edge-fn"),
    (re.compile(r"(^|/)billing/"), "billing"),
]

# Scope — only enforce on substantive impl code. The default covers the common
# code roots (not just src/ — also Next.js app/ & pages/, plus lib/server/components),
# extension-gated. Case-insensitive so an uppercase spelling on a case-insensitive FS
# (macOS) can't evade the gate. Configurable via env; a bad override regex falls back
# to the default rather than crashing at import (fail-open: a config typo must never
# break a session).
_DEFAULT_SCOPE = r"(^|/)(src|app|pages|lib|server|components)/.+\.(ts|tsx|js|jsx|py)$"
try:
    SCOPE_RE = re.compile(os.environ.get("AGENT_SPEC_GATE_SCOPE_REGEX", _DEFAULT_SCOPE), re.IGNORECASE)
except re.error:
    SCOPE_RE = re.compile(_DEFAULT_SCOPE, re.IGNORECASE)

# Files to skip — tests, types, config, docs, index, harness meta. Directory tokens
# are ANCHORED ((^|/)…/) so only a real path segment skips: 'src/subtypes/' must NOT
# inherit the 'types/' exemption. Case-insensitive to match SCOPE_RE.
SKIP_PATTERNS = [
    re.compile(r"\.(test|spec)\.(ts|tsx|js|jsx|py)$", re.IGNORECASE),
    re.compile(r"(^|/)(types|config|constants|locales|styles|fixtures)/", re.IGNORECASE),
    re.compile(r"\.(css|scss|json|d\.ts|md)$", re.IGNORECASE),
    re.compile(r"(/index\.(ts|js)$|env\.d\.ts)", re.IGNORECASE),
    re.compile(r"(^|/)\.agent/", re.IGNORECASE),
]


def repo_root():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return os.getcwd()


def session_id():
    return os.environ.get("AGENT_SESSION_ID", "")


def log_dryrun(root, file_path, verdict, reason, guard_area):
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "file_path": file_path,
        "verdict": verdict,
        "reason": reason,
        "guard_area": guard_area,
        "session_id": session_id(),
        "mode": MODE,
    }
    sink = os.path.join(root, DRYRUN_SINK_RELATIVE)
    try:
        os.makedirs(os.path.dirname(sink), exist_ok=True)
        with open(sink, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def emit_advisory(message):
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"spec-gate: {message}",
        }
    }
    sys.stdout.write(json.dumps(out))


def emit_ask(reason):
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": f"spec-gate: {reason}",
        },
    }
    sys.stdout.write(json.dumps(out))


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    file_path = (data.get("tool_input") or {}).get("file_path", "")
    if not file_path:
        sys.exit(0)

    # Plan approved this session → all edits allowed (the flag is the dedup).
    if os.path.exists(PLAN_FLAG):
        sys.exit(0)

    root = repo_root()

    # Risk-area whitelist
    for pat, area in GUARD_PATTERNS:
        if pat.search(file_path):
            log_dryrun(root, file_path, "guard_skip", area, area)
            sys.exit(0)

    # Scope filter
    if not SCOPE_RE.search(file_path):
        sys.exit(0)

    # Skip patterns (tests, types, config, docs, meta)
    for pat in SKIP_PATTERNS:
        if pat.search(file_path):
            sys.exit(0)

    # Substantive impl code, no approved plan this session.
    reason = (
        "no approved plan this session for substantive impl code. Run /spec "
        "(brainstorm -> spec.md -> plan.md, then approve the plan via ExitPlanMode), "
        "or set AGENT_SPEC_GATE_MODE=off to disable this gate."
    )
    log_dryrun(root, file_path, "would_ask" if MODE == "block" else "would_advise", reason, None)

    if MODE == "block":
        emit_ask(reason)
    else:
        emit_advisory(reason + " (dryrun mode — set AGENT_SPEC_GATE_MODE=block to enforce)")

    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail-open: a gate bug must never break the session (protocol §3, hard lesson 1).
        sys.exit(0)
