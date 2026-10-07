#!/usr/bin/env python3
"""review-evidence.py — review-evidence helpers shared by call-worker.sh and the commit gate.

  project-key [--root DIR]  per-project key: sha256(realpath(git toplevel))[:12], the same
                            key council-escalation-gate.py's state_dir() uses
  key --staged              sha256 over mode+blob of the STAGED risk-path files only (empty
                            line when none; exit 2 on any git failure, never a key); risk
                            paths are classified by `council-threshold.sh --classify`
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
THRESHOLD = os.path.join(HERE, "council-threshold.sh")


def git_toplevel(path: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "-c", "core.fsmonitor=", "rev-parse", "--show-toplevel"],
            cwd=path, stderr=subprocess.DEVNULL, timeout=15,
        ).decode().strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return out or None


def canonical_root(path: str) -> str:
    """git toplevel of `path`, realpath'd; realpath(path) outside a repo.
    Mirrors council-escalation-gate.canonical_root (parity is tested)."""
    return os.path.realpath(git_toplevel(path) or path)


def project_key(root: str | None = None) -> str:
    """Same order as the gate: the cwd's own repo wins; the env dirs are only a
    fallback when cwd is not inside a git repo. A linked worktree is its own
    toplevel, so review and commit must run in the same worktree."""
    start = root or os.getcwd()
    if not root and git_toplevel(start) is None:
        start = (
            os.environ.get("AGENT_PROJECT_DIR")
            or os.environ.get("CLAUDE_PROJECT_DIR")
            or start
        )
    return hashlib.sha256(canonical_root(start).encode()).hexdigest()[:12]


class EvidenceError(Exception):
    pass


def _git(top: str, *args: str) -> bytes:
    env = dict(os.environ, GIT_LITERAL_PATHSPECS="1")
    proc = subprocess.run(
        ["git", "-c", "core.fsmonitor=", *args],
        cwd=top, capture_output=True, env=env, check=False,
    )
    if proc.returncode != 0:
        raise EvidenceError(f"git {args[0]} failed: {proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


def staged_entries(top: str) -> dict[str, tuple[str, str]]:
    """path -> (mode, blob) of the staged diff only; a deletion is ("000000", "deleted")."""
    # --no-abbrev: --raw abbreviates blob ids, and the abbreviation grows with the
    # object count, so a key computed at review time could differ at commit time.
    raw = _git(top, "diff", "--staged", "--raw", "-z", "--no-renames", "--no-abbrev",
               "--no-ext-diff", "--no-textconv").split(b"\0")
    entries: dict[str, tuple[str, str]] = {}
    i = 0
    while i + 1 < len(raw) and raw[i]:
        meta = raw[i].decode().lstrip(":").split()  # old-mode new-mode old-blob new-blob status
        path = raw[i + 1].decode(errors="surrogateescape")
        status = meta[4][0]
        entries[path] = ("000000", "deleted") if status == "D" else (meta[1], meta[3])
        i += 2
    return entries


def classify_risk(top: str, paths: list[str]) -> set[str]:
    if not paths:
        return set()
    proc = subprocess.run(
        ["bash", THRESHOLD, "--classify"], cwd=top, check=False, capture_output=True,
        input=b"".join(p.encode(errors="surrogateescape") + b"\0" for p in paths),
    )
    if proc.returncode != 0:
        raise EvidenceError("council-threshold --classify failed")
    return {x.decode(errors="surrogateescape") for x in proc.stdout.split(b"\0") if x}


def diff_key_staged() -> str:
    top = git_toplevel(os.getcwd())
    if top is None:
        raise EvidenceError("not inside a git repository")
    entries = staged_entries(top)
    risky = classify_risk(top, list(entries))
    if not risky:
        return ""
    lines = sorted(f"{p}\0{entries[p][0]}\0{entries[p][1]}" for p in risky)
    return hashlib.sha256("\n".join(lines).encode(errors="surrogateescape")).hexdigest()


def main(argv: list[str]) -> int:
    if argv[:1] == ["project-key"]:
        root = argv[2] if argv[1:2] == ["--root"] and len(argv) > 2 else None
        print(project_key(root))
        return 0
    if argv == ["key", "--staged"]:
        try:
            print(diff_key_staged())
        except EvidenceError as exc:
            print(f"review-evidence: {exc}", file=sys.stderr)
            return 2
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
