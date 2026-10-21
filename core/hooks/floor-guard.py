#!/usr/bin/env python3
"""floor-guard PreToolUse hook — warn when a change lowers a quality floor.

WARN-ONLY. Emits `additionalContext` and never a permission decision (no allow / ask /
deny): `allow` would skip the host's own permission prompt, and the point of this hook is
only to make the agent say what it is doing. Whether it should ever block is decided later,
from the firing record, not guessed here.

A quality floor is lowered when a change makes a red check go green without fixing the
cause. Detected as markers ADDED (count in the new text minus count in the old text > 0):
  - test skips: pytest.mark.skip/skipif/xfail (decorator, `pytestmark =` or `marks=`),
    pytest.skip(), unittest.skip, it/test/describe.skip, xit,
    xdescribe, xtest, Go t.Skip, Rust #[ignore], JUnit @Disabled
  - type/lint suppressions: @ts-ignore, @ts-nocheck, @ts-expect-error, eslint-disable,
    `# type: ignore`, `# noqa`, `# pyright: ignore`
Sources of old/new text by tool (canonical names; the adapters map their native tools):
  Edit       old_string vs new_string
  MultiEdit  summed over the edits[] entries
  Write      content vs the file currently on disk (missing file = empty; an oversized,
             non-regular or unreadable existing file is skipped, never read unboundedly)
Documentation files (.md/.rst/.txt/...) are skipped: they describe markers, they do not use them.

Bash commands are checked conservatively (a false negative is fine, a false positive is not):
  - `rm` / `unlink` / `git rm` (not --cached / -n) of a test path (tests/, test_*, *_test.*,
    *.test.*, *.spec.*)
  - `sed -i` / `perl -i` whose REPLACEMENT text (s///, sed i/a/c) puts a skip marker into a
    test path; deleting or rewriting a marker away never counts
  - `pytest --deselect` and `pytest -k "... not ..."`
The command is tokenized with stdlib shlex, not the pre-tool-guard lexer: that lexer lives
inside a shell heredoc (not importable) and is built around secrets/ reads. Anything shlex
cannot parse, any heredoc, shell comments and any path built from a shell variable is left
alone.

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
import stat
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
        # no leading "@": `pytestmark = pytest.mark.skip(...)` and `marks=pytest.mark.xfail` count too
        ("pytest.mark.skipif", r"\bpytest\.mark\.skipif\b"),
        ("pytest.mark.skip", r"\bpytest\.mark\.skip\b"),
        ("pytest.skip(", r"\bpytest\.skip\s*\("),
        ("pytest.mark.xfail", r"\bpytest\.mark\.xfail\b"),
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
        ("# noqa", r"#\s*(?i:noqa)\b"),
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
TEST_DIR_NAMES = {"test", "tests", "__tests__", "spec"}
TEST_FILE = re.compile(r"test_[^/]*\.\w+|[^/]*_test\.\w+|[^/]*\.(?:test|spec)\.\w+")
# A file under a tests/ or spec/ directory is a test only when it is code-like: data, docs and
# bytecode there (README.md, fixtures.json, *.pyc, docs/spec/old.yaml) are not a lowered floor.
# .snap is deliberately NOT listed: a deleted snapshot lets a failing snapshot test regenerate
# green, so `rm tests/__snapshots__/x.snap` still warns (warn-only, so a legit refresh costs one line).
NON_CODE_EXTENSIONS = (".md", ".mdx", ".rst", ".txt", ".adoc", ".log", ".pyc", ".pyo",
                       ".json", ".yaml", ".yml")
SCRATCH_PREFIXES = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")
VENDORED_PARTS = {"node_modules", ".venv", "venv", "site-packages", ".git", "__pycache__",
                  ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache"}
HEREDOC = re.compile(r"<<(?!<)")
SHELL_C_FLAGS = re.compile(r"-[A-Za-z]*c[A-Za-z]*")  # -c, -lc, -ec ...
COMMENT_STARTERS = " \t\r\n;|&("
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


def read_disk(path: str, cwd: str) -> str | None:
    """Current content of `path`: "" when it does not exist, None when it exists but must not
    be scanned (oversized, not a regular file such as a FIFO or device, or unreadable).

    Never blocks and never reads more than MAX_TEXT_BYTES + 1 bytes: O_NONBLOCK keeps a FIFO
    open from waiting for a writer, and the regular-file check happens on the open descriptor.
    """
    full = path if os.path.isabs(path) or not cwd else os.path.join(cwd, path)
    try:
        fd = os.open(full, os.O_RDONLY | os.O_NONBLOCK)
    except (FileNotFoundError, NotADirectoryError):
        return ""
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        data = b""
        while len(data) <= MAX_TEXT_BYTES:
            chunk = os.read(fd, MAX_TEXT_BYTES + 1 - len(data))
            if not chunk:
                break
            data += chunk
        return None if len(data) > MAX_TEXT_BYTES else data.decode("utf-8", errors="replace")
    except OSError:
        return None
    finally:
        os.close(fd)


def file_findings(tool: str, tool_input: dict[str, Any], cwd: str) -> list[tuple[str, str, int]]:
    """[(file_path, marker label, increase)] for an Edit / MultiEdit / Write."""
    path = as_str(tool_input.get("file_path"))
    if not path or path.lower().endswith(DOC_EXTENSIONS):
        return []
    if tool == "Write":
        new_text = as_str(tool_input.get("content"))
        if len(new_text) > MAX_TEXT_BYTES or not PREFILTER.search(new_text):
            return []
        disk_text = read_disk(path, cwd)
        if disk_text is None:
            return []
        old_text = disk_text
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


def strip_comments(command: str) -> str:
    """Drop shell comments (an unquoted `#` at the start of a word, to end of line).

    Done here rather than with shlex commenters, which also cut `a#b` mid-word and swallow the
    newline, gluing the next command onto the current segment. Quote state is tracked, so
    `echo "#"; rm x` keeps its second command.
    """
    out: list[str] = []
    quote = ""
    prev = " "
    i, n = 0, len(command)
    while i < n:
        c = command[i]
        if quote:
            out.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(command[i + 1])
                i += 1
            elif c == quote:
                quote = ""
        elif c == "\\" and i + 1 < n:
            out.append(c)
            out.append(command[i + 1])
            i += 1
            prev = "x"
        elif c in "'\"":
            quote = c
            out.append(c)
            prev = "x"
        elif c == "#" and prev in COMMENT_STARTERS:
            while i < n and command[i] != "\n":
                i += 1
            continue
        else:
            out.append(c)
            prev = c
        i += 1
    return "".join(out)


def tokenize(command: str) -> list[str] | None:
    try:
        lex = shlex.shlex(strip_comments(command), posix=True, punctuation_chars=";<>|&()\n")
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


def is_test_path(path: str, recursive: bool = False) -> bool:
    """Is `path` a test file, or (with `recursive`) a test directory being removed whole?"""
    if not path or "$" in path or "`" in path:
        return False
    norm = os.path.normpath(path)  # `tests/../src/main.py` is src/main.py
    parts = norm.split("/")
    if norm.startswith(SCRATCH_PREFIXES) or VENDORED_PARTS.intersection(parts):
        return False
    *dirs, last = parts
    if TEST_FILE.fullmatch(last) or any(d in TEST_DIR_NAMES or d.startswith("test_") for d in dirs):
        return not last.lower().endswith(NON_CODE_EXTENSIONS)
    if last in TEST_DIR_NAMES or last.startswith("test_"):
        return recursive  # a directory operand: only `rm -r` removes it
    return False


def operands(args: list[str]) -> list[str]:
    out: list[str] = []
    options_done = False
    for a in args:
        if options_done or not a.startswith("-"):
            out.append(a)
        elif a == "--":
            options_done = True
    return out


def short_flags(args: list[str]) -> set[str]:
    """Letters of the short options (`-rf` -> r, f) before any `--`."""
    letters: set[str] = set()
    for a in args:
        if a == "--":
            break
        if a.startswith("-") and not a.startswith("--"):
            letters.update(a[1:])
    return letters


def sed_perl_in_place(head: str, args: list[str]) -> bool:
    flag = r"-[nEersz]*i" if head == "sed" else r"-[pnlaE0-9]*i"
    return any(re.match(flag, a) or a.startswith("--in-place") for a in args if a.startswith("-"))


def sed_perl_parts(head: str, args: list[str]) -> tuple[list[str], list[str]] | None:
    """(scripts, file operands) of a sed / perl command line; None when a script is not inline."""
    script_flag = re.compile(r"-[nEzsru]*e" if head == "sed" else r"-[pnla0-9]*[eE]")
    scripts: list[str] = []
    files: list[str] = []
    options_done = False
    i = 0
    while i < len(args):
        a = args[i]
        i += 1
        if options_done or not a.startswith("-") or a == "-":
            files.append(a)
        elif a == "--":
            options_done = True
        elif a in ("-f", "--file") or a.startswith("--file=") or (head == "sed" and re.fullmatch(r"-[nEzsru]*f", a)):
            return None  # the script lives in a file we cannot see
        elif a == "--expression" or script_flag.fullmatch(a):
            if i >= len(args):
                return None
            scripts.append(args[i])
            i += 1
        elif a.startswith("--expression="):
            scripts.append(a.split("=", 1)[1])
    files = [f for f in files if f]  # BSD `sed -i ''` passes an empty suffix word
    if not scripts:
        if head != "sed" or not files:
            return None  # perl without -e runs a script file
        scripts.append(files.pop(0))
    return scripts, files


def unescape_replacement(text: str) -> str:
    """Replacement / appended text with sed escapes resolved: `\\n` is a newline (never a stray `n`)."""
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text, flags=re.S)


def read_delimited(script: str, i: int, close: str, open_: str = "") -> tuple[str, int] | None:
    """Text from script[i] up to the unescaped `close` (nesting `open_`); (text, index after close)."""
    depth = 0
    start = i
    while i < len(script):
        c = script[i]
        if c == "\\":
            i += 2
            continue
        if open_ and c == open_:
            depth += 1
        elif c == close:
            if depth == 0:
                return script[start:i], i + 1
            depth -= 1
        i += 1
    return None


_PAIRS = {"{": "}", "(": ")", "[": "]", "<": ">"}


def read_substitution(script: str, i: int, bracketed: bool) -> tuple[str, int] | None:
    """script[i] is the `s` of s<d>pat<d>repl<d>; returns (replacement text, index after it)."""
    if i + 1 >= len(script):
        return None
    d = script[i + 1]
    if d.isalnum() or d in " \\\n;":
        return None
    if bracketed and d in _PAIRS:
        pat = read_delimited(script, i + 2, _PAIRS[d], d)
        if pat is None:
            return None
        j = pat[1]
        while j < len(script) and script[j] in " \t\n":
            j += 1
        if j >= len(script) or script[j] not in _PAIRS:
            return None
        rep = read_delimited(script, j + 1, _PAIRS[script[j]], script[j])
    else:
        pat = read_delimited(script, i + 2, d)
        if pat is None:
            return None
        rep = read_delimited(script, pat[1], d)
    return None if rep is None else (rep[0], rep[1])


def sed_added_text(script: str) -> str | None:
    """Text a sed script ADDS: s/// replacement sides and the text of i / a / c commands.

    Deletes and pattern sides never count. None = could not parse, which the caller treats as
    "stay silent".
    """
    added: list[str] = []
    i, n = 0, len(script)
    while i < n:
        if script[i] in " \t\n;{}":
            i += 1
            continue
        while i < n:  # address: N, $, /re/, \\cREc, first~step, with an optional ,second
            c = script[i]
            if c.isdigit() or c in "$~+":
                i += 1
            elif c == "/" or c == "\\":
                if c == "\\":
                    i += 1
                if i >= n:
                    return None
                got = read_delimited(script, i + 1, script[i])
                if got is None:
                    return None
                i = got[1]
                while i < n and script[i] in "IM":
                    i += 1
            else:
                break
            if i < n and script[i] == ",":
                i += 1
                continue
            if i < n and (script[i].isdigit() or script[i] in "$/\\~+"):
                continue
            break
        while i < n and script[i] in " \t!":
            i += 1
        if i >= n:
            break
        cmd = script[i]
        if cmd in "{}":
            i += 1
        elif cmd == "s":
            sub = read_substitution(script, i, bracketed=False)
            if sub is None:
                return None
            added.append(unescape_replacement(sub[0]))
            i = sub[1]
            while i < n and script[i] not in ";\n}":  # flags; `w file` runs to the end of the line
                i += 1
        elif cmd in "iac":
            i += 1
            while i < n and script[i] in " \t":
                i += 1
            if i < n and script[i] == "\\":
                i += 1
                while i < n and script[i] in " \t":
                    i += 1
                if i < n and script[i] == "\n":
                    i += 1
            start = i
            while i < n and not (script[i] == "\n" and script[i - 1] != "\\"):
                i += 1
            added.append(unescape_replacement(script[start:i]))
        elif cmd in "dpPnNgGhHxlq=D":
            i += 1
        elif cmd in "ywrRWbtTv:e":
            while i < n and script[i] != "\n":
                i += 1
        else:
            return None
    return "\n".join(added)


def perl_added_text(script: str) -> str:
    """Replacement sides of the s/// operators in a perl one-liner (unparseable ones are skipped)."""
    added: list[str] = []
    for m in re.finditer(r"(?:^|(?<=[\s;{}(]))s(?=[^\w\s])", script):
        sub = read_substitution(script, m.start(), bracketed=True)
        if sub is not None:
            added.append(unescape_replacement(sub[0]))
    return "\n".join(added)


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


