#!/usr/bin/env python3
"""loop-write-guard.py — L-2: protect the grader/verifier surface during a loop.

While the autonomous improvement loop (§5) is active, the improvement agent is
supposed to edit ONLY its declared TARGET (e.g. the reviewer prompts). If it can
freely rewrite the grader (`core/tests/`), the eval rubric/datasets (`evals/`), the
guards' own enforcement code, or the results ledger, it can game its own score. This
hook escalates such changes to `ask` (NOT deny — the calibration policy §3a reserves
deny for secrets; the grader surface escalates to a human decision) so a human stays
on the loop.

DEFENSE-IN-DEPTH, not the sole gate. A hook cannot fully contain a shell-capable
agent (a shell has unbounded ways to mutate a file), and an auto-approved loop turns
`ask` into `allow`. The PRIMARY containment is `grade.sh`: it refuses to grade a
dirty working tree and discards any candidate whose committed diff touches an
off-target file (§5.1 pillar ③). This hook raises the cost of the common tamper
paths and keeps a human in the loop; it does not claim to be exhaustive.

Scope: INERT unless a loop session is active — `AGENT_LOOP_ACTIVE=1` OR the flag file
exists (the loop SKILL creates it on start, removes it on end). Outside a loop every
action passes untouched.

Active-session decisions:
  Write|Edit|MultiEdit to a guarded path        -> ask
    guarded = core/tests/, evals/, and the enforcement files themselves
    (this hook, pre-tool-guard.sh, the adapter, hooks.json) so the guard cannot be
    silently neutered.
  Write|Edit|MultiEdit non-append to the ledger -> ask
  Bash command that WRITES into a guarded path  -> ask   (best-effort: redirection,
    tee, sed -i, cp/mv/dd/install, rm/truncate, git checkout/restore/apply, or a
    python/perl one-liner opening a guarded path for write)
  anything else                                 -> allow

Fail closed: any unexpected error while a loop is active emits `ask` rather than
crashing silently (a crashing PreToolUse hook is treated as no-decision = allow).

Containment uses realpath (not lexical prefix): a symlink into a guarded dir is
resolved before the check, so the boundary cannot be dodged with a symlink.

Test seams:
  AGENT_LOOP_ACTIVE=1       force the session active (no flag file needed)
  AGENT_LOOP_FLAG=<path>    override the flag-file path
  AGENT_LOOP_LEDGER=<path>  override the results-ledger path
  AGENT_PROJECT_DIR=<path>  project root (else CLAUDE_PROJECT_DIR, git, cwd)
"""
import json
import os
import re
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
    """realpath that also resolves a non-existent leaf via its parent, so a write to
    a not-yet-created file under a symlinked dir is still contained correctly."""
    path = os.path.abspath(path)
    if os.path.exists(path):
        return os.path.realpath(path)
    parent = os.path.realpath(os.path.dirname(path))
    return os.path.join(parent, os.path.basename(path))


def _within(target_real: str, dir_real: str) -> bool:
    return target_real == dir_real or target_real.startswith(dir_real + os.sep)


def _guarded_dirs(root: str):
    return [_real(os.path.join(root, "core", "tests")), _real(os.path.join(root, "evals"))]


def _guarded_files(root: str):
    # the enforcement surface itself — a guard that can be silently rewritten is no
    # guard. Kept explicit (not all of core/hooks) so a legitimate per-hook mission
    # can still edit an unrelated hook.
    return {
        _real(os.path.join(root, "core", "hooks", "loop-write-guard.py")),
        _real(os.path.join(root, "core", "hooks", "pre-tool-guard.sh")),
        _real(os.path.join(root, "adapters", "claude-code", "adapter.sh")),
        _real(os.path.join(root, "hooks", "hooks.json")),
    }


def _ledger_path(root: str) -> str:
    return _real(os.environ.get("AGENT_LOOP_LEDGER", os.path.join(root, ".agent", "loop", "results.tsv")))


def emit_ask(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False))


