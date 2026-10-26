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
    tee, sed -i, cp/mv/dd/install, rm/unlink/shred/rmdir/truncate, find -delete,
    git checkout/restore/apply/clean, or a python/perl/ruby/node/deno/bun/php
    one-liner writing or deleting a guarded path). The path may be spelled through
    quotes, escapes, `$'..'`, a glob, a brace list or dot segments — see
    _bash_hits_guarded.
  anything else                                 -> allow

Fail closed: any unexpected error while a loop is active emits `ask` rather than
crashing silently (a crashing PreToolUse hook is treated as no-decision = allow). So
does running out of time: the harness kills a hook at its timeout and a killed hook
decides nothing, so the hook keeps its own shorter deadline and asks when it hits it.

Containment uses realpath (not lexical prefix): a symlink into a guarded dir is
resolved before the check, so the boundary cannot be dodged with a symlink.

Test seams:
  AGENT_LOOP_ACTIVE=1       force the session active (no flag file needed)
  AGENT_LOOP_FLAG=<path>    override the flag-file path
  AGENT_LOOP_LEDGER=<path>  override the results-ledger path
  AGENT_PROJECT_DIR=<path>  project root (else CLAUDE_PROJECT_DIR, git, cwd)
  AGENT_LOOP_GUARD_TIMEOUT=<seconds>  the hook's own deadline (default 20)
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import signal
import subprocess
import sys
from collections.abc import Iterator


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
    "WHY: L-2 — a shell write (redirect, sed -i, cp/mv, rm/unlink/find -delete, "
    "git checkout/apply/clean, a python/node/perl one-liner) to core/tests/, evals/, "
    "the guards, or the ledger is a self-grading tamper path.\n"
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
# KNOWN LIMIT (sec C7): a path split across a `cd` (`cd core && sed -i '' tests/x.sh`)
# evades the token match; full shell path resolution is out of scope for a
# best-effort hook — grade.sh's INTEGRITY phase is the primary containment for
# anything that lands on disk. (One path spelled through quotes, a glob or a brace
# list IS handled — see _bash_hits_guarded.)
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
    r"\bsqlite3\b[^|;&]*(?i:\b(update|insert|delete|drop|alter|replace|attach|vacuum)\b)|"
    # Removal verbs the first version lacked (the "VERB LIST" residual below) — `rm`
    # was the only deleter in the table. Everything from here on only ADDS asks; the
    # alternatives above are untouched. Verbs that mean something only next to a
    # second word (find -delete, an interpreter calling unlink) are _scoped_write_verb.
    #  - unlink/rmdir carry no trailing \b so Node's unlinkSync/rmdirSync match too;
    #    the bare word also covers perl's unlink() and pathlib's .unlink(). The price is
    #    that a search for the word (`grep -rn unlink core/tests`) asks as well: a spurious
    #    ask is cheap, a missed deletion is not.
    #  - Homebrew coreutils install the GNU tools under a `g` prefix (grm, gmv, gcp,
    #    gunlink, ...), which `\brm\b` and friends never match. Only where a command
    #    starts (after a separator, a quote, a shell keyword, xargs/sudo/env with their
    #    options and assignments, find -exec) and followed by a space or the end:
    #    `grep -E 'aws|gcp' ...` is a search, not a copy.
    #  - One wrapper name below is spelled as a class (`no[h]up`): supply-chain-scan reads
    #    core/hooks/__pycache__ as well, and compiled bytecode cannot carry the scan's per-line
    #    allow marker, so the bare name would fail the scan whenever a test imports this file.
    r"\bunlink|\bshred\b|\brmdir|"
    r"(?:^|[;&|(`\n'\"{!]|"
    r"\b(?:xargs|sudo|env|command|exec|no[h]up|time|nice|do|then|else|elif|if|while|until)\b"
    r"(?:\s+(?:-\S+|\w+=\S*))*|-exec(?:dir)?|-ok(?:dir)?)\s*"
    r"g(?:cp|mv|rm|dd|install|truncate|ln|tee|tar|patch|shred|unlink|rmdir)(?=\s|$))"
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
# RESIDUALS. The TOKEN set is complete for cd-chains. The Bash axis has two other
# sides (the round-2 final review enumerated them, each confirmed to get no ask AND
# actually remove the file). The cases that review named are closed below; each
# side still lets some through, and this says which.
#
#   VERB LIST. Closed for the named cases: `find .agent -name active -delete`,
#   `unlink`, `shred -u`, `git clean -fdx .agent`, `perl -e 'unlink ...'`,
#   `pathlib.Path(...).unlink()` and perl/node/deno/bun/ruby/php code that calls a
#   writer (`fs.rmSync(`, `File.delete "x"`, `file_put_contents(`, `rmtree(`) all
#   ask now, as do the `g`-prefixed GNU tools (`grm`, `gmv`) and git behind its own
#   global options (`git -C . clean`). So does an open() whose quoted mode writes, in
#   Node's (`wx`, `ax+`), PHP's (`xb`, `wbe`) and Ruby's (`w:UTF-8`) spellings, also
#   behind a nested call (`openSync(path.join(a, b), 'w')`, up to three deep), and any
#   PHP `fopen` that shows no read-only mode (`fopen($p, $m)`). Still open: verbs the
#   table does not hold (touch, mkdir, gzip, chown, yq -i, sponge, rename(1), `vim
#   -es`); library writers it does not name (`df.to_csv`, `plt.savefig`, `np.save`,
#   `Path.touch`, `Deno.create`, `zipfile.extractall`); a mode that is not a quoted
#   literal, except for PHP's `fopen` (`File.open(p, m)`, `fs.openSync(p, flags)`,
#   `os.open(.., O_WRONLY)`, `Deno.open(p, {write: true})`); a `g`-prefixed GNU tool
#   behind a wrapper option that takes its own argument (`nice -n 5 grm`, `sudo -u
#   root grm`); a command that names no path (`git clean -fdx` deletes untracked
#   `.agent/` without saying so); and any program that works out its target at run
#   time (`python3 cleanup.py`, `make clean`).
#
#   LITERAL SUBSTRING MATCHING. Closed for what the shell itself does to a word
#   before it runs: quotes and escapes (`".age""nt"`, `.$'a'gent`, `$'\x2eagent'`),
#   globs (`.age*`, `.ag?nt`, `core/te*`), brace lists (`.ag{e,}nt`) and dot
#   segments (`core/./tests`) are rebuilt and matched segment by segment from the
#   project root, also behind a `key=value` (`dd of=core/./tests/x`). Still open: a
#   path the command only COMPUTES (`a=.age; b=nt; rm $a$b/loop/active`, `$(...)`,
#   eval, base64); a path split by a `cd` inside one command (`cd core && rm -rf
#   tests`); a case-folded spelling on a case-insensitive filesystem (`rm -rf
#   CORE/Tests`); a spelling that first climbs out of the root
#   (`../<root>/core/te*`); an option glued to its value (`-ocore/./tests/x`);
#   POSIX classes and extglob (`.[[:lower:]]gent`); and a wildcard with no literal
#   character in it (`rm -rf *`, `rm -rf .??*`) or only one or two (`rm -rf *va*`,
#   which cannot be told from markdown emphasis), since those match nearly anything.
#
#   CROSS-CALL STATE. Unchanged. `cd .agent/loop` in one tool call then a bare
#   `rm active` in the NEXT names no guarded path at all.
#
# Those are NOT the same kind of gap, and conflating them would flatter the guard.
# The first two are "this matcher does not see it" — reachable inside a SINGLE
# command, and closable here (a longer verb list; matching the shell's
# post-expansion view rather than the literal text), which is what was done, as far
# as a check on the command text alone can go. The third is "no matcher CAN see
# it": the command carries no guarded path, so only a cwd-aware or filesystem-level
# control would catch it. What is still open is open on main identically — none of
# it is introduced here — and it matters more for .agent/ than for core/tests/:
# those have grade.sh's git-diff INTEGRITY phase as a downstream backstop, while
# .agent/ is untracked, so a missed Bash write to loop state is caught by nothing
# later.
#
# What the widening costs is noise, not a gap: the old table was quiet where the new
# one asks on a search for a verb's name (`grep -rn unlink core/tests` — the bare word
# is how perl, pathlib and node delete) and on a command with a write verb that
# carries one word too long or too branchy to enumerate (a JSON argument past 4 KB).
# A spurious ask costs a click; a missed deletion costs the grader.
#
# The Write/Edit axis is unaffected by all of this — it resolves real paths, and
# was verified against `..` traversal and symlinks into .agent/loop/.
CONTROL_TOKENS = (".agent",)


