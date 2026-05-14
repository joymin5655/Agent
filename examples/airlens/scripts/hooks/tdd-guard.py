#!/usr/bin/env python3
"""
tdd-guard PreToolUse hook (frosted-mason Phase 2 + Phase 3).

Strengthened from advisory-only (original 48-line bash) to RGR-aware enforcement.

Decision flow:
  1. Mode check (AIRLENS_TDD_GUARD_MODE: dryrun|block|off, default dryrun)
  2. Parse stdin -> tool_input.file_path
  3. Phase 3 — 5-guard whitelist (production-migration / secret / edge-fn / billing) -> guard_skip
  4. Scope filter (Phase 1 default = A, apps/web/src/) -> skip if outside
  5. Skip patterns preserved from original L20-26 (test/spec/types/config/etc.)
  6. Cache freshness (mtime > 600s = stale) -> mode_stale, always allow
  7. Failing test resolution in target file area
  8. Verdict -> dryrun jsonl + advisory (dryrun) or decision:deny (block)

Plan: ~/.claude/plans/tdd-guard-self-strengthen-frosted-mason.md §Phase 2 + §Phase 3
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

MODE = os.environ.get("AIRLENS_TDD_GUARD_MODE", "dryrun")
if MODE == "off":
    sys.exit(0)

TTL_SECONDS = 600
DRYRUN_SINK_RELATIVE = os.environ.get(
    "AIRLENS_TDD_GUARD_SINK", ".claude/logs/tdd-guard-dryrun.jsonl"
)
CACHE_RELATIVE = ".claude/state/vitest-last-run.json"

# Phase 3 — 5-guard whitelist (CRITICAL — security-guards.md SOT)
# ML uncertainty (#5) deferred to scope B/C (models/) — Phase 1 = scope A only.
GUARD_PATTERNS = [
    (re.compile(r"supabase/migrations/.+\.sql$"), "production-migration"),
    (re.compile(r"(^|/)(secrets/|\.env)"), "secret"),
    (re.compile(r"supabase/functions/[^/]+/index\.ts$"), "edge-fn"),
    (re.compile(r"apps/.+/billing/"), "billing"),
]

SCOPE_RE = re.compile(r"apps/web/src/.+\.(ts|tsx)$")

SKIP_PATTERNS = [
    re.compile(r"\.(test|spec)\.(ts|tsx)$"),
    re.compile(r"(types/|config/|constants/|locales/|styles/)"),
    re.compile(r"\.(css|scss|json|d\.ts)$"),
    re.compile(r"(/index\.ts$|vite-env)"),
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
        "decision": "deny",
        "reason": f"tdd-guard: {reason}",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": f"tdd-guard blocked: {reason}",
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
        for ext in ["test.ts", "test.tsx", "spec.ts", "spec.tsx"]:
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

    # Phase 3 — 5-guard whitelist (CRITICAL, immediate allow)
    for pat, area in GUARD_PATTERNS:
        if pat.search(file_path):
            log_dryrun(root, file_path, "guard_skip", area, area, 0)
            sys.exit(0)

    # Scope filter (Phase 1 default = A)
    if not SCOPE_RE.search(file_path):
        sys.exit(0)

    # Existing skip patterns (preserved from original L20-26)
    for pat in SKIP_PATTERNS:
        if pat.search(file_path):
            sys.exit(0)

    # Cache freshness
    cache, age = cache_load(root)
    if cache is None or age > TTL_SECONDS:
        reason = (
            f"cache missing or unreadable" if cache is None
            else f"cache stale ({age}s > {TTL_SECONDS}s TTL)"
        )
        log_dryrun(root, file_path, "mode_stale", reason, None, age)
        if MODE == "block":
            rel = file_path.split("/apps/web/", 1)[-1] if "/apps/web/" in file_path else file_path
            emit_advisory(
                f"vitest cache stale ({age}s). Run `npm run test:run` in apps/web to enable RGR enforcement. ({rel})"
            )
        sys.exit(0)

    # Relative path normalization
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
        emit_advisory(f"would block: {reason} (dryrun mode — set AIRLENS_TDD_GUARD_MODE=block to enforce)")

    sys.exit(0)


if __name__ == "__main__":
    main()