ASK_SURFACE = (
    "Editing the grader/verifier surface during an active loop session.\n"
    "WHY: L-2 — the improvement agent must not edit the code that scores it "
    "(core/tests/, evals/, the guards themselves); self-grading edits are how a loop "
    "games its metric.\n"
    "FIX: restrict this run to its declared TARGET files. If the grader itself must "
    "change, do it OUTSIDE the loop as a human-reviewed change."
)
ASK_LEDGER = (
    "Loop ledger is append-only: this write is not a pure append.\n"
    "WHY: L-2 — the results ledger is the loop's tamper-evident record; rewriting or "
    "editing past rows lets a run launder its own history.\n"
    "FIX: only append new rows (or use core/infra/loop-ledger.sh append). A human "
    "must approve any rewrite."
)
ASK_BASH = (
    "Bash command writes into the grader/verifier surface during an active loop.\n"
    "WHY: L-2 — a shell write (redirect, sed -i, cp/mv, rm, git checkout/apply, a "
    "python one-liner) to core/tests/, evals/, the guards, or the ledger is a "
    "self-grading tamper path.\n"
    "FIX: keep loop edits inside the declared TARGET via Write/Edit; change the "
    "grader outside the loop under human review."
)


def _is_pure_append(ledger_real: str, tool_name: str, tool_input: dict) -> bool:
    """True iff this write only ADDS to the end of the ledger. Fail closed: anything
    we cannot PROVE is an append is treated as NOT an append (escalate to ask)."""
    if tool_name in ("Edit", "MultiEdit"):
        return False
    if not os.path.exists(ledger_real):
        return True  # creating the ledger for the first time
    new_content = tool_input.get("content")
    if not isinstance(new_content, str):
        return False  # missing / non-string content -> cannot prove append
    try:
        with open(ledger_real, "r", encoding="utf-8", errors="surrogateescape") as fh:
            old = fh.read()
    except Exception:
        return False
    return new_content.startswith(old)


# Bash write-into-guarded-path detector (best-effort). We flag a command that both
# NAMES a guarded path and carries a write-ish operation. Conservative on the verb
# side (a read like `cat core/tests/x` has no write verb -> allow).
_WRITE_OPS = re.compile(
    r"(>>?|\btee\b|\bsed\b[^|;&]*\s-\w*i|\bcp\b|\bmv\b|\bdd\b|\binstall\b|\brm\b|"
    r"\btruncate\b|\bgit\s+(checkout|restore|apply|rm)\b|"
    r"\bpython[0-9.]*\b[^|;&]*open\s*\([^)]*['\"][wa]|"
    r"\bperl\b[^|;&]*>|\b\w*chmod\b|\bln\b)"
)


def _bash_hits_guarded(command: str, guarded_tokens) -> bool:
    if not any(tok in command for tok in guarded_tokens):
        return False
    return bool(_WRITE_OPS.search(command))


def _decide(data: dict, root: str):
    """Return an emit_* callable's reason string tagged by kind, or None to allow."""
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {}) or {}

    if tool_name == "Bash":
        command = tool_input.get("command", "")
        if not isinstance(command, str) or not command:
            return None
        # relative tokens are enough: the command text references paths as written.
        guarded_tokens = ("core/tests", "evals/", "core/hooks/loop-write-guard.py",
                          "core/hooks/pre-tool-guard.sh", "adapters/claude-code/adapter.sh",
                          "hooks/hooks.json", ".agent/loop/results.tsv")
        if _bash_hits_guarded(command, guarded_tokens):
            return ("bash", ASK_BASH)
        return None

    if tool_name not in ("Write", "Edit", "MultiEdit"):
        return None

    file_path = tool_input.get("file_path", "")
    if not isinstance(file_path, str) or not file_path:
        return None

    target = _real(file_path)
    ledger = _ledger_path(root)

    if target == ledger:
        if _is_pure_append(ledger, tool_name, tool_input):
            return None
        return ("ledger", ASK_LEDGER)

    if target in _guarded_files(root):
        return ("surface", ASK_SURFACE)
    for g in _guarded_dirs(root):
        if _within(target, g):
            return ("surface", ASK_SURFACE)

    return None


def main() -> None:
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit(0)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    root = _project_root()
    if not _loop_active(root):
        sys.exit(0)  # inert outside a loop session

    # Fail closed: while a loop is active, an unexpected error must escalate to ask
    # rather than crash (a crashing PreToolUse hook is treated as allow).
    try:
        decision = _decide(data, root)
    except Exception as exc:
        emit_ask(
            "loop-write-guard could not evaluate this action safely.\n"
            "WHY: L-2 — during an active loop, an unevaluable write fails closed to a "
            f"human decision rather than silently proceeding ({type(exc).__name__}).\n"
            "FIX: retry with a simpler write, or pause the loop and inspect."
        )
        sys.exit(0)

    if decision is not None:
        emit_ask(decision[1])
    sys.exit(0)


if __name__ == "__main__":
    main()