# --- the shell's post-expansion view of a Bash command (text only) ----------------
# The token check is a literal substring match, so anything the shell rewrites
# before running defeats it: `".age""nt"`, `.$'a'gent`, `.a\gent`, `.age*`,
# `.ag{e,}nt`, `core/./tests`. The helpers below rebuild that view from the command
# TEXT alone — no filesystem access, no evaluation. _bash_hits_guarded consults it
# IN ADDITION to the raw text, so every spelling the raw match already caught is
# still caught: this can only add asks.

_ANSI_C_SIMPLE = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
                  "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
_HEX_ESCAPE = {"x": re.compile(r"[0-9A-Fa-f]{1,2}"), "u": re.compile(r"[0-9A-Fa-f]{1,4}"),
               "U": re.compile(r"[0-9A-Fa-f]{1,8}")}
_OCT_ESCAPE = re.compile(r"[0-7]{1,3}")


def _ansi_c_escape(s: str, i: int) -> tuple:
    """Decode the `$'...'` escape whose backslash is s[i] -> (text, index after it)."""
    c = s[i + 1] if i + 1 < len(s) else ""
    if c in _HEX_ESCAPE:
        m = _HEX_ESCAPE[c].match(s, i + 2)
        if m:
            try:
                return chr(int(m.group(), 16)), m.end()
            except (ValueError, OverflowError):
                return "", m.end()
    elif c and c in "01234567":
        m = _OCT_ESCAPE.match(s, i + 1)
        return chr(int(m.group(), 8) & 0xFF), m.end()
    elif c in _ANSI_C_SIMPLE:
        return _ANSI_C_SIMPLE[c], i + 2
    return (c, i + 2) if c else ("\\", i + 1)


