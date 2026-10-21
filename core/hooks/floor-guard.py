#!/usr/bin/env python3
"""floor-guard PreToolUse hook — warn when a change lowers a quality floor.

WARN-ONLY. Emits `additionalContext` and never a permission decision (no allow / ask /
deny): `allow` would skip the host's own permission prompt, and the point of this hook is
only to make the agent say what it is doing. Whether it should ever block is decided later,
from the firing record, not guessed here.

A quality floor is lowered when a change makes a red check go green without fixing the
cause. Detected as markers ADDED (count in the new text minus count in the old text > 0):
  - test skips: pytest skip/skipif/xfail, unittest.skip, it/test/describe.skip, xit,
    xdescribe, xtest, Go t.Skip, Rust #[ignore], JUnit @Disabled
  - type/lint suppressions: @ts-ignore, @ts-nocheck, @ts-expect-error, eslint-disable,
    `# type: ignore`, `# noqa`, `# pyright: ignore`
Sources of old/new text by tool (canonical names; the adapters map their native tools):
  Edit       old_string vs new_string
  MultiEdit  summed over the edits[] entries
  Write      content vs the file currently on disk (missing or unreadable file = empty)
Documentation files (.md/.rst/.txt/...) are skipped: they describe markers, they do not use them.

Bash commands are checked conservatively (a false negative is fine, a false positive is not):
  - `rm` / `unlink` / `git rm` of a test path (tests/, test_*, *_test.*, *.test.*, *.spec.*)
  - `sed -i` / `perl -i` that puts a skip marker into a test path
  - `pytest --deselect` and `pytest -k "... not ..."`
The command is tokenized with stdlib shlex, not the pre-tool-guard lexer: that lexer lives
inside a shell heredoc (not importable) and is built around secrets/ reads. Anything shlex
cannot parse, any heredoc, and any path built from a shell variable is left alone.

Configuration env vars:
  AGENT_FLOOR_GUARD     off | 0 | false  disables the hook (anything else = on)
  AGENT_GATE_SINK_DIR   redirect the firing record (test runners); default <repo>/.agent/logs
  AGENT_REPRODUCE_TEST  1 marks battery-fed records so they never inflate the fire rate

Hook protocol: canonical event JSON on stdin; empty stdout (no finding) or one
`additionalContext` object. Exit is always 0 and any error is swallowed (fail-open).
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

OFF_VALUES = {"off", "0", "false"}
FILE_TOOLS = {"Write", "Edit", "MultiEdit"}
DOC_EXTENSIONS = (".md", ".mdx", ".rst", ".txt", ".adoc")
MAX_TEXT_BYTES = 2_000_000  # larger edits are skipped, not scanned (keeps the hook O(n) and quick)
MAX_COMMAND_CHARS = 20_000  # same bound for the shlex pass over a Bash command
MAX_LISTED = 6  # findings named in the warning; the rest are summarized
SINK_NAME = "floor-guard.jsonl"

# (label shown to the agent, compiled pattern). Patterns are linear: no nested quantifiers.
SKIP_MARKERS: list[tuple[str, re.Pattern[str]]] = [
    (label, re.compile(pat))
    for label, pat in [
        ("@pytest.mark.skipif", r"@pytest\.mark\.skipif\b"),
        ("@pytest.mark.skip", r"@pytest\.mark\.skip\b"),
        ("pytest.skip(", r"\bpytest\.skip\s*\("),
        ("@pytest.mark.xfail", r"@pytest\.mark\.xfail\b"),
        ("@unittest.skip", r"@unittest\.skip"),
        ("it.skip(", r"\bit\.skip\s*\("),
        ("test.skip(", r"\btest\.skip\s*\("),
        ("describe.skip(", r"\bdescribe\.skip\s*\("),
        ("xit(", r"(?<![\w.])xit\s*\("),
        ("xdescribe(", r"(?<![\w.])xdescribe\s*\("),
        ("xtest(", r"(?<![\w.])xtest\s*\("),
        ("t.Skip(", r"\bt\.Skip(?:f|Now)?\s*\("),
        ("#[ignore]", r"#\[ignore\b[^\]\n]{0,200}\]"),
        ("@Disabled", r"@Disabled\b"),
    ]
]
SUPPRESSION_MARKERS: list[tuple[str, re.Pattern[str]]] = [
    (label, re.compile(pat))
    for label, pat in [
        ("@ts-ignore", r"@ts-ignore\b"),
        ("@ts-nocheck", r"@ts-nocheck\b"),
        ("@ts-expect-error", r"@ts-expect-error\b"),
        ("eslint-disable", r"\beslint-disable"),
        ("# type: ignore", r"#\s*type:\s*ignore\b"),
        ("# noqa", r"#\s*noqa\b"),
        ("# pyright: ignore", r"#\s*pyright:\s*ignore\b"),
    ]
]
MARKERS = SKIP_MARKERS + SUPPRESSION_MARKERS
# One cheap scan that says "nothing here can match": most edits end here without a disk read.
PREFILTER = re.compile(
    r"skip|xfail|xit\s*\(|xdescribe|xtest|\[ignore|@Disabled|@ts-|eslint-disable"
    r"|type:\s*ignore|noqa|pyright:\s*ignore",
    re.IGNORECASE,
)

SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
BACKGROUNDERS = {"nohup"}  # supply-chain-scan: allow-literal wrapper name skipped to find the command, not a spawn
LAUNCHERS = {"sudo", "doas", "command", "env", "time", "exec", "nice", "builtin", "rtk"} | BACKGROUNDERS
SEPARATOR_CHARS = set(";|&\n()")
REDIRECT_CHARS = set("<>")
TEST_DIR = re.compile(r"(?:^|/)(?:tests?|__tests__|spec|test_[^/]+)(?:/|$)")
TEST_FILE = re.compile(r"(?:^|/)(?:test_[^/]*\.\w+|[^/]*_test\.\w+|[^/]*\.(?:test|spec)\.\w+)$")
SCRATCH_PREFIXES = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")
VENDORED_PARTS = {"node_modules", ".venv", "venv", "site-packages", ".git", "__pycache__",
                  ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache"}
HEREDOC = re.compile(r"<<(?!<)")
BASH_PREFILTER = re.compile(r"\b(?:rm|unlink|sed|perl|pytest|py\.test)\b")
# git global options that consume the following word
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}


def marker_counts(text: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for label, pat in MARKERS:
        n = len(pat.findall(text))
        if n:
            counts[label] = n
    return counts


def added_markers(old_text: str, new_text: str) -> dict[str, int]:
    """Markers whose count rose, as {label: increase}."""
    if not PREFILTER.search(new_text):
        return {}
    old = marker_counts(old_text)
    return {k: v - old.get(k, 0) for k, v in marker_counts(new_text).items() if v > old.get(k, 0)}


def as_str(value: Any) -> str:
    return value if isinstance(value, str) else ""


def read_disk(path: str, cwd: str) -> str:
    """Current content of `path`; missing, unreadable, a directory or oversized = empty."""
    try:
        full = path if os.path.isabs(path) or not cwd else os.path.join(cwd, path)
        if os.path.getsize(full) > MAX_TEXT_BYTES:
            return ""
        with open(full, "rb") as f:
            return f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def file_findings(tool: str, tool_input: dict[str, Any], cwd: str) -> list[tuple[str, str, int]]:
    """[(file_path, marker label, increase)] for an Edit / MultiEdit / Write."""
    path = as_str(tool_input.get("file_path"))
    if not path or path.lower().endswith(DOC_EXTENSIONS):
        return []
    if tool == "Write":
        new_text = as_str(tool_input.get("content"))
        if len(new_text) > MAX_TEXT_BYTES or not PREFILTER.search(new_text):
            return []
        old_text = read_disk(path, cwd)
    elif tool == "Edit":
        old_text = as_str(tool_input.get("old_string"))
        new_text = as_str(tool_input.get("new_string"))
    else:
        edits = tool_input.get("edits")
        pairs = [e for e in edits if isinstance(e, dict)] if isinstance(edits, list) else []
        old_text = "\n".join(as_str(e.get("old_string")) for e in pairs)
        new_text = "\n".join(as_str(e.get("new_string")) for e in pairs)
    if len(old_text) > MAX_TEXT_BYTES or len(new_text) > MAX_TEXT_BYTES:
        return []
    return [(path, label, n) for label, n in added_markers(old_text, new_text).items()]


# --- Bash -------------------------------------------------------------------------------


def tokenize(command: str) -> list[str] | None:
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=";<>|&()\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        lex.commenters = ""
        return list(lex)
    except ValueError:
        return None


def split_segments(tokens: list[str]) -> list[list[str]]:
    """Simple commands: split at separators, drop redirects together with their target."""
    segments: list[list[str]] = [[]]
    skip_next = False
    for tok in tokens:
        punct = bool(tok) and all(c in SEPARATOR_CHARS or c in REDIRECT_CHARS for c in tok)
        if skip_next:
            skip_next = False
            if not punct:
                continue
        if punct and any(c in REDIRECT_CHARS for c in tok):
            skip_next = True
        elif punct:
            segments.append([])
        else:
            segments[-1].append(tok)
    return [s for s in segments if s]


def is_test_path(path: str) -> bool:
    if not path or "$" in path or "`" in path:
        return False
    if path.startswith(SCRATCH_PREFIXES) or VENDORED_PARTS.intersection(path.split("/")):
        return False
    return bool(TEST_DIR.search(path) or TEST_FILE.search(path))


def operands(args: list[str]) -> list[str]:
    out: list[str] = []
    options_done = False
    for a in args:
        if options_done or not a.startswith("-"):
            out.append(a)
        elif a == "--":
            options_done = True
    return out


def sed_perl_in_place(head: str, args: list[str]) -> bool:
    flag = r"-[nEersz]*i" if head == "sed" else r"-[pnlaE0-9]*i"
    return any(re.match(flag, a) or a == "--in-place" for a in args if a.startswith("-"))


def pytest_deselects(args: list[str]) -> list[str]:
    labels: list[str] = []
    for i, w in enumerate(args):
        if w == "--deselect" or w.startswith("--deselect="):
            labels.append("--deselect")
        else:
            expr = args[i + 1] if w == "-k" and i + 1 < len(args) else w[2:] if w.startswith("-k") else ""
            if re.search(r"\bnot\b", expr):
                labels.append('-k "not ..."')
    return labels


def segment_findings(words: list[str], depth: int = 0) -> list[tuple[str, str, int]]:
    """[(target, label, 1)] for one simple command."""
    words = list(words)
    while words and (re.match(r"[A-Za-z_]\w*=", words[0]) or os.path.basename(words[0]) in LAUNCHERS):
        launcher = os.path.basename(words[0]) in LAUNCHERS
        words.pop(0)
        while launcher and words and words[0].startswith("-"):
            words.pop(0)
    if not words:
        return []
    head = os.path.basename(words[0])
    args = words[1:]
    found: list[tuple[str, str, int]] = []

    if head in SHELLS and "-c" in args and depth < 2:
        idx = args.index("-c")
        if idx + 1 < len(args):
            inner = tokenize(args[idx + 1])
            for seg in split_segments(inner or []):
                found += segment_findings(seg, depth + 1)
        return found

    remove_args: list[str] | None = None
    if head in ("rm", "unlink"):
        remove_args = args
    elif head == "git":
        rest = list(args)
        while rest and rest[0].startswith("-"):
            opt = rest.pop(0)
            if opt in GIT_VALUE_OPTS and rest:
                rest.pop(0)
        if rest and rest[0] == "rm" and "--cached" not in rest:
            remove_args = rest[1:]
    if remove_args is not None:
        found += [(p, "deletes test file", 1) for p in operands(remove_args) if is_test_path(p)]

    if head in ("sed", "perl") and sed_perl_in_place(head, args):
        script = " ".join(a for a in args if not is_test_path(a))
        script = re.sub(r"\\(?=[A-Za-z0-9])", " ", script).replace("\\", "")  # \n -> space, \. -> .
        if any(pat.search(script) for _, pat in SKIP_MARKERS):
            found += [(p, "adds skip via " + head + " -i", 1) for p in operands(args) if is_test_path(p)]

    if any(os.path.basename(w) in ("pytest", "py.test") for w in words):
        found += [("pytest", label, 1) for label in pytest_deselects(args)]
    return found


def bash_findings(command: str) -> list[tuple[str, str, int]]:
    if (len(command) > MAX_COMMAND_CHARS or not BASH_PREFILTER.search(command)
            or HEREDOC.search(command)):
        return []
    tokens = tokenize(command)
    if tokens is None:
        return []
    found: list[tuple[str, str, int]] = []
    for seg in split_segments(tokens):
        found += segment_findings(seg)
    return found


# --- output -----------------------------------------------------------------------------


def build_message(findings: list[tuple[str, str, int]]) -> str:
    # str.format with *f on purpose: the out-of-band label guard treats .format() arguments
    # as runtime data but cannot enumerate an f-string, or per-item {n} counts, fed by
    # tool-derived tuples (it gives up past 4096 candidate texts).
    rows = ["  - {}: {} (+{})".format(*f) for f in findings[:MAX_LISTED]]
    if len(findings) > MAX_LISTED:
        rows.append("  - ... and {} more".format(len(findings) - MAX_LISTED))
    return (
        "floor-guard: this change lowers a quality floor.\n{}\n"
        "WHY: a skipped, ignored or deleted check turns red into green without fixing "
        "anything, and nothing downstream will notice.\n"
        "FIX: remove the bypass and fix the root cause (the failing test, type error or lint "
        "finding). If the user explicitly asked for this, say so in your reply (what is "
        "skipped or suppressed, and that they asked); if they did not explicitly ask, do not "
        "make this change."
    ).format("\n".join(rows))


def repo_root(cwd: str) -> str:
    base = os.environ.get("AGENT_PROJECT_DIR") or cwd or os.getcwd()
    try:
        out = subprocess.check_output(
            ["git", "-C", base, "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL, timeout=2,
        )
        return out.decode().strip() or base
    except (subprocess.SubprocessError, OSError):
        return base


def log_firing(tool: str, findings: list[tuple[str, str, int]], cwd: str,
               session_id: str) -> None:
    """Append a content-free record (labels and paths only) to the jsonl sink."""
    sink_dir = os.environ.get("AGENT_GATE_SINK_DIR") or os.path.join(repo_root(cwd), ".agent", "logs")
    rec = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "guard": "floor-guard",
        "hook": "floor-guard.py",
        "tool": tool,
        "file_path": findings[0][0],
        "markers": sorted({label for _, label, _ in findings}),
        "decision": "warn",
        "session_id": session_id or os.environ.get("AGENT_SESSION_ID", "main"),
        "reproduce_test": os.environ.get("AGENT_REPRODUCE_TEST", "") in ("1", "true", "TRUE", "True"),
        "origin": os.environ.get("AGENT_LOG_ORIGIN") or "session",
        "schema_version": "2.0.0",
    }
    try:
        os.makedirs(sink_dir, exist_ok=True)
        with open(os.path.join(sink_dir, SINK_NAME), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
    except OSError:
        pass


def main() -> None:
    if os.environ.get("AGENT_FLOOR_GUARD", "").strip().lower() in OFF_VALUES:
        return
    try:
        event = json.loads(sys.stdin.read())
    except ValueError:
        return
    if not isinstance(event, dict):
        return
    tool = event.get("tool_name")
    tool_input = event.get("tool_input")
    if not isinstance(tool, str) or not isinstance(tool_input, dict):
        return
    cwd = as_str(event.get("cwd"))

    if tool in FILE_TOOLS:
        findings = file_findings(tool, tool_input, cwd)
    elif tool == "Bash":
        findings = bash_findings(as_str(tool_input.get("command")))
    else:
        return
    if not findings:
        return

    log_firing(tool, findings, cwd, as_str(event.get("session_id")))
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                  "additionalContext": build_message(findings)}}
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    with contextlib.suppress(Exception):  # a warning hook must never break the session
        main()
    sys.exit(0)
