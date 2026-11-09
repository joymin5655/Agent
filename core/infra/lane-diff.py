#!/usr/bin/env python3
"""lane-diff.py — diff for a no-tools review lane, with function context for code files.

Usage: lane-diff.py [--staged | --head | <range>] [--max-bytes 122880]

A lane that cannot open files sees only the diff, so an enclosing try/catch or the rest of
a function is invisible to it. For code files this prints `git diff -W` (whole enclosing
function) when that stays small; every other file keeps its default diff. Past the byte
cap the plain default diff of the whole target is printed instead.

stderr's last line: context_mode=<w|mixed|default|over_cap> bytes=<n> files=<n> w_files=<n>
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile

CODE_EXT = frozenset(
    [
        "py",
        "sh",
        "bash",
        "js",
        "mjs",
        "cjs",
        "ts",
        "tsx",
        "jsx",
        "go",
        "rs",
        "rb",
        "java",
        "kt",
        "swift",
        "c",
        "h",
        "cc",
        "cpp",
        "hpp",
        "cs",
        "php",
        "scala",
        "dart",
        "m",
        "mm",
        "ex",
        "exs",
        "lua",
        "pl",
    ]
)
SKIP_PARTS = ("dist/", "build/", "vendor/", "node_modules/")
SKIP_NAMES = re.compile(
    r"(\.min\.|\.lock$|(^|/)package-lock\.json$|_pb2\.py$|\.pb\.go$|generated)"
)
ATTRIBUTES = """\
*.py diff=python
*.sh diff=bash
*.bash diff=bash
*.go diff=golang
*.rs diff=rust
*.rb diff=ruby
*.java diff=java
*.kt diff=kotlin
*.c diff=cpp
*.h diff=cpp
*.cc diff=cpp
*.cpp diff=cpp
*.hpp diff=cpp
*.cs diff=csharp
*.php diff=php
"""
SLACK = 8192


class GitError(Exception):
    pass


def git(args: list[str], attrs: str | None = None) -> bytes:
    cmd = ["git"]
    if attrs:
        cmd += ["-c", f"core.attributesFile={attrs}"]
    cmd += args
    proc = subprocess.run(cmd, capture_output=True, check=False)
    if proc.returncode != 0:
        reason = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise GitError(reason[0] if reason else f"git exited {proc.returncode}")
    return proc.stdout


def is_code_file(path: str) -> bool:
    ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
    if ext not in CODE_EXT:
        return False
    if any(f"/{part}" in f"/{path}" for part in SKIP_PARTS):
        return False
    return SKIP_NAMES.search(path) is None


def changed_files(selector: list[str]) -> list[list[str]]:
    """Per changed file, the pathspecs that select it (old and new path for a rename)."""
    raw = git(["diff", "--name-status", "-z", "-M", *selector]).split(b"\0")
    files: list[list[str]] = []
    i = 0
    while i < len(raw) and raw[i]:
        status = raw[i].decode("utf-8", "replace")
        n = 2 if status[0] in "RC" else 1
        files.append(
            [p.decode("utf-8", "surrogateescape") for p in raw[i + 1 : i + 1 + n]]
        )
        i += 1 + n
    return files


def build(selector: list[str], max_bytes: int) -> tuple[bytes, str, int, int]:
    files = changed_files(selector)
    if not files:
        return b"", "default", 0, 0
    parts: list[bytes] = []
    eligible = w_used = 0
    with tempfile.NamedTemporaryFile("w", suffix=".attrs", delete=False) as tmp:
        tmp.write(ATTRIBUTES)
    try:
        for paths in files:
            spec = ["--", *paths]
            plain = git(["diff", "-M", *selector, *spec])
            if is_code_file(paths[-1]):
                eligible += 1
                wide = git(["diff", "-W", "-M", *selector, *spec], attrs=tmp.name)
                if len(wide) <= 2 * len(plain) + SLACK:
                    parts.append(wide)
                    w_used += 1
                    continue
            parts.append(plain)
    finally:
        os.unlink(tmp.name)
    out = b"".join(parts)
    if len(out) > max_bytes:
        out = git(["diff", *selector])
        return out, ("over_cap" if len(out) > max_bytes else "default"), len(files), 0
    if w_used == 0:
        mode = "default"
    elif w_used == eligible:
        mode = "w"
    else:
        mode = "mixed"
    return out, mode, len(files), w_used


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    ap.add_argument("--staged", action="store_true", help="git diff --staged (default)")
    ap.add_argument("--head", action="store_true", help="HEAD~1..HEAD")
    ap.add_argument("target", nargs="?", help="a git range, passed through")
    ap.add_argument("--max-bytes", type=int, default=122880)
    args = ap.parse_args()
    if args.target:
        selector = [args.target]
    elif args.head:
        selector = ["HEAD~1..HEAD"]
    else:
        selector = ["--staged"]
    try:
        out, mode, nfiles, nw = build(selector, args.max_bytes)
    except GitError as exc:
        print(f"lane-diff: git failed: {exc}", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    print(
        f"context_mode={mode} bytes={len(out)} files={nfiles} w_files={nw}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
