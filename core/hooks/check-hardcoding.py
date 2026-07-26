#!/usr/bin/env python3
"""PreToolUse hook — Detect hardcoded constants in Write/Edit content.

Flags common hardcoding anti-patterns:
  - Inline RGB color arrays (style values that should live in a theme/config)
  - Linear-gradient strings with hardcoded RGB values
  - Const arrays of tick/label/stop strings (chart data that should come from config)

Modes (AGENT_HARDCODING_MODE):
  - off     — skip entirely
  - dryrun  — advisory + jsonl log, never blocks (default — this is a DESIGN-TASTE
              gate, not an irreversibility/secret gate, so per the harness
              escalation principle it must not hard-deny by default)
  - block   — return permissionDecision=deny (the pre-2026-07 behavior, opt-in)

Configuration env vars:
  - AGENT_HARDCODING_MODE   off | dryrun | block
  - AGENT_HARDCODING_SINK   jsonl sink (default .agent/logs/hardcoding.jsonl)

NOTE: the built-in pattern list below is currently the only pattern source —
`hook-config.yml: hardcoding_patterns[]` is a PLANNED extension seam (backlog
T-4), not yet wired. Until T-4 lands, customize by mode env only.

Hook protocol: reads canonical event JSON from stdin, writes decision JSON
(deny) or advisory JSON to stdout on match, or empty stdout (allow) otherwise.
Exit always 0. Fail-open: any exception → exit 0, never block on error.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

MODE = os.environ.get("AGENT_HARDCODING_MODE", "dryrun")
if MODE == "off":
    sys.exit(0)

SINK_RELATIVE = os.environ.get("AGENT_HARDCODING_SINK", ".agent/logs/hardcoding.jsonl")

# Files / path patterns exempt from hardcoding checks
EXEMPT_PATHS = {
    "config.ts",
    "config.js",
    "config.py",
    "types.ts",
    "types.js",
    ".test.",
    ".spec.",
    "test/",
    "__tests__/",
    ".yml",
    ".yaml",
    ".md",
    ".json",
    "tailwind.config",
    "vite.config",
    "webpack.config",
    "rollup.config",
    "tsconfig",
    "eslint",
    "prettier",
    ".html",
    "assets/",
    "/fixtures/",
    "/legacy/",
    # Self + sibling test script (cite the same patterns as fixtures —
    # same precedent as secret-content-scan.py's self-exemption)
    "check-hardcoding.py",
    "check-hardcoding-test.sh",
}

# Generic hardcoding patterns (built-in only until T-4 wires hook-config.yml).
HARDCODING_PATTERNS = [
    # Inline color segment arrays: [number, [r, g, b]]
    (
        r'\[\s*\d+\s*,\s*\[\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\]\s*\]',
        "Inline color segment array — define in a theme/config file and import",
    ),
    # CSS gradient strings with rgb values
    (
        r"linear-gradient\s*\(\s*\d+deg\s*,\s*rgb\(",
        "Hardcoded CSS gradient — derive from a config color scale",
    ),
    # Const arrays of tick/label/stop strings
    (
        r"(?:const|let|var)\s+\w*(?:TICK|LABEL|STOP).*=\s*\[",
        "Hardcoded tick/label/stop array — define in a config file and import",
    ),
]

# Component-area specific check. Only fires on files in components / hooks / pages dirs.
COMPONENT_PATTERNS = [
    (
        r"(?:const|let|var)\s+(?:MODES|LAYERS|OPTIONS)\s*[=:]",
        "UI metadata array defined in component — extract to a config file and import",
    ),
]


def is_exempt(file_path: str) -> bool:
    for pattern in EXEMPT_PATHS:
        if pattern in file_path:
            return True
    return False


def check_content(content: str, file_path: str) -> list[str]:
    warnings = []
    for pattern, message in HARDCODING_PATTERNS:
        matches = re.findall(pattern, content)
        if matches:
            warnings.append(f"[HARDCODING] {message} (found {len(matches)} match(es))")
    if "/components/" in file_path or "/hooks/" in file_path or "/pages/" in file_path:
        for pattern, message in COMPONENT_PATTERNS:
            if re.search(pattern, content):
                warnings.append(f"[HARDCODING] {message}")
    return warnings


def repo_root() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return os.getcwd()


def log_firing(file_path: str, verdict: str, warning_count: int) -> None:
    """Append a firing record to the jsonl sink (gate-registry instrumentation).
    Matches the schema written by the other guard hooks (schema_version 2.0.0);
    guard+hook let telemetry-digest attribute the record unambiguously, and
    AGENT_REPRODUCE_TEST marks battery-fed synthetic events so they never
    inflate fire-rate/FATIGUE."""
    repro_env = os.environ.get("AGENT_REPRODUCE_TEST", "")
    rec = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "guard": "hardcoding",
        "hook": "check-hardcoding.py",
        "file_path": file_path,
        "decision": verdict,
        "warnings": warning_count,
        "mode": MODE,
        "session_id": os.environ.get("AGENT_SESSION_ID", "main"),
        "reproduce_test": repro_env in ("1", "true", "TRUE", "True"),
        "schema_version": "2.0.0",
    }
    sink = os.path.join(repo_root(), SINK_RELATIVE)
    try:
        os.makedirs(os.path.dirname(sink), exist_ok=True)
        with open(sink, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def emit_deny(reason: str) -> None:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(output, ensure_ascii=False))


def emit_advisory(message: str) -> None:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"check-hardcoding: {message}",
        }
    }
    print(json.dumps(output, ensure_ascii=False))


def main():
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit(0)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_input = data.get("tool_input", {})
    file_path = tool_input.get("file_path", "")
    if not file_path:
        sys.exit(0)

    if is_exempt(file_path):
        sys.exit(0)

    content = tool_input.get("content", "")
    if not content:
        content = tool_input.get("new_string", "")
    if not content:
        sys.exit(0)

    warnings = check_content(content, file_path)
    if not warnings:
        sys.exit(0)

    log_firing(file_path, "denied" if MODE == "block" else "would_deny", len(warnings))

    label = "BLOCKED" if MODE == "block" else "ADVISORY"
    print(f"[Hook] {label}: Hardcoding detected in {file_path.split('/')[-1]}", file=sys.stderr)
    for w in warnings:
        print(f"  {w}", file=sys.stderr)
    print("\nExtract constants to a config file and import them. "
          "(Pattern customization via hook-config.yml is planned — backlog T-4; "
          "until then use AGENT_HARDCODING_MODE=off|dryrun|block.)", file=sys.stderr)

    # Teaching format (T-1): WHY + FIX so the agent can self-correct.
    reason = (
        "Hardcoding detected in " + file_path.split("/")[-1] + "\n"
        "WHY: design-hardcoding guard — inline style/config constants drift from the "
        "theme and dodge the config review path.\n"
        "FIX: extract the values to a config/theme file and import them. "
        "(Pattern customization via hook-config.yml is planned — backlog T-4; "
        "until then use AGENT_HARDCODING_MODE=off|dryrun|block.)"
    )
    if MODE == "block":
        emit_deny(reason)
    else:
        emit_advisory(reason + "\n(dryrun mode — set AGENT_HARDCODING_MODE=block to enforce)")
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail-open: a gate bug must never break the session (protocol §3).
        sys.exit(0)
