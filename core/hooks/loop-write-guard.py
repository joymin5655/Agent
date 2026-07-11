#!/usr/bin/env python3
"""loop-write-guard.py — L-2: protect the grader/verifier surface during a loop.

While the autonomous improvement loop (§5) is active, the improvement agent is
supposed to edit ONLY its declared TARGET (e.g. the reviewer prompts). If it can
freely rewrite the grader (`core/tests/`), the eval rubric/datasets (`evals/`), or
the results ledger, it can game its own score: overwrite a test, weaken a check,
or rewrite history in the ledger. This hook escalates those writes to `ask`
(NOT deny — per the calibration policy §3a, only secrets escalate to deny; the
grader surface escalates to a human decision) so a human stays on the loop.

Scope: this guard is INERT unless a loop session is active. A session is active
iff `AGENT_LOOP_ACTIVE=1` OR the flag file exists (the loop SKILL creates it on
start, removes it on end). Outside a loop, every write passes untouched — this
adds zero friction to normal work.

Active-session decisions (Write|Edit|MultiEdit):
  * a write under `evals/` or `core/tests/`  -> ask (grader/verifier tamper)
  * a NON-APPEND write to the results ledger  -> ask (ledger is append-only)
  * anything else                             -> allow

Containment is enforced with realpath (not lexical prefix): a symlink placed
under the guarded dir whose target is elsewhere — or one pointing INTO the
guarded dir from outside — is resolved before the check, so the boundary cannot
be dodged with a symlink (the campaign's lexical-containment lesson).

Test seams:
  AGENT_LOOP_ACTIVE=1       force the session active (no flag file needed)
  AGENT_LOOP_FLAG=<path>    override the flag-file path
  AGENT_LOOP_LEDGER=<path>  override the results-ledger path
  AGENT_PROJECT_DIR=<path>  project root (else CLAUDE_PROJECT_DIR, git, cwd)
"""
import json
import os
import subprocess
import sys


def _project_root() -> str:
    for var in ("AGENT_PROJECT_DIR", "CLAUDE_PROJECT_DIR"):
        v = os.environ.get(var)
        if v:
            return v
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return os.getcwd()


def _loop_active(root: str) -> bool:
    if os.environ.get("AGENT_LOOP_ACTIVE") == "1":
        return True
    flag = os.environ.get("AGENT_LOOP_FLAG", os.path.join(root, ".agent", "loop", "active"))
    return os.path.exists(flag)


def _real(path: str) -> str:
    """realpath that also resolves a non-existent leaf via its parent, so a write
    to a not-yet-created file under a symlinked dir is still contained correctly."""
    path = os.path.abspath(path)
    if os.path.exists(path):
        return os.path.realpath(path)
    parent = os.path.realpath(os.path.dirname(path))
    return os.path.join(parent, os.path.basename(path))


def _within(target_real: str, dir_real: str) -> bool:
    return target_real == dir_real or target_real.startswith(dir_real + os.sep)


def emit_ask(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))


def _is_pure_append(ledger_real: str, tool_name: str, tool_input: dict) -> bool:
    """True iff this write only ADDS to the end of the ledger.

    Edit/MultiEdit mutate existing bytes -> never a pure append. A Write is an
    append iff the new content is byte-for-byte the old content plus a suffix
    (and a brand-new file is fine). Fail closed: if we cannot read the old file
    to prove append, treat it as NOT an append (escalate to ask)."""
    if tool_name in ("Edit", "MultiEdit"):
        return False
    if not os.path.exists(ledger_real):
        return True  # creating the ledger for the first time
    new_content = tool_input.get("content")
    if new_content is None:
        return False
    try:
        with open(ledger_real, "r", encoding="utf-8", errors="surrogateescape") as fh:
            old = fh.read()
    except Exception:
        return False
    return new_content.startswith(old)


def main() -> None:
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit(0)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = data.get("tool_name", "")
    if tool_name not in ("Write", "Edit", "MultiEdit"):
        sys.exit(0)

    tool_input = data.get("tool_input", {}) or {}
    file_path = tool_input.get("file_path", "")
    if not file_path:
        sys.exit(0)

    root = _project_root()
    if not _loop_active(root):
        sys.exit(0)  # inert outside a loop session

    target = _real(file_path)
    ledger = _real(os.environ.get("AGENT_LOOP_LEDGER", os.path.join(root, ".agent", "loop", "results.tsv")))

    # 1) ledger: allow pure appends, escalate any rewrite/edit.
    if target == ledger:
        if _is_pure_append(ledger, tool_name, tool_input):
            sys.exit(0)
        emit_ask(
            "Loop ledger is append-only: this write is not a pure append.\n"
            "WHY: L-2 — the results ledger is the loop's tamper-evident record; "
            "rewriting or editing past rows lets a run launder its own history.\n"
            "FIX: only append new rows (Write the old content plus your new line, "
            "or use core/infra/loop-ledger.sh append). A human must approve any rewrite."
        )
        sys.exit(0)

    # 2) grader / eval surface: escalate any write under core/tests or evals.
    guarded = [_real(os.path.join(root, "core", "tests")), _real(os.path.join(root, "evals"))]
    for g in guarded:
        if _within(target, g):
            emit_ask(
                "Editing the grader/verifier surface during an active loop session.\n"
                "WHY: L-2 — the improvement agent must not edit the code that scores it "
                "(core/tests/, evals/); self-grading edits are how a loop games its metric.\n"
                "FIX: restrict this run to its declared TARGET files. If the grader itself "
                "must change, do it OUTSIDE the loop as a human-reviewed change."
            )
            sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
