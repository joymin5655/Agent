#!/usr/bin/env python3
"""Configurable TDD PreToolUse hook.

Default mode is advisory (`dryrun`). Set `AGENT_TDD_GUARD_MODE=block` to deny
production writes when there is no nearby failing test evidence.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys

MODE = os.environ.get("AGENT_TDD_GUARD_MODE", "dryrun").lower()
if MODE == "off":
    sys.exit(0)

TTL_SECONDS = int(os.environ.get("AGENT_TDD_CACHE_TTL_SECONDS", "600"))
SCOPE_RE = re.compile(os.environ.get("AGENT_TDD_SCOPE_REGEX", r"src/.+\.(ts|tsx|js|jsx|py)$"))
SINK_RELATIVE = os.environ.get("AGENT_TDD_GUARD_SINK", ".claude/logs/tdd-guard-dryrun.jsonl")
CACHE_RELATIVE = os.environ.get("AGENT_TDD_CACHE", ".agent-harness/state/test-last-run.json")

GUARD_PATTERNS = [
    (re.compile(r"(^|/)(secrets/|\.env(\.|$))"), "secret"),
    (re.compile(r"(migrations?|schema).+\.(sql|ts|js|py)$"), "migration"),
    (re.compile(r"(billing|payments?|checkout)"), "billing"),
]

SKIP_PATTERNS = [
    re.compile(r"\.(test|spec)\.(ts|tsx|js|jsx|py)$"),
    re.compile(r"(^|/)(types|config|constants|locales|styles)/"),
    re.compile(r"\.(css|scss|json|md|d\.ts)$"),
    re.compile(r"(^|/)index\.(ts|tsx|js|jsx|py)$"),
]


def repo_root() -> Path:
    try:
        out = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], stderr=subprocess.DEVNULL)
        return Path(out.decode().strip())
    except Exception:
        return Path.cwd()


def _read_payload() -> dict:
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def _relpath(root: Path, path_text: str) -> str:
    path = Path(path_text)
    try:
        if path.is_absolute():
            return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return path_text
    return path_text


def log_dryrun(root: Path, file_path: str, verdict: str, reason: str, guard_area: str | None, cache_age_s: int) -> None:
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "file_path": file_path,
        "verdict": verdict,
        "reason": reason,
        "guard_area": guard_area,
        "cache_age_s": cache_age_s,
        "mode": MODE,
        "session_id": os.environ.get("AGENT_SESSION_ID", ""),
    }
    sink = root / SINK_RELATIVE
    try:
        sink.parent.mkdir(parents=True, exist_ok=True)
        with sink.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def emit_advisory(message: str) -> None:
    out = {
        "decision": "allow",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"tdd-guard: {message}",
        },
    }
    sys.stdout.write(json.dumps(out))


def emit_deny(reason: str) -> None:
    out = {
        "decision": "deny",
        "reason": f"tdd-guard: {reason}",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"tdd-guard blocked: {reason}",
        },
    }
    sys.stdout.write(json.dumps(out))


def cache_load(root: Path) -> tuple[dict | None, int]:
    cache_path = root / CACHE_RELATIVE
    if not cache_path.is_file():
        return None, 999999
    try:
        mtime = int(cache_path.stat().st_mtime)
        age = int(datetime.now(timezone.utc).timestamp()) - mtime
        return json.loads(cache_path.read_text(encoding="utf-8")), age
    except Exception:
        return None, 999999


def _test_candidates(rel_target: str) -> list[str]:
    target = Path(rel_target)
    stem = target.stem
    parent = str(target.parent)
    candidates: list[str] = []
    for directory in (parent, f"{parent}/__tests__", "tests"):
        for ext in ("test.ts", "test.tsx", "test.js", "test.jsx", "test.py", "spec.ts", "spec.tsx", "spec.py"):
            candidates.append(f"{directory}/{stem}.{ext}")
    return candidates


def resolve_failing_test(rel_target: str, cache: dict) -> tuple[str, str]:
    by_file = {item.get("file"): item for item in (cache.get("testResults") or []) if item.get("file")}
    matched = [candidate for candidate in _test_candidates(rel_target) if candidate in by_file]
    if not matched:
        return "would_block", "no nearby test file in last test result cache"

    has_assertions = False
    for test_file in matched:
        for assertion in by_file[test_file].get("assertionResults", []) or []:
            has_assertions = True
            if assertion.get("status") == "failed":
                return "would_allow", "failing test detected in target area"
    if has_assertions:
        return "would_block", "nearby tests are green; write or identify the failing test first"
    return "would_block", "nearby test file exists but no assertions were recorded"


def main() -> int:
    payload = _read_payload()
    file_path = str((payload.get("tool_input") or {}).get("file_path") or "")
    if not file_path:
        return 0

    root = repo_root()
    rel = _relpath(root, file_path)

    for pattern, area in GUARD_PATTERNS:
        if pattern.search(rel):
            log_dryrun(root, rel, "guard_skip", area, area, 0)
            return 0

    if not SCOPE_RE.search(rel):
        return 0

    for pattern in SKIP_PATTERNS:
        if pattern.search(rel):
            return 0

    cache, age = cache_load(root)
    if cache is None or age > TTL_SECONDS:
        reason = "cache missing or unreadable" if cache is None else f"cache stale ({age}s > {TTL_SECONDS}s TTL)"
        log_dryrun(root, rel, "mode_stale", reason, None, age)
        if MODE == "block":
            emit_advisory(f"{reason}; run the relevant test command to refresh {CACHE_RELATIVE}")
        return 0

    verdict, reason = resolve_failing_test(rel, cache)
    log_dryrun(root, rel, verdict, reason, None, age)
    if verdict == "would_allow":
        return 0
    if MODE == "block":
        emit_deny(reason)
    else:
        emit_advisory(f"would block: {reason} (dryrun mode; set AGENT_TDD_GUARD_MODE=block to enforce)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
