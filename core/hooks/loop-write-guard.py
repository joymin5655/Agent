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
    (this hook, pre-tool-guard.sh, the adapter, hooks.json, and the sanctioned
    ledger writer core/infra/loop-ledger.sh) so the guard cannot be silently
    neutered.
  Write|Edit|MultiEdit non-append to the ledger -> ask
    (recreating a deleted ledger whose .witness survives, or hand-writing the
    .witness itself, is NOT an append — delete-recreate High, see loop-ledger.sh)
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
        # the sanctioned ledger writer IS enforcement surface: rewriting it turns
        # every future "sanctioned" append into a forgery channel (sec C9).
        _real(os.path.join(root, "core", "infra", "loop-ledger.sh")),
        # the gitleaks config IS the secret-scan floor grade.sh runs; a weakened
        # allowlist neuters the GATE (round-4 review HIGH).
        _real(os.path.join(root, "gitleaks.toml")),
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
ASK_CONTROL = (
    "Editing the loop's own control state (.agent/loop/active or "
    ".agent/loop/state/) during an active loop session.\n"
    "WHY: this guard is INERT unless .agent/loop/active exists, so deleting that "
    "marker turns the guard off entirely — the controlled party must not hold the "
    "off switch. The state files are the same hazard one step in: they carry the "
    "status and the consecutive-failure count, so editing them resurrects a loop "
    "the circuit breaker already stopped.\n"
    "FIX: let core/infra/loop-run.sh own these files. Stopping or resuming a loop "
    "is a human decision made outside it (loop-run.sh stop / init)."
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
        # First creation is an append ONLY if no witness survives: a witness with
        # no ledger means the ledger was deleted — recreating it would launder the
        # history as a fresh file (the delete-recreate High). Escalate instead.
        return not os.path.exists(ledger_real + ".witness")
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
# KNOWN LIMIT (sec C7): token matching is a contiguous-substring check, so a path
# split across a `cd` (`cd core && sed -i '' tests/x.sh`) evades it; full shell
# path resolution is out of scope for a best-effort hook — grade.sh's INTEGRITY
# phase is the primary containment for anything that lands on disk.
_WRITE_OPS = re.compile(
    r"(>>?|\btee\b|\bg?sed\b[^|;&]*\s-\w*i|\bg?awk\b[^|;&]*\s-\w*i|\bcp\b|\bmv\b|"
    r"\bdd\b|\binstall\b|\brm\b|\btruncate\b|\brsync\b|\btar\b|\bditto\b|\bpatch\b|"
    r"\bunzip\b|\bcurl\b[^|;&]*\s-\w*[oO]|\bwget\b|\bed\b|\bex\b|"
    r"\bgit\s+(checkout|restore|apply|rm|mv|stash\s+pop|update-index)\b|"
    # the python branch tolerates `;` (a -c one-liner uses it INSIDE the quoted
    # program, e.g. `import pathlib; ...write_text(...)`) — over-matching across a
    # real shell `;` only costs a spurious ask, never a miss.
    r"\bpython[0-9.]*\b[^|&]*(open\s*\([^)]*['\"][wa]|write_text|write_bytes|"
    r"shutil\.\w+|os\.(replace|rename|remove|unlink))|"
    r"\bperl\b[^|;&]*>|\b\w*chmod\b|\bln\b|"
    # sqlite3 with a mutating statement: the supervisor goal DB under
    # .agent/locks/ is a plain file, so `sqlite3 <db> "UPDATE ..."` rewrote the
    # loop's authoritative status without touching any verb above (round-2 review
    # CRITICAL — it was the second half of an end-to-end breaker resurrection).
    # Case-insensitive only for the SQL keywords; `sqlite3` itself is lowercase.
    r"\bsqlite3\b[^|;&]*(?i:\b(update|insert|delete|drop|alter|replace|attach|vacuum)\b))"
)


# The Bash write path's copy of the guarded surface. Relative tokens are enough:
# the command text references paths as written. "evals" carries no trailing slash
# so `cd evals && rm ...` still hits (C7); the .witness token is technically
# covered by the ledger substring but is named explicitly so the guarantee
# survives a ledger rename (C9). The two ledger entries are Bash-path-only
# extras — the Write/Edit path reaches the ledger through its own append-only
# check, not through this list.
#
# MODULE-LEVEL so grade-test.sh's (g4) drift gate can call it live: this is the
# FIFTH hand-maintained copy of the enforcement surface (alongside grade.sh's
# surface_list and guarded_surface_re and this module's _guarded_dirs/
# _guarded_files), and it is the ONLY one gating Bash writes. Left out of that
# gate, a file could be added to the other four and still be rewritable by a
# loop agent via `sed -i`/redirect with no ask.
GUARDED_TOKENS = ("core/tests", "evals", "core/hooks/loop-write-guard.py",
                  "core/hooks/pre-tool-guard.sh", "adapters/claude-code/adapter.sh",
                  "hooks/hooks.json", "core/infra/loop-ledger.sh", "gitleaks.toml",
                  ".agent/loop/results.tsv", ".agent/loop/results.tsv.witness")

# The loop's own control state, kept SEPARATE from GUARDED_TOKENS so a Bash hit
# can carry the reason that actually explains it. NOT part of the scoring surface
# the five definitions must agree on — it is untracked runtime state, like the
# ledger entries above. Guarded because this hook is INERT without
# .agent/loop/active, so `rm` on that marker is a one-command self-disable, and
# .agent/loop/state/ holds the status + failure count that revive a stopped loop.
#
# Matched at DIRECTORY granularity, not on the full file paths. `cd .agent/loop
# && rm active` contains neither ".agent/loop/active" nor ".agent/loop/state",
# so path-level tokens missed it and the marker went away with no ask (round-2
# review CRITICAL, reproduced end-to-end). ".agent/locks" is here for the same
# reason: the SQLite goal DB lives there and was not guarded at all, so an
# `sqlite3 ... UPDATE` on it rewrote the very status cmd_attempt now cross-checks.
#
# Directory granularity alone was still not enough: the split can be taken one
# level higher. `cd .agent && rm loop/active` and `cd .agent && cd loop && rm
# active` contain neither ".agent/loop" nor ".agent/locks". So the token set
# bottoms out at ".agent" — the runtime root — which is the shallowest path any
# cd-chain to this state must still name SOMEWHERE in the command.
#
# Cost of that breadth: a write command mentioning an unrelated ".agent" (say
# `> src/user.agent.ts`) draws a spurious ask. That is the right trade here —
# it is an ask, not a deny, and it only applies while a loop is running.
#
# RESIDUALS. The TOKEN set is now complete for cd-chains, but the Bash axis has
# two other sides and BOTH remain open — do not read the above as "single-command
# removal of the marker is closed", because it is not (round-2 final review
# enumerated these, each confirmed to get no ask AND actually remove the file):
#
#   VERB LIST. _WRITE_OPS decides what counts as a write, and it misses plenty:
#   `find .agent -name active -delete` (only -exec rm is matched), `unlink`,
#   `shred -u`, `git clean -fdx .agent` (ideal here — .agent is untracked),
#   `perl -e 'unlink ...'` (the perl branch demands a literal `>`),
#   `pathlib.Path(...).unlink()` (os.remove is matched, this is not), and
#   node/ruby/php, which are absent entirely.
#
#   LITERAL SUBSTRING MATCHING. A glob or a split literal defeats the token:
#   `rm .age*/loop/active`, `rm .a*/loop/active`, `rm -rf .ag?nt/loop`,
#   `rm ".age""nt/loop/active"`, `rm .$'a'gent/loop/active`.
#
#   CROSS-CALL STATE. `cd .agent/loop` in one tool call then a bare `rm active`
#   in the NEXT names no guarded path at all.
#
# Those three are NOT the same kind of gap, and conflating them would flatter the
# guard. The first two are "this matcher does not see it" — reachable inside a
# SINGLE command, and closable here (a longer verb list; matching the shell's
# post-expansion view rather than the literal text). The third is "no matcher
# CAN see it": the command carries no guarded path, so only a cwd-aware or
# filesystem-level control would catch it.
#
# All of the above are open on main identically — none is introduced here — but
# they matter more for .agent/ than for core/tests/: those have grade.sh's
# git-diff INTEGRITY phase as a downstream backstop, while .agent/ is untracked,
# so a missed Bash write to loop state is caught by nothing later.
#
# The Write/Edit axis is unaffected by all three — it resolves real paths, and
# was verified against `..` traversal and symlinks into .agent/loop/.
CONTROL_TOKENS = (".agent",)


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
        # control-state tokens first: `rm .agent/loop/active` deserves the reason
        # that explains it disarms the guard, not the generic grader-surface text.
        if _bash_hits_guarded(command, CONTROL_TOKENS):
            return ("control", ASK_CONTROL)
        if _bash_hits_guarded(command, GUARDED_TOKENS):
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

    if target == ledger + ".witness":
        # only the sanctioned writer (loop-ledger.sh) may touch the witness — a
        # hand-written witness would notarize a tampered ledger.
        return ("ledger", ASK_LEDGER)

    # loop control state, handled like the ledger above (its own branch, not part
    # of the scoring-surface sets the drift gate holds equal): the marker that
    # arms this hook and the state files that hold status / failure counts.
    if target == _real(os.path.join(root, ".agent", "loop", "active")):
        return ("control", ASK_CONTROL)
    if _within(target, _real(os.path.join(root, ".agent", "loop", "state"))):
        return ("control", ASK_CONTROL)

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
