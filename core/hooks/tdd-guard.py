#!/usr/bin/env python3
"""tdd-guard PreToolUse hook — RGR-aware TDD enforcement.

Blocks creating new production code when a corresponding failing test doesn't exist.
Implements the Red-Green-Refactor (RGR) discipline at hook level.

Modes (AGENT_TDD_GUARD_MODE):
  - off     — skip entirely
  - dryrun  — log verdict but never block (default — observation phase)
  - block   — return permissionDecision=deny when RGR rules violated

Configuration env vars:
  - AGENT_TDD_GUARD_MODE          off | dryrun | block
  - AGENT_TDD_GUARD_SINK          relative path for dryrun jsonl (default .agent/logs/tdd-guard-dryrun.jsonl)
  - AGENT_TDD_SCOPE_REGEX         file path regex to enforce on (default: src/.+\\.(ts|tsx|js|jsx|py)$)
  - AGENT_TDD_CACHE_PATH          relative path to test run cache JSON (default .agent/state/test-last-run.json)
  - AGENT_TDD_CACHE_TTL           cache TTL in seconds (default 600)

Risk-area whitelist:
  Files matching project risk-area patterns (production data / secrets / deploy / etc.) are
  exempted — RGR enforcement defers to risk-area hooks. Define in hook-config.yml.

Decision flow:
  1. Mode check
  2. Parse tool_input.file_path
  3. Risk-area whitelist (immediate allow if matched)
  4. Scope filter
  5. Skip patterns (tests, types, config, etc.)
  6. Cache freshness
  7. Failing test resolution
  8. Verdict → dryrun jsonl + (advisory or deny based on mode)

Hook protocol: reads canonical event JSON from stdin, writes decision JSON or empty.
Exit always 0.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

MODE = os.environ.get("AGENT_TDD_GUARD_MODE", "dryrun")
if MODE == "off":
    sys.exit(0)

TTL_SECONDS = int(os.environ.get("AGENT_TDD_CACHE_TTL", "600"))
DRYRUN_SINK_RELATIVE = os.environ.get(
    "AGENT_TDD_GUARD_SINK", ".agent/logs/tdd-guard-dryrun.jsonl"
)
CACHE_RELATIVE = os.environ.get(
    "AGENT_TDD_CACHE_PATH", ".agent/state/test-last-run.json"
)

# Risk-area whitelist — files matching these patterns skip TDD enforcement.
# Edit this list or override via hook-config.yml: risk_areas[].paths.
# Each entry: (compiled-regex, category-label).
GUARD_PATTERNS = [
    (re.compile(r"(^|/)migrations/.+\.sql$"), "production-migration"),
    (re.compile(r"(^|/)(secrets/|\.env)"), "secret"),
    (re.compile(r"(^|/)functions/[^/]+/index\.(ts|js)$"), "edge-fn"),
    (re.compile(r"(^|/)billing/"), "billing"),
]

# Scope — only enforce TDD on files matching this. Configurable via env.
SCOPE_RE = re.compile(
    os.environ.get("AGENT_TDD_SCOPE_REGEX", r"(^|/)src/.+\.(ts|tsx|js|jsx|py)$")
)

# Files to skip — tests themselves, types, config, etc.
SKIP_PATTERNS = [
    re.compile(r"\.(test|spec)\.(ts|tsx|js|jsx|py)$"),
    re.compile(r"(types/|config/|constants/|locales/|styles/|fixtures/)"),
    re.compile(r"\.(css|scss|json|d\.ts)$"),
    re.compile(r"(/index\.(ts|js)$|env\.d\.ts)"),
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


def log_dryrun(root, file_path, verdict, reason, guard_area, cache_age_s):
    rec = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "file_path": file_path,
        "verdict": verdict,
        "reason": reason,
        "cache_age_s": cache_age_s,
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
            "additionalContext": f"tdd-guard: {message}",
        }
    }
    sys.stdout.write(json.dumps(out))


def emit_deny(reason):
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": f"tdd-guard: {reason}",
        },
    }
    sys.stdout.write(json.dumps(out))


def cache_load(root):
    cache_path = os.path.join(root, CACHE_RELATIVE)
    if not os.path.isfile(cache_path):
        return None, 999999
    try:
        mtime = int(os.path.getmtime(cache_path))
        age = int(datetime.now(timezone.utc).timestamp()) - mtime
        with open(cache_path) as f:
            cache = json.load(f)
        return cache, age
    except Exception:
        return None, 999999


def resolve_failing_test(rel_target, cache):
    """Return (verdict, reason). verdict in {would_allow, would_block}."""
    target_dir = os.path.dirname(rel_target)
    target_basename = os.path.splitext(os.path.basename(rel_target))[0]

    candidates = []
    for d in [target_dir, f"{target_dir}/__tests__"]:
        for ext in ["test.ts", "test.tsx", "spec.ts", "spec.tsx",
                    "test.js", "test.jsx", "spec.js", "spec.jsx",
                    "test.py", "spec.py"]:
            candidates.append(f"{d}/{target_basename}.{ext}")

    by_file = {tr["file"]: tr for tr in (cache.get("testResults") or [])}
    matched = [c for c in candidates if c in by_file]

    if not matched:
        return "would_block", "no test file in area (write failing test first)"

    has_failing = False
    has_any = False
    for tf in matched:
        for ar in by_file[tf].get("assertionResults", []) or []:
            has_any = True
            if ar.get("status") == "failed":
                has_failing = True
                break
        if has_failing:
            break

    if has_failing:
        return "would_allow", "failing test detected in area (RGR red phase)"
    if has_any:
        return "would_block", "test file all green — write failing test or invoke refactor mode"
    return "would_block", "test file exists but no assertions detected"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    file_path = (data.get("tool_input") or {}).get("file_path", "")
    if not file_path:
        sys.exit(0)

    root = repo_root()

    # Risk-area whitelist
    for pat, area in GUARD_PATTERNS:
        if pat.search(file_path):
            log_dryrun(root, file_path, "guard_skip", area, area, 0)
            sys.exit(0)

    # Scope filter
    if not SCOPE_RE.search(file_path):
        sys.exit(0)

    # Existing skip patterns
    for pat in SKIP_PATTERNS:
        if pat.search(file_path):
            sys.exit(0)

    # Cache freshness
    cache, age = cache_load(root)
    if cache is None or age > TTL_SECONDS:
        reason = (
            "cache missing or unreadable" if cache is None
            else f"cache stale ({age}s > {TTL_SECONDS}s TTL)"
        )
        log_dryrun(root, file_path, "mode_stale", reason, None, age)
        if MODE == "block":
            emit_advisory(
                f"test cache stale ({age}s). Run your test suite to enable RGR enforcement."
            )
        sys.exit(0)

    rel = file_path
    if file_path.startswith(root + "/"):
        rel = file_path[len(root) + 1:]

    verdict, reason = resolve_failing_test(rel, cache)
    log_dryrun(root, file_path, verdict, reason, None, age)

    if verdict == "would_allow":
        sys.exit(0)

    if MODE == "block":
        emit_deny(reason)
    else:
        emit_advisory(f"would block: {reason} (dryrun mode — set AGENT_TDD_GUARD_MODE=block to enforce)")

    sys.exit(0)


if __name__ == "__main__":
    main()