def _dequote(s: str) -> str:
    """The command with shell quoting and escaping removed: `".age""nt"` and
    `.$'a'gent` and `.a\\gent` all read `.agent`, `$'\\x2eagent'` decodes to
    `.agent`. Quote characters are simply dropped, so a quoted glob character still
    counts as a glob — an over-match that costs a spurious ask, never a miss (a
    quote-aware parse would let a stray apostrophe in a heredoc body hide a real
    glob that follows it)."""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "$" and s.startswith("'", i + 1):          # $'...' ANSI-C quoting
            i += 2
            while i < n and s[i] != "'":
                if s[i] == "\\":
                    text, i = _ansi_c_escape(s, i)
                    out.append(text)
                else:
                    out.append(s[i])
                    i += 1
            i += 1
        elif (c == "$" and s.startswith('"', i + 1)) or c in "'\"":   # `$"..."` is plain "..."
            i += 1
        elif c == "\\" and i + 1 < n:
            if s[i + 1] != "\n":                           # backslash-newline joins lines
                out.append(s[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


# Brace expansion is enumerated, so it is capped: results per word, and the length of a
# word that carries a brace.
_BRACE_RESULTS_MAX = 4096
_BRACE_WORD_MAX = 4096


def _brace_expand(word: str, limit: int = _BRACE_RESULTS_MAX) -> list | None:
    """Bash brace expansion of one word: `.ag{e,}nt` -> [`.agent`, `.agnt`]. A list of
    alternatives expands exactly; a `{a..z}` range becomes a `*` wildcard; a group
    that is neither (`${var}`, `{}`) is left alone. A word too long or too branchy to
    enumerate (`{,}{,}{,}...`) comes back as None, "cannot be evaluated" — never as
    the word written, which would let padding the braces hide the path."""
    start = word.find("{")
    if start < 0:
        return [word]
    if len(word) > _BRACE_WORD_MAX:
        return None
    depth, cuts, end = 0, [], -1
    for i in range(start, len(word)):
        c = word[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
        elif c == "," and depth == 1:
            cuts.append(i)
    if end < 0:
        return [word]
    head, body, tail = word[:start], word[start + 1:end], word[end + 1:]
    if cuts:
        edges = [start] + cuts + [end]
        alts = []
        for k in range(len(edges) - 1):
            sub = _brace_expand(word[edges[k] + 1:edges[k + 1]], limit)
            if sub is None:
                return None
            alts.extend(sub)
            if len(alts) > limit:
                return None            # stop before a wide list builds a huge product
    elif re.fullmatch(r"[^,{}]+\.\.[^,{}]+", body):
        alts = ["*"]
    else:
        alts = ["{" + body + "}"]
    tails = _brace_expand(tail, limit)
    if tails is None:
        return None
    if len(alts) * len(tails) > limit:
        return None
    return [head + a + t for a in alts for t in tails]


_GLOB_CHARS = re.compile(r"[*?\[]")
# a word worth resolving: it carries a glob, a brace or a dot/dot-dot/empty segment
_RESOLVABLE = re.compile(r"[*?\[{]|/\.\.?/|//")
# shell words: whitespace and operators separate them. Not `=`: the shell never globs
# the value of `--include=*.toml` or `of=core/te*/x`, so a glob there is not a path to
# resolve (_paths_in still reads a glob-free `key=value` value as the path it is).
_WORDS = re.compile(r"[^\s;|&()<>`]+")
_VAR_LEAD = re.compile(r"\$(?:\{[^}]*\}|\w+)")
# Token comparisons one command may cost. Typical commands spend a few dozen; a
# hostile one (thousands of globs, each with dozens of brace results) would stall the
# hook past its timeout, and a timed-out hook decides nothing — i.e. allows.
_PATH_WORK_BUDGET = 40000


def _path_segments(path: str) -> list:
    """Segments of a path with `.`, empty and literal `..` segments resolved."""
    segs = []
    for s in path.split("/"):
        if s in ("", "."):
            continue
        if s == ".." and segs and segs[-1] != ".." and not _GLOB_CHARS.search(segs[-1]):
            segs.pop()
        elif not (s == "**" and segs and segs[-1] == "**"):
            segs.append(s)
    return segs


def _seg_matches(pat: str, name: str, dot_ok: bool) -> bool:
    """One path segment of a word (`te*`, `.[a]gent`) against a literal guarded segment.
    Like the shell, a wildcard does not match a leading dot (`*agent*` is not
    `.agent`) unless dotglob is on — that is what keeps prose about "the agent" quiet."""
    if pat == name:
        return True
    if not _GLOB_CHARS.search(pat):
        return False
    if name.startswith(".") and not pat.startswith(".") and not dot_ok:
        return False
    pat = re.sub(r"\*+", "*", pat).replace("[^", "[!")   # fnmatch negates with `!`
    return len(pat) <= 256 and fnmatch.fnmatchcase(name, pat)


def _real_chars(pat: str) -> int:
    """Characters of a glob that say something: not `*`, `?`, `[...]` or a dot. One pass:
    a `[` with no `]` after it (the same for every later `[`) is just a character, so a
    long run of them is not re-scanned from each one."""
    n, i = 0, 0
    while i < len(pat):
        c = pat[i]
        if c == "[":
            j = pat.find("]", i + 1)
            if j >= 0:
                i = j + 1
                continue
            return n + sum(1 for ch in pat[i:] if ch not in "*?./")
        if c not in "*?./":
            n += 1
        i += 1
    return n


def _hits_token(segs: list, tok_segs: list, dot_ok: bool) -> bool:
    """True if the root-relative `segs` name the guarded `tok_segs` or anything under
    it. A `**` segment stands for any run of directories.

    A match must rest on at least one segment that identifies the path — the literal
    name itself, or a glob with real characters in it (`ev*`, `.age*`, `*.toml`).
    Wildcards alone (`*`, `*/node_modules/*`, `.*`) match every top-level name, so
    letting them count would ask on every `find -not -path '*/x/*'` and every regex
    that starts with `.*`."""
    if len(segs) > 64:
        return True                    # absurdly deep: fail closed rather than recurse
    dead = set()                       # states already known to lead nowhere

    def walk(i: int, j: int, said: bool) -> bool:
        if j == len(tok_segs):
            return said
        if i == len(segs) or (i, j, said) in dead:
            return False
        if segs[i] == "**":
            hit = walk(i + 1, j, said) or (
                (dot_ok or not tok_segs[j].startswith(".")) and walk(i, j + 1, said))
        elif _seg_matches(segs[i], tok_segs[j], dot_ok):
            hit = walk(i + 1, j + 1, said or segs[i] == tok_segs[j] or _real_chars(segs[i]) > 0)
        else:
            hit = False
        if not hit:
            dead.add((i, j, said))
        return hit

    return walk(0, 0, False)


def _root_forms(root: str) -> list:
    forms = []
    for r in (os.path.abspath(root), os.path.realpath(root)):
        segs = _path_segments(r)
        if segs not in forms:
            forms.append(segs)
    return forms


def _root_relative(word: str, root_forms: list) -> list | None:
    """The word as segments relative to the project root, or None when it points
    elsewhere. A leading `$VAR`/`${VAR}` is taken to be the root (the usual
    `$CLAUDE_PROJECT_DIR/...` spelling); an absolute path must sit under it."""
    if word.startswith("~"):
        word = os.path.expanduser(word)
    m = _VAR_LEAD.match(word)
    rest = word[m.end():] if m else word
    segs = _path_segments(rest)
    if m or not rest.startswith("/"):
        return segs
    for form in root_forms:
        if len(segs) >= len(form) and all(_seg_matches(p, r, True) for p, r in zip(segs, form)):
            return segs[len(form):]
    return None


def _paths_in(cand: str) -> Iterator[str]:
    """The paths one brace-expanded word can stand for. The word itself, unless it is a
    single segment of asterisks around a few letters (`*it*`): markdown emphasis, not a
    target. And, for `key=value`, the value — `dd of=core/./tests/x`, `--target=core/{a,b}`
    — which the shell does not glob but the program resolves like any other path (a
    value with a glob in it is left to the word's own check: `--include=*.toml` is a
    pattern for the program, not a path)."""
    if not ("/" not in cand and cand.startswith("*") and cand.endswith("*")
            and _real_chars(cand) < 3):
        yield cand
    _, eq, value = cand.partition("=")
    if eq and value and not _GLOB_CHARS.search(value):
        yield value


def _path_words_hit(view: str, guarded_tokens, root: str) -> bool:
    """True if some word of `view`, once the shell expands its globs, brace lists and
    dot segments, names a guarded token — `rm .age*/loop/active`, `rm core/{tests,x}/g`.
    Matching is segment-wise from the project root (no filesystem access): `te*`
    matches the segment `tests`, and a glob never crosses a `/`."""
    tok_segs = [t.split("/") for t in guarded_tokens]
    forms = _root_forms(root)
    lowered = view.lower()
    dot_ok = "dotglob" in lowered or "glob_dots" in lowered
    budget = _PATH_WORK_BUDGET
    for word in _WORDS.findall(view):
        if not _RESOLVABLE.search(word):
            continue                   # a plain word: the substring check already saw it
        cands = _brace_expand(word)
        if cands is None:
            return True                # cannot be evaluated: fail closed
        for cand in cands:
            budget -= 1
            for path in _paths_in(cand):
                rel = _root_relative(path, forms)
                if rel is None:
                    continue
                budget -= len(tok_segs)
                if any(_hits_token(rel, t, dot_ok) for t in tok_segs):
                    return True
            if budget < 0:
                return True            # more to look at than the hook may spend: fail closed
    return False


_GIT_WRITE_VERBS = frozenset(("checkout", "restore", "apply", "rm", "mv", "clean",
                              "update-index"))
# git's global options that take their value as the NEXT word
_GIT_ARG_OPTS = frozenset(("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                           "--super-prefix", "--config-env", "--attr-source"))
_COMMAND_SEGMENTS = re.compile(r"[;&|\n()`]+")


def _git_write_verb(view: str) -> bool:
    """A git write subcommand behind git's own global options (`git -C . clean`,
    `git -c k=v checkout`), which the plain `git\\s+checkout` alternative of
    _WRITE_OPS cannot see past. `git clean` — the one verb that deletes untracked
    files, which is what .agent/ is — has no plain alternative and is matched here
    only."""
    for seg in _COMMAND_SEGMENTS.split(view):
        toks = seg.split()
        for i, tok in enumerate(toks):
            if tok.rsplit("/", 1)[-1] != "git":
                continue
            j = i + 1
            while j < len(toks) and toks[j].startswith("-"):
                j += 2 if toks[j] in _GIT_ARG_OPTS else 1
            if j < len(toks) and (toks[j] in _GIT_WRITE_VERBS or
                                  (toks[j] == "stash" and toks[j + 1:j + 2] == ["pop"])):
                return True
    return False


# Verbs that mean something only NEXT TO a second word inside one pipeline segment:
# `find` with an action that deletes, an interpreter running code that writes. A
# chain is a list of patterns that must occur in that order. They are searched step
# by step, not as one `word[^|&]*call` regex: that scans to the end of the segment
# from EVERY occurrence of the word (quadratic — a long run of `node` words stalls
# the hook past its timeout), and a bounded span could be padded past. Like the
# _WRITE_OPS tail, these only ADD asks.
_PYTHON = re.compile(r"\bpython[0-9.]*\b")
# a quoted open() mode that can write: only mode letters, at least one of w a x +
# (`'x'`, `'r+'`, `'rb+'`, `'bw'`) — a filename that merely starts with one is not it
_PY_WRITE_MODE = r"['\"](?=[rwxabt+]*['\"])[rbt]*[wax+]"
_SCOPED_VERBS = (
    # -delete removes with no `rm` in sight; -fprint*/-fls write files. The segment
    # runs across the `\;` of an earlier -exec, not across a newline.
    (re.compile(r"[|&\n]+"),
     ((re.compile(r"\bg?find\b"), re.compile(r"\s-(?:delete|fprint0?|fprintf|fls)\b")),)),
    # perl/ruby -i edit in place exactly like `sed -i` (the perl branch of _WRITE_OPS
    # demands a literal `>`)
    (re.compile(r"[|;&]+"),
     ((re.compile(r"\b(?:perl|ruby)\b"), re.compile(r"\s-\w*i\b|\brename\b")),)),
    # python: open() modes the `[wa]` branch of _WRITE_OPS skips (exclusive create,
    # read-write), a pathlib rename (a bare `.rename(` is also pandas), the rest
    (re.compile(r"[|&]+"),
     ((_PYTHON, re.compile(r"open\s*\([^)]*" + _PY_WRITE_MODE)),
      (_PYTHON, re.compile(r"\b(?:pathlib|Path)\b"), re.compile(r"\.rename\s*\(")),
      (_PYTHON, re.compile(r"os\.(?:symlink|link)")))),
)
_INTERPRETER = re.compile(r"\b(?:node(?:js)?|deno|bun|ruby|php|perl)\b")
_CALLED_NAME = re.compile(r"\b(\w+)\s*(?:\(|['\"])")
# the name of an API that writes, deletes, moves or copies (`writeFileSync`,
# `createWriteStream`, `file_put_contents`, `rmSync`, `rmtree`, `FileUtils.rm_rf`, `cpSync`)
_WRITER_NAME = re.compile(
    r"(?i:write)|put_contents|"
    r"^(?:append|rm|remove|rename|copy|truncate|symlink|delete|chmod)|"
    r"^(?:mv|cp|ln|link|move)(?:Sync|_\w+)?$")
# A quoted open() mode that can write, in the spellings of the languages that reach this
# table: Node's flags (`w` `wx` `xw` `ax+` `as+` `rs+`), PHP's modes (`xb` `cb` `w+b` `wbe`),
# Ruby's with an encoding after a colon (`w:UTF-8` `r+:UTF-8`) and perl's `+<`. The first
# alternative is the original grammar, kept as it was; a bare `r`, `rb`, `rs` or `r:UTF-8`
# reads and stays out. Each letter of the new alternatives is a real flag, so a quoted word
# such as "text", "case" or "access" in a block that follows an open call does not match.
_OPEN_MODE = (r"(?:(?:[waxc]|r[bts]*\+)[bts+]*"
              r"|(?:[xs]?[wacx][xs]?[bte]{0,2}\+?|[xs]?r[xs]?[bte]{0,2}\+)[bte]{0,2}"
              r"|\+<)(?::[\w.:-]*)?")
# Tokens of an open call, scanned left to right in ONE pass: an open word (`open`,
# `openSync`, `fopen`, with or without parentheses — `File.open "x", "w"`) arms the check,
# the `)` that ends its arguments disarms it, and a quoted write mode while armed is the
# hit. A regex that scans on from every open word would be quadratic in a long command.
_OPEN_TOKEN = re.compile(r"\bf?open\w*[\s(]|\)|['\"]" + _OPEN_MODE + r"['\"]")
# PHP's fopen() always takes a mode, so a call that shows no read-only one (`'r'`, `"rb"`)
# may be taking it from a variable (`fopen($p, $m)`), which cannot be read from the text.
# The quotes are optional because the exemption must hold in the dequoted view too.
_FOPEN_TOKEN = re.compile(r"\bfopen\s*\(|[()]|,\s*['\"]?r[bte]*['\"]?\s*(?=[,)])")
_INNER_GROUP = re.compile(r"\([^()]*\)")


def _call_views(seg: str) -> Iterator[str]:
    """`seg`, then `seg` with its innermost parenthesised groups collapsed to `_`, up to
    three times. An open call's arguments end at the FIRST `)`, so a nested call in front
    of the mode — `openSync(path.join(a, b), 'w')`, `open(os.path.join(a, b), 'w')` — hid
    it. The original is always the first view and every view is tried, so the extra views
    can only add asks."""
    yield seg
    for _ in range(3):
        collapsed = _INNER_GROUP.sub("_", seg)
        if collapsed == seg:
            return
        seg = collapsed
        yield seg


def _open_for_write(view: str, pos: int) -> bool:
    """An open call after `pos` with a quoted mode that can write, before its `)`."""
    armed = False
    for m in _OPEN_TOKEN.finditer(view, pos):
        tok = m.group(0)
        if tok == ")":
            armed = False
        elif tok[0] in "'\"":
            if armed:
                return True
        else:
            armed = True
    return False


def _fopen_without_read_mode(view: str, pos: int) -> bool:
    """A PHP `fopen(` after `pos` whose own arguments show no read-only mode. One pass with
    a stack of the calls still open, so a nested call cannot lend its mode to the outer one."""
    depth = 0
    calls: list[list] = []          # per open fopen: [depth of its arguments, saw `, 'r'`]
    for m in _FOPEN_TOKEN.finditer(view, pos):
        tok = m.group(0)
        if tok == "(":
            depth += 1
        elif tok == ")":
            depth -= 1
            closed = calls.pop() if calls and depth < calls[-1][0] else None
            if closed is not None and not closed[1]:
                return True
        elif tok[0] == ",":
            if calls and depth == calls[-1][0]:
                calls[-1][1] = True
        else:
            depth += 1
            calls.append([depth, False])
    return any(not seen for _, seen in calls)


def _interpreter_writes(seg: str) -> bool:
    """node/deno/bun/ruby/php/perl code in `seg` that CALLS a writer: `fs.writeFileSync(`,
    `File.delete "x"`, `FileUtils.rm_rf "x"`, `rmtree(`, or opens a file in a mode that
    writes. The `(` or quote right after the name keeps prose that merely says "write"
    quiet."""
    first = _INTERPRETER.search(seg)
    if first is None:
        return False
    if any(_WRITER_NAME.search(c.group(1)) for c in _CALLED_NAME.finditer(seg, first.end())):
        return True
    for view in _call_views(seg):
        m = _INTERPRETER.search(view)
        if m is not None and _open_for_write(view, m.end()):
            return True
    return _fopen_without_read_mode(seg, first.end())


def _scoped_write_verb(view: str) -> bool:
    for splitter, chains in _SCOPED_VERBS:
        for seg in splitter.split(view):
            for sview in _call_views(seg):
                for chain in chains:
                    pos = 0
                    for pat in chain:
                        m = pat.search(sview, pos)
                        if m is None:
                            break
                        pos = m.end()
                    else:
                        return True
    return any(_interpreter_writes(seg) for seg in re.split(r"[|&]+", view))


def _has_write_verb(view: str) -> bool:
    return bool(_WRITE_OPS.search(view)) or _git_write_verb(view) or _scoped_write_verb(view)


def _bash_hits_guarded(command: str, guarded_tokens, root: str = "") -> bool:
    """True if `command` carries a write-ish verb AND names a guarded path.

    The raw text is judged first, exactly as before. The same is then asked of the
    command with its quoting stripped (so `r""m ".age""nt/loop/active"` reads
    `rm .agent/loop/active`), and of each word the shell would expand — a glob, a
    brace list, a dot segment — resolved against the tokens from the project root."""
    unquoted = _dequote(command)
    views = [command] if unquoted == command else [command, unquoted]
    named = any(tok in v for v in views for tok in guarded_tokens)
    if not named and not (_RESOLVABLE.search(unquoted)
                          and _path_words_hit(unquoted, guarded_tokens, root)):
        return False
    return any(_has_write_verb(v) for v in views)


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
        if _bash_hits_guarded(command, CONTROL_TOKENS, root):
            return ("control", ASK_CONTROL)
        if _bash_hits_guarded(command, GUARDED_TOKENS, root):
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


# The harness kills a hook at its timeout (hooks.json: 30 s) and a killed hook decides
# nothing, which reads as allow — so a command long enough to stall the matching would
# walk straight through the guard. Own the deadline instead: SIGALRM raises, and
# main() turns that into the same ask as any other unevaluable action.
_DEADLINE_S = 20.0


def _on_deadline(signum: int, frame: object) -> None:
    raise TimeoutError("deadline exceeded")


def _arm_deadline() -> None:
    if not hasattr(signal, "setitimer"):
        return
    secs = _DEADLINE_S
    try:
        seam = float(os.environ.get("AGENT_LOOP_GUARD_TIMEOUT", secs))
        if 0 < seam <= _DEADLINE_S:     # false for NaN too: a bad value never lengthens it
            secs = seam
    except (ValueError, OverflowError):
        pass
    try:
        signal.signal(signal.SIGALRM, _on_deadline)
        signal.setitimer(signal.ITIMER_REAL, secs)
    except (ValueError, signal.ItimerError):
        pass                            # no main thread / no timer: run without one


def _disarm_deadline() -> None:
    if hasattr(signal, "setitimer"):
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
        except TimeoutError:
            pass                       # the alarm fired as we stood down: already one-shot


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
        _arm_deadline()
        decision = _decide(data, root)
        _disarm_deadline()  # first thing after the verdict: nothing may cut the answer short
    except Exception as exc:
        _disarm_deadline()
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
