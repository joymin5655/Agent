#!/usr/bin/env python3
"""Verify core hook modules avoid hardcoded local project roots."""

from __future__ import annotations

from pathlib import Path
import sys

HOOKS_DIR = Path(__file__).resolve().parent
REPO_ROOT = HOOKS_DIR.parents[1]

HOOKS_TO_SCAN = [
    "supervisor.py",
    "admin-merge-track.py",
    "tdd-guard.py",
]

FORBIDDEN = [
    "WD_BLACK",
    "Obsidian-airlens",
    "apps/web",
    "AIRLENS_",
]


def test_no_project_specific_paths() -> None:
    for name in HOOKS_TO_SCAN:
        text = (HOOKS_DIR / name).read_text(encoding="utf-8")
        for needle in FORBIDDEN:
            assert needle not in text, f"{name} contains project-specific marker {needle!r}"


def test_project_root_shape() -> None:
    assert (REPO_ROOT / "core" / "hooks").resolve() == HOOKS_DIR.resolve()
    assert (REPO_ROOT / "core" / "config" / "config.json").exists()


if __name__ == "__main__":
    failures = []
    for fn in (test_no_project_specific_paths, test_project_root_shape):
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as exc:
            failures.append((fn.__name__, exc))
            print(f"FAIL {fn.__name__}: {exc}")
    if failures:
        sys.exit(1)
