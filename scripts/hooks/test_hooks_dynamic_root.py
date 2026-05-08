#!/usr/bin/env python3
"""Verify all hook modules resolve PROJECT_ROOT dynamically (no hardcoded path)."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

HOOKS_DIR = Path(__file__).resolve().parent
REPO_ROOT = HOOKS_DIR.parents[1]

# Python hooks that hold a PROJECT_ROOT (or WIKI_ROOT) module-level constant.
HOOKS_WITH_PROJECT_ROOT = [
    "session-init.py",
    "session-daily-summary.py",
    "session-quality-gate.py",
    "record-handoff-on-keyword.py",
    "record-agent-routing.py",
    "record-chat-log.py",
    "record-github-repos.py",
    "record-session-activity.py",
    "wiki-auto-index.py",
    "token-budget-track.py",
]


def _load(name: str):
    path = HOOKS_DIR / name
    spec = importlib.util.spec_from_file_location(f"_hook_{name}", path)
    assert spec and spec.loader, name
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_no_hardcoded_volume_path() -> None:
    """No hook source contains the legacy hardcoded volume path."""
    legacy = "/workspace/internal-platform"
    for name in HOOKS_WITH_PROJECT_ROOT:
        text = (HOOKS_DIR / name).read_text(encoding="utf-8")
        assert legacy not in text, f"{name} still contains hardcoded path"


def test_project_root_resolves_under_repo() -> None:
    """Each hook's PROJECT_ROOT (file-based fallback) maps under the repo root.

    With CLAUDE_PROJECT_DIR unset, PROJECT_ROOT comes from `parents[2]` of the
    script file, which equals REPO_ROOT. wiki-auto-index.py additionally exposes
    WIKI_ROOT = REPO/Obsidian-airlens.
    """
    os.environ.pop("CLAUDE_PROJECT_DIR", None)
    expected_repo = REPO_ROOT.resolve()
    for name in HOOKS_WITH_PROJECT_ROOT:
        mod = _load(name)
        pr = getattr(mod, "PROJECT_ROOT", None)
        assert pr is not None, f"{name}: missing PROJECT_ROOT"
        assert Path(pr).resolve() == expected_repo, (name, pr)
        if name == "wiki-auto-index.py":
            wiki = Path(getattr(mod, "WIKI_ROOT")).resolve()
            assert wiki == (expected_repo / "Obsidian-airlens").resolve(), (
                name, wiki
            )


def test_token_budget_respects_env_var() -> None:
    """token-budget-track.py honors CLAUDE_PROJECT_DIR for MEMORY_DIR derivation."""
    fake_root = "/tmp/fake project_root"
    os.environ["CLAUDE_PROJECT_DIR"] = fake_root
    try:
        sys.modules.pop("_hook_token-budget-track.py", None)
        mod = _load("token-budget-track.py")
        # macOS resolves /tmp → /private/tmp; compare via .resolve() for portability.
        assert mod.PROJECT_ROOT == Path(fake_root).resolve(), mod.PROJECT_ROOT
        # Transcoding rule: '/', ' ', '_' all → '-'. Both /private and /tmp paths
        # produce a segment containing '-fake-project-root' (underscore → hyphen).
        assert "-fake-project-root" in str(mod.MEMORY_DIR), mod.MEMORY_DIR
    finally:
        os.environ.pop("CLAUDE_PROJECT_DIR", None)


def test_token_budget_transcoding_underscore() -> None:
    """Transcoding rule converts underscore to hyphen (matches Claude Code behavior)."""
    os.environ["CLAUDE_PROJECT_DIR"] = "/workspace/internal-platform"
    try:
        sys.modules.pop("_hook_token-budget-track.py", None)
        mod = _load("token-budget-track.py")
        # Expected transcoded segment matches actual ~/.claude/projects/<this>/ form.
        assert "-Volumes-WD-BLACK-SN770M-2TB-internal-platform" in str(mod.MEMORY_DIR), (
            mod.MEMORY_DIR
        )
    finally:
        os.environ.pop("CLAUDE_PROJECT_DIR", None)


if __name__ == "__main__":
    failures = []
    for fn in (
        test_no_hardcoded_volume_path,
        test_project_root_resolves_under_repo,
        test_token_budget_respects_env_var,
        test_token_budget_transcoding_underscore,
    ):
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as exc:
            failures.append((fn.__name__, exc))
            print(f"FAIL {fn.__name__}: {exc}")
    if failures:
        sys.exit(1)