def pytest_args(words: list[str]) -> list[str] | None:
    """Arguments of a pytest run when the COMMAND word is pytest; None otherwise.

    Recognized: pytest / py.test, python[3] [opts] -m pytest, and `uv run` / `poetry run` /
    `pipenv run` / `pdm run` in front of those. `echo pytest --deselect x` is not a run.
    """
    if not words:
        return None
    head = os.path.basename(words[0])
    if head in ("pytest", "py.test"):
        return words[1:]
    if re.fullmatch(r"python(?:3(?:\.\d+)?)?", head):
        for i, w in enumerate(words[1:-1], 1):
            if w == "-m" and words[i + 1] == "pytest":
                return words[i + 2:]
        return None
    if head in ("uv", "poetry", "pipenv", "pdm") and len(words) > 2 and words[1] == "run":
        rest = words[2:]
        while rest and rest[0].startswith("-"):
            rest = rest[1:]
        return pytest_args(rest)
    return None


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

    if head in SHELLS and depth < 2:
        for idx, a in enumerate(args):
            if SHELL_C_FLAGS.fullmatch(a):  # -c, -lc, -ec ...
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
        if rest and rest[0] == "rm":
            flags = short_flags(rest[1:])
            dry_or_keep = "--cached" in rest or "--dry-run" in rest or "n" in flags
            if not dry_or_keep:
                remove_args = rest[1:]
    if remove_args is not None:
        recursive = bool(short_flags(remove_args) & {"r", "R"}) or "--recursive" in remove_args
        found += [(p, "deletes test file", 1) for p in operands(remove_args) if is_test_path(p, recursive)]

    if head in ("sed", "perl") and sed_perl_in_place(head, args):
        parts = sed_perl_parts(head, args)
        if parts is not None:
            scripts, files = parts
            added = [perl_added_text(sc) if head == "perl" else sed_added_text(sc) for sc in scripts]
            if None not in added and any(pat.search(t or "") for t in added for _, pat in SKIP_MARKERS):
                found += [(p, "adds skip via " + head + " -i", 1) for p in files if is_test_path(p)]

    runner_args = pytest_args(words)
    if runner_args is not None:
        found += [("pytest", label, 1) for label in pytest_deselects(runner_args)]
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
