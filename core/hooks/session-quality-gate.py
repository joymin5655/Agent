#!/usr/bin/env python3
"""Stop hook — completion gate for code-quality violations.

Inspects the session's git diff at Stop time. If any changed source file
has unresolved style/quality violations (inline types, hardcoded colors,
console.log statements), the hook EMITS `decision: block` and the AI
must address them before the session can end.

Anti-infinite-loop: `stop_hook_active=true` on stdin means this Stop was
already blocked once. We pass on the second Stop so the user can break out
by deciding "intentional violation".

Escape hatch: AGENT_QUALITY_GATE_BLOCK=0 → advisory only (no block).

Configuration (env vars):
  AGENT_QUALITY_GATE_BLOCK=1 (default)   enable block enforcement
  AGENT_QUALITY_GATE_BLOCK=0             advisory only
  AGENT_QUALITY_SCAN_DIRS                comma-separated dir prefixes to scan
                                          (default: 'src/')
"""
import json
import os
import re
import subprocess
import sys
from datetime import date

SCAN_DIRS = tuple(
    s.strip()
    for s in os.environ.get("AGENT_QUALITY_SCAN_DIRS", "src/").split(",")
    if s.strip()
)


def resolve_root(stdin_data: dict) -> str:
    """Active project root at runtime, so hooks act on the user's project — not
    the plugin install cache (this file's own location). Priority:
    stdin event 'cwd' -> CLAUDE_PROJECT_DIR env -> os.getcwd().
    """
    cwd = stdin_data.get("cwd") if isinstance(stdin_data, dict) else ""
    return cwd or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def resolve_log_dir(stdin_data: dict) -> str:
    """Log destination = the active project's .agent/logs."""
    return os.path.join(resolve_root(stdin_data), ".agent/logs")


# Per-command wall-clock bound for a completion test (seconds). Overridable so a
# slow suite can raise it; a runaway command can never hang the Stop event.
def _parse_timeout(raw: str) -> int:
    """Parse the per-command timeout, degrading to 120 on any bad value. This
    runs at import (before main()'s try/except), so a typo like '2m' or '30s'
    must NEVER raise — that would crash the Stop hook and break the load-bearing
    'Stop always exits 0' contract. A non-positive value also degrades to 120."""
    try:
        v = int(raw)
    except (TypeError, ValueError):
        return 120
    return v if v > 0 else 120


COMPLETION_TEST_TIMEOUT = _parse_timeout(os.environ.get("AGENT_COMPLETION_TEST_TIMEOUT", "120"))


def run_completion_tests(root: str) -> list[str]:
    """Run the project's `session.completion_tests` (P3-1) in `root`.

    Returns a list of human-readable failure descriptions — empty when all pass
    or none are configured. A nonzero exit, a timeout, OR a spawn error each
    counts as a failure: an unverifiable completion must not silently pass. This
    NEVER raises (a broken config or a missing interpreter degrades to []).
    """
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import hook_config  # noqa: E402
        cmds = hook_config.load_session_config(root).get("completion_tests", [])
    except Exception:
        return []

    failures: list[str] = []
    for cmd in cmds:
        try:
            r = subprocess.run(
                cmd, shell=True, cwd=root or None,
                capture_output=True, text=True, timeout=COMPLETION_TEST_TIMEOUT,
                # Run the command in its OWN process group/session so a teardown
                # idiom that signals its GROUP (`kill 0`, `trap 'kill 0' EXIT`) —
                # the common Makefile/integration-test teardown case — reaches only
                # the command's own group, not this hook. Without it a group signal
                # kills the hook with a signal code + empty stdout, breaking the
                # 'Stop always exits 0' contract.
                #
                # Residual boundary: this changes the process GROUP, not parentage,
                # so a command that reads $PPID and signals the hook's own pid
                # directly with an UNCATCHABLE signal (`kill -9 $PPID`) cannot be
                # defended from inside the process. That is a deliberate self-attack
                # at the project's OWN trust level (completion_tests run as the
                # project's package.json scripts do), and its outcome is a fail-open
                # non-blocking stop — never corruption or a weakened security gate.
                start_new_session=True,
            )
            if r.returncode != 0:
                tail = (r.stderr or r.stdout or "").strip().splitlines()[-3:]
                detail = (" — " + " / ".join(t.strip() for t in tail)) if tail else ""
                failures.append(f"`{cmd}` exited {r.returncode}{detail}")
        except subprocess.TimeoutExpired:
            failures.append(f"`{cmd}` timed out after {COMPLETION_TEST_TIMEOUT}s")
        except Exception as e:  # spawn error, etc. — unverifiable => failure
            failures.append(f"`{cmd}` could not run ({type(e).__name__})")
    return failures


def get_changed_files() -> list[str]:
    """Return modified + untracked files from git."""
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        files = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
        result2 = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            capture_output=True, text=True, timeout=5,
        )
        untracked = [f.strip() for f in result2.stdout.strip().split("\n") if f.strip()]
        return files + untracked
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []


