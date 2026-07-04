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


def resolve_log_dir(stdin_data: dict) -> str:
    """Log destination = the active project's .agent/logs.

    Resolve the project root at runtime so logs land in the user's project,
    not the plugin install cache (this file's own location). Priority:
    stdin event 'cwd' -> CLAUDE_PROJECT_DIR env -> os.getcwd().
    """
    cwd = stdin_data.get("cwd") if isinstance(stdin_data, dict) else ""
    root = cwd or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    return os.path.join(root, ".agent/logs")


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

    log_dir = resolve_log_dir(stdin_data)

    block_enabled = os.environ.get("AGENT_QUALITY_GATE_BLOCK", "1") == "1"

    files = get_changed_files()
    src_files = [
        f for f in files
        if any(prefix in f for prefix in SCAN_DIRS)
        and f.endswith((".tsx", ".ts"))
    ]

    if not src_files:
        print(json.dumps({}))
        sys.exit(0)

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

    if total_issues == 0:
        print(f"[quality gate] {len(src_files)} file(s) checked, 0 violations.",
              file=sys.stderr)
        print(json.dumps({}))
        sys.exit(0)

    summary = (
        f"[quality gate] {len(src_files)} file(s) checked, {total_issues} violation(s):\n"
        + "\n".join(file_reports)
    )
    print(summary, file=sys.stderr)

    # Append to violations log (cross-session learning).
    os.makedirs(log_dir, exist_ok=True)
    violations_file = os.path.join(log_dir, "quality-gate-violations.jsonl")
    try:
        with open(violations_file, "a", encoding="utf-8") as vf:
            vf.write(json.dumps({
                "ts": date.today().isoformat(),
                "files": len(src_files),
                "issues": total_issues,
                "details": file_reports[:5],
            }, ensure_ascii=False) + "\n")
    except Exception:
        pass

    # Completion gate: block on first Stop with violations. Second Stop passes
    # (user has decided "intentional violation"). Env escape forces advisory.
    if block_enabled and not stop_hook_active:
        reason = (
            f"{summary}\n\n"
            "Response halted by quality gate. Choose one:\n"
            "  (a) Resolve — move types to types.ts / tokenize colors /\n"
            "      remove console.log, then complete the response.\n"
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
