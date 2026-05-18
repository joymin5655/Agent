#!/usr/bin/env python3
"""Hardcoding scan for staged files.

Mirrors patterns from core/hooks/check-hardcoding.py (Claude Code PreToolUse hook),
but operates on `git diff --cached` to also catch direct edits made outside an AI tool.

Exit 0 on pass, 1 on violation.

Configuration (env vars):
  AGENT_HARDCODE_EXEMPT_GLOBS="config.ts,types.ts,..."  (comma-separated substrings)
  AGENT_HARDCODE_EXTENSIONS=".ts,.tsx,.py,..."           (comma-separated suffixes)
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_EXEMPT = (
    "config.ts",
    "config.js",
    "types.ts",
    "types.js",
    ".test.",
    ".spec.",
    "test/",
    "__tests__/",
    ".yml",
    ".yaml",
    ".md",
    ".json",
    "tailwind.config",
    "vite.config",
    "tsconfig",
    "eslint",
    "prettier",
    ".html",
    "assets/",
    "docs/",
    "wiki/",
)

if os.environ.get("AGENT_HARDCODE_EXEMPT_GLOBS"):
    EXEMPT_PATTERNS = tuple(
        p.strip() for p in os.environ["AGENT_HARDCODE_EXEMPT_GLOBS"].split(",") if p.strip()
    )
else:
    EXEMPT_PATTERNS = DEFAULT_EXEMPT

DEFAULT_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".py")
if os.environ.get("AGENT_HARDCODE_EXTENSIONS"):
    SCAN_EXTENSIONS = tuple(
        e.strip() for e in os.environ["AGENT_HARDCODE_EXTENSIONS"].split(",") if e.strip()
    )
else:
    SCAN_EXTENSIONS = DEFAULT_EXTENSIONS

HARDCODING_PATTERNS = [
    (
        r"\[\s*\d+\s*,\s*\[\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\]\s*\]",
        "Inline color segment array — must use config import",
    ),
    (
        r"linear-gradient\s*\(\s*\d+deg\s*,\s*rgb\(",
        "Hardcoded CSS gradient — must derive from config color scale",
    ),
    (
        r"(?:const|let|var)\s+\w*(?:TICK|LABEL|STOP).*=\s*\[",
        "Hardcoded tick/label array — must use config",
    ),
]

COMPONENT_PATTERNS = [
    (
        r"(?:const|let|var)\s+(?:MODES|LAYERS|OPTIONS|ALTITUDES|PROJECTIONS)\s*[=:]",
        "UI metadata array defined in component — must use config import",
    ),
]

COMPONENT_DIR_MARKERS = ("/components/", "/hooks/", "/pages/")


def is_exempt(file_path: str) -> bool:
    return any(pat in file_path for pat in EXEMPT_PATTERNS)


def is_scannable(file_path: str) -> bool:
    return file_path.endswith(SCAN_EXTENSIONS)


def get_staged_files() -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=AM"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]


def get_staged_diff(file_path: str) -> str:
    result = subprocess.run(
        ["git", "diff", "--cached", "--", file_path],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return ""
    added_lines = []
    for line in result.stdout.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            added_lines.append(line[1:])
    return "\n".join(added_lines)


def scan_content(content: str, file_path: str) -> list[str]:
    findings = []
    for pattern, message in HARDCODING_PATTERNS:
        matches = re.findall(pattern, content)
        if matches:
            findings.append(f"{message} ({len(matches)} match(es))")

    if any(marker in file_path for marker in COMPONENT_DIR_MARKERS):
        for pattern, message in COMPONENT_PATTERNS:
            if re.search(pattern, content):
                findings.append(message)
    return findings


def main() -> int:
    try:
        staged = get_staged_files()
    except subprocess.CalledProcessError as exc:
        print(f"[check-staged] git diff failed: {exc}", file=sys.stderr)
        return 0  # do not block commits on tooling failure

    violations: list[tuple[str, list[str]]] = []
    for file_path in staged:
        if not is_scannable(file_path):
            continue
        if is_exempt(file_path):
            continue
        if not Path(file_path).exists():
            continue
        diff_content = get_staged_diff(file_path)
        if not diff_content:
            continue
        findings = scan_content(diff_content, file_path)
        if findings:
            violations.append((file_path, findings))

    if violations:
        print("\n\033[0;31m✗ Hardcoding detected in staged changes:\033[0m", file=sys.stderr)
        for path, findings in violations:
            print(f"\n  {path}", file=sys.stderr)
            for f in findings:
                print(f"    • {f}", file=sys.stderr)
        print(
            "\n  Move constants to a config file and import them.\n"
            "  Bypass (emergency only): git commit --no-verify",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