def check_file(filepath: str) -> list[str]:
    """Run quick rule checks against a single file. Returns issue list."""
    issues: list[str] = []

    if not os.path.exists(filepath):
        return issues
    if not filepath.endswith((".tsx", ".ts")):
        return issues
    if "node_modules" in filepath or "dist/" in filepath:
        return issues

    try:
        with open(filepath, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return issues

    # 1. Inline types (outside dedicated types files)
    if "/types" not in filepath and "/types.ts" not in filepath:
        inline_types = re.findall(
            r"^(?:export\s+)?(?:interface|type)\s+(\w+)",
            content, re.MULTILINE,
        )
        non_props = [t for t in inline_types if not t.endswith("Props")]
        if non_props:
            issues.append(f"inline types: {', '.join(non_props[:3])}")

    # 2. Hardcoded hex colors in pages/components
    if "/pages/" in filepath or "/components/" in filepath:
        hex_count = len(re.findall(r"\[#[0-9a-fA-F]{3,8}\]", content))
        if hex_count > 0:
            issues.append(f"hardcoded colors: {hex_count} occurrence(s)")

    # 3. console.log left behind
    console_logs = len(re.findall(r"console\.log\(", content))
    if console_logs > 0:
        issues.append(f"console.log: {console_logs} occurrence(s)")

    return issues


def main() -> None:
    # Stop hook input: {"session_id":"...","transcript_path":"...","cwd":"...",
    #                   "hook_event_name":"Stop","stop_hook_active":bool}
    stop_hook_active = False
    stdin_data: dict = {}
    try:
        stdin_data = json.load(sys.stdin)
        if isinstance(stdin_data, dict):
            stop_hook_active = bool(stdin_data.get("stop_hook_active", False))
    except (json.JSONDecodeError, EOFError):
        pass

    root = resolve_root(stdin_data)
    log_dir = os.path.join(root, ".agent/logs")

    block_enabled = os.environ.get("AGENT_QUALITY_GATE_BLOCK", "1") == "1"
    # Enforce only on the first Stop (anti-loop: a second Stop passes) and only
    # when block is enabled (advisory mode never runs tests or blocks).
    enforcing = block_enabled and not stop_hook_active

    # P3-1: run the project's session.completion_tests. Gated on `enforcing` so
    # a second Stop or advisory mode neither runs the suite nor blocks.
    completion_failures = run_completion_tests(root) if enforcing else []

    files = get_changed_files()
    src_files = [
        f for f in files
        if any(prefix in f for prefix in SCAN_DIRS)
        and f.endswith((".tsx", ".ts"))
    ]

    total_issues = 0
    file_reports: list[str] = []
    for filepath in src_files:
        issues = check_file(filepath)
        if issues:
            total_issues += len(issues)
            file_reports.append(
                f"  {os.path.basename(filepath)}:\n"
                + "\n".join(f"    - {i}" for i in issues)
            )

    # Both gates clean -> pass.
    if total_issues == 0 and not completion_failures:
        if src_files:
            print(f"[quality gate] {len(src_files)} file(s) checked, 0 violations.",
                  file=sys.stderr)
        print(json.dumps({}))
        sys.exit(0)

    parts: list[str] = []
    if total_issues:
        parts.append(
            f"[quality gate] {len(src_files)} file(s) checked, {total_issues} violation(s):\n"
            + "\n".join(file_reports)
        )
    if completion_failures:
        parts.append(
            f"[completion gate] {len(completion_failures)} test command(s) failed:\n"
            + "\n".join(f"    - {f}" for f in completion_failures)
        )
    summary = "\n\n".join(parts)
    print(summary, file=sys.stderr)

    # Append to violations log (cross-session learning). log_dir derives from
    # untrusted stdin cwd — a bogus/unwritable path must not crash the Stop hook.
    violations_file = os.path.join(log_dir, "quality-gate-violations.jsonl")
    try:
        os.makedirs(log_dir, exist_ok=True)
        with open(violations_file, "a", encoding="utf-8") as vf:
            vf.write(json.dumps({
                "ts": date.today().isoformat(),
                "files": len(src_files),
                "issues": total_issues,
                "completion_failures": len(completion_failures),
                "details": file_reports[:5],
            }, ensure_ascii=False) + "\n")
    except Exception:
        pass

    # Completion gate: block on the first Stop with any failure. Second Stop
    # passes (user decided "intentional"). Advisory mode (BLOCK=0) never blocks.
    if enforcing:
        # Teaching format (T-1): WHY + FIX so the agent can self-correct.
        reason = (
            f"{summary}\n\n"
            "Response halted by quality gate.\n"
            "WHY: completion gate — the session diff still carries quality violations "
            "or failing completion tests; ending now would ship them silently.\n"
            "FIX: choose one:\n"
            "  (a) Resolve — fix the failing test(s) / move types to types.ts /\n"
            "      tokenize colors / remove console.log, then complete.\n"
            "  (b) Intentional — state the reason explicitly, then complete\n"
            "      (the second Stop will pass automatically).\n"
            "  (c) Disable for this session: set AGENT_QUALITY_GATE_BLOCK=0\n"
            "      in the environment."
        )
        print(json.dumps({"decision": "block", "reason": reason}))
        sys.exit(0)

    print(json.dumps({}))
    sys.exit(0)


if __name__ == "__main__":
    main()
