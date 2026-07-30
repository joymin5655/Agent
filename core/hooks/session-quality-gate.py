#!/usr/bin/env python3
"""Stop hook — completion gate for code-quality violations.

Two layers, calibrated separately (2026-07-27 guard-trim):

  1. COMPLETION gate (objective, consumer-declared): runs the project's
     `session.completion_tests` (P3-1). Any failure EMITS `decision: block` —
     an unverifiable completion must not end the session silently.
  2. STYLE scan (subjective taste: inline types, hardcoded colors,
     console.log): ADVISORY by default — findings are reported and logged but
     never block. Per the harness escalation principle, a style opinion is not
     an irreversibility/secret gate. Opt back into the pre-2026-07 blocking
     behavior with AGENT_QUALITY_STYLE_BLOCK=1.
  3. UNVERIFIED-SESSION advisory (objective, needs no project config): layer 1
     only fires where a consumer declares `completion_tests` — "Unset/empty =>
     the gate does nothing" (docs/hook-config.md) — so a session with no such
     config can rewrite code end to end, run nothing, and end clean. The gate
     registry recorded exactly that: `quality-completion` shows zero local
     firings because no consumer declares the key. This layer reads the records
     written by core/hooks/verify-observer.py and notes when the session diff
     carries code changes but no verification command was ever invoked.
     OBSERVE-ONLY by default (records + advisory, never blocks); opt into
     blocking with AGENT_VERIFY_OBSERVER_BLOCK=1. Effect is measured through the
     gate registry (`verify-observed`) BEFORE it is enforced — a gate whose
     value is unmeasured does not get to block.
     It never claims a verification PASSED: this runtime supplies no exit status
     (measured 2026-07-30, see core/hooks/circuit-breaker.py), so presence of an
     invocation is the only honest signal.

Anti-infinite-loop: `stop_hook_active=true` on stdin means this Stop was
already blocked once. We pass on the second Stop so the user can break out
by deciding "intentional violation".

Escape hatch: AGENT_QUALITY_GATE_BLOCK=0 → advisory only (no block at all).

Configuration (env vars):
  AGENT_QUALITY_GATE_BLOCK=1 (default)   enable block enforcement (master)
  AGENT_QUALITY_GATE_BLOCK=0             advisory only (never blocks)
  AGENT_QUALITY_STYLE_BLOCK=0 (default)  style findings are advisory
  AGENT_QUALITY_STYLE_BLOCK=1            style findings also block (opt-in)
  AGENT_QUALITY_SCAN_DIRS                comma-separated dir prefixes to scan
                                          (default: 'src/')
  AGENT_VERIFY_OBSERVER_BLOCK=0 (default) unverified-session finding is advisory
  AGENT_VERIFY_OBSERVER_BLOCK=1          unverified-session finding also blocks
  AGENT_VERIFY_OBSERVED_SINK             override the observer sink path
                                          (same seam as verify-observer.py)
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import date, datetime, timezone

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


def get_changed_files(root: str = "") -> list[str]:
    """Return modified + untracked files from git.

    `root` scopes the git invocation to a specific project dir. It defaults to
    "" (git runs in this process's cwd) so the layer-2 style scan keeps its
    existing behavior unchanged; layer 3 passes the resolved root explicitly
    because it must be deterministic — a non-git fixture dir has to yield zero
    changed files rather than inheriting whatever the real repo tree looks like.
    """
    cwd = root or None
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            capture_output=True, text=True, timeout=5, cwd=cwd,
        )
        files = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
        result2 = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            capture_output=True, text=True, timeout=5, cwd=cwd,
        )
        untracked = [f.strip() for f in result2.stdout.strip().split("\n") if f.strip()]
        return files + untracked
    except (subprocess.TimeoutExpired, FileNotFoundError, NotADirectoryError, OSError):
        return []


# ---------------------------------------------------------------------------
# Layer 3 — unverified-session advisory (see module docstring)
# ---------------------------------------------------------------------------

# Sink filename is shared with core/hooks/verify-observer.py, which WRITES the
# invocation records this gate READS. Keep the two in sync.
VERIFY_SINK_NAME = "verify-observed.jsonl"
VERIFY_GUARD = "verify-observed"

# Only these count as "code changed". An allowlist (not a docs denylist) keeps a
# new/unknown extension from silently counting as code and firing the advisory.
CODE_EXTS = (
    ".py", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".go", ".rs", ".rb",
    ".java", ".kt", ".swift", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs", ".php",
    ".sh", ".bash", ".zsh", ".sql", ".vue", ".svelte", ".scala", ".ex", ".exs",
)

# Bound the tail read so a long-lived sink cannot make the Stop event slow. One
# session's records sit at the end of the file; 512 KiB is thousands of records,
# far more than any single session writes.
_SINK_TAIL_BYTES = 512 * 1024


def verify_sink_path(root: str) -> str:
    """Sink path, with the override confined to the project's .agent/logs or the
    system temp dir. Confinement is decided on the REALPATH so a symlink or a
    '../' segment cannot redirect reads/writes outside those roots."""
    fallback = os.path.join(root, ".agent", "logs", VERIFY_SINK_NAME)
    override = os.environ.get("AGENT_VERIFY_OBSERVED_SINK")
    if not override:
        return fallback
    try:
        candidate = os.path.realpath(override)
        allowed = [
            os.path.realpath(os.path.join(root, ".agent", "logs")),
            os.path.realpath(tempfile.gettempdir()),
        ]
    except OSError:
        return fallback
    for base in allowed:
        if candidate == base or candidate.startswith(base + os.sep):
            return override
    return fallback


def session_ran_verification(root: str, session_id: str) -> bool:
    """True when this session invoked at least one verification command."""
    if not session_id:
        return False
    path = verify_sink_path(root)
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - _SINK_TAIL_BYTES))
            chunk = fh.read()
    except (OSError, ValueError):
        return False
    lines = chunk.decode("utf-8", "ignore").splitlines()
    if size > _SINK_TAIL_BYTES and lines:
        lines = lines[1:]          # first line is a partial record
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        if (rec.get("event") == "verification_invoked"
                and rec.get("session_id") == session_id):
            return True
    return False


def unverified_note(root: str, session_id: str) -> tuple[str, int]:
    """('' , 0) when there is nothing to say; otherwise (advisory text, n files).

    Deliberately makes no claim about whether anything PASSED — see layer 3 in
    the module docstring.
    """
    changed = [f for f in get_changed_files(root) if f.endswith(CODE_EXTS)]
    if not changed:
        return "", 0
    if session_ran_verification(root, session_id):
        return "", 0
    shown = ", ".join(os.path.basename(f) for f in changed[:5])
    if len(changed) > 5:
        shown += f", +{len(changed) - 5} more"
    return (
        f"[verify-observer] {len(changed)} code file(s) changed this session and "
        f"no verification command was observed ({shown}).\n"
        "WHY: nothing in this session ran the project's tests, type check, lint, "
        "or build, so no evidence exists that the changes behave as intended. "
        "This gate observes invocations only — it makes no claim about whether "
        "anything passed.\n"
        "FIX: run the narrowest relevant check (a focused test, a type check, or "
        "this repo's own battery), or state explicitly why none applies."
    ), len(changed)


def record_verify_firing(root: str, session_id: str, n_files: int, decision: str) -> None:
    """Log the layer-3 firing so `telemetry-digest --gates` can measure it.
    `hook` is this gate (not the observer) so the digest counts firings, not the
    observer's invocation records, which share the sink."""
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "guard": VERIFY_GUARD,
        "hook": "session-quality-gate.py",
        "schema_version": "1.0.0",
        "session_id": session_id or "no-session",
        "event": "unverified_session",
        "decision": decision,
        "changed_code_files": n_files,
    }
    if os.environ.get("AGENT_REPRODUCE_TEST") == "1":
        record["reproduce_test"] = True
    path = verify_sink_path(root)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


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

    session_id = str(stdin_data.get("session_id") or "") if isinstance(stdin_data, dict) else ""

    block_enabled = os.environ.get("AGENT_QUALITY_GATE_BLOCK", "1") == "1"
    style_block = os.environ.get("AGENT_QUALITY_STYLE_BLOCK", "0") == "1"
    verify_block = os.environ.get("AGENT_VERIFY_OBSERVER_BLOCK", "0") == "1"
    # Enforce only on the first Stop (anti-loop: a second Stop passes) and only
    # when block is enabled (advisory mode never runs tests or blocks).
    enforcing = block_enabled and not stop_hook_active

    # P3-1: run the project's session.completion_tests. Gated on `enforcing` so
    # a second Stop or advisory mode neither runs the suite nor blocks.
    completion_failures = run_completion_tests(root) if enforcing else []

    # Layer 3. Computed on every Stop (it is an observation, not an enforcement),
    # but never consulted for blocking unless AGENT_VERIFY_OBSERVER_BLOCK=1.
    verify_text, verify_files_n = unverified_note(root, session_id)

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

    # Layers 1+2 clean -> pass, unless layer 3 has an advisory to surface.
    if total_issues == 0 and not completion_failures:
        if src_files:
            print(f"[quality gate] {len(src_files)} file(s) checked, 0 violations.",
                  file=sys.stderr)
        if verify_text and not (enforcing and verify_block):
            print(verify_text, file=sys.stderr)
            record_verify_firing(root, session_id, verify_files_n, "advisory")
            # Two channels on purpose: `systemMessage` is the field this runtime
            # is known to surface for Stop, and `additionalContext` is what the
            # agent reads when supported. Emitting only the latter risks a
            # silently inert advisory — the failure mode where a shipped feature
            # never actually reaches anyone.
            print(json.dumps({
                "systemMessage": verify_text,
                "hookSpecificOutput": {
                    "hookEventName": "Stop",
                    "additionalContext": verify_text,
                },
            }))
            sys.exit(0)
        if not verify_text:
            print(json.dumps({}))
            sys.exit(0)

    parts: list[str] = []
    if verify_text:
        parts.append(verify_text)
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

    # Block decision: completion-test failures always block (objective,
    # consumer-declared); style findings block only under the opt-in
    # AGENT_QUALITY_STYLE_BLOCK=1 — by default they were reported+logged above
    # and the session may end. Second Stop passes (user decided "intentional").
    # Advisory mode (BLOCK=0) never blocks.
    should_block = (
        bool(completion_failures)
        or (style_block and total_issues > 0)
        or (verify_block and bool(verify_text))
    )
    if enforcing and verify_text and not (verify_block and should_block):
        # Layer 3 rode along with someone else's block (or with a non-blocking
        # style report): still record it as an advisory firing so the registry
        # fire-rate counts it exactly once.
        record_verify_firing(root, session_id, verify_files_n, "advisory")
    elif enforcing and verify_block and verify_text:
        record_verify_firing(root, session_id, verify_files_n, "blocked")
    if enforcing and should_block:
        # Teaching format (T-1): WHY + FIX so the agent can self-correct. The
        # remedy list names only the layer(s) that actually triggered the block
        # — post-split, pointing at non-blocking style fixes when only a
        # completion test failed would send the agent chasing the wrong work.
        remedies = []
        causes = []
        if completion_failures:
            remedies.append("fix the failing completion test(s)")
            causes.append("failing completion tests")
        if style_block and total_issues:
            remedies.append("move types to types.ts / tokenize colors / remove console.log")
            causes.append("blocking style violations")
        if verify_block and verify_text:
            remedies.append("run one relevant verification command")
            causes.append("code changes with no verification observed")
        reason = (
            f"{summary}\n\n"
            "Response halted by quality gate.\n"
            "WHY: completion gate — the session diff still carries "
            + " and ".join(causes)
            + "; ending now would ship them silently.\n"
            "FIX: choose one:\n"
            "  (a) Resolve — " + " and ".join(remedies) + ", then complete.\n"
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
