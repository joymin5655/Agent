#!/usr/bin/env python3
"""review-evidence.py — review-evidence helpers shared by call-worker.sh and the commit gate.

  project-key [--root DIR]  per-project key: sha256(realpath(git toplevel))[:12], the same
                            key council-escalation-gate.py's state_dir() uses
  key --staged              sha256 over mode+blob of the STAGED risk-path files only (empty
                            line when none; exit 2 on any git failure, never a key); risk
                            paths are classified by `council-threshold.sh --classify`
  check --staged            commit gate: exit 0 when no risk file is staged, or an
                            external-vendor (not anthropic, not an advisor-* role)
                            `complete` review row in
                            reviews.jsonl is bound to this exact key, or the user set
                            AGENT_REVIEW_OVERRIDE (>=10 chars; logged). Exit 1 otherwise.
                            The override is user-only by policy; agents must not set it.
  summary CAPTURE...        lane-status line for the council report; first line warns
                            "single-vendor review" when no external lane completed
"""
from __future__ import annotations

import getpass
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

# realpath, not abspath: consumer hooks reach this file as <link>/../infra/..., and a
# lexical ".." collapse would point THRESHOLD outside the framework copy.
HERE = os.path.dirname(os.path.realpath(__file__))
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


OVERRIDE_MIN = 10
OVERRIDE_MAX = 300
SINGLE_VENDOR = "single-vendor review — not a council (no external lane returned)"


def workers_dir() -> str:
    return os.environ.get("AGENT_WORKERS_DIR") or os.path.join(
        os.path.expanduser("~"), ".agent", "workers", project_key())


def has_external_complete(key: str) -> bool:
    try:
        with open(os.path.join(workers_dir(), "reviews.jsonl"), encoding="utf-8",
                  errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return False
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if (isinstance(row, dict) and row.get("diff_key") == key
                and row.get("status") == "complete"
                and not str(row.get("role") or "").startswith("advisor")
                and row.get("vendor") not in (None, "", "anthropic")):
            return True
    return False


def log_override(key: str | None, reason: str) -> None:
    logs = os.environ.get("AGENT_LOGS_DIR") or os.path.join(
        os.path.expanduser("~"), ".agent", "logs")
    try:
        user = getpass.getuser()
    except (KeyError, OSError, ImportError):
        user = "unknown"
    row = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "project_key": project_key(), "diff_key": key, "reason": reason[:OVERRIDE_MAX],
           "user": user}
    os.makedirs(logs, exist_ok=True)
    with open(os.path.join(logs, "review-override.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(row) + "\n")


def try_override(key: str | None) -> bool:
    """User-only escape: a logged reason of >= OVERRIDE_MIN chars. It also covers a key
    that cannot be computed, so a broken git state never leaves --no-verify as the
    only way out."""
    reason = (os.environ.get("AGENT_REVIEW_OVERRIDE") or "").strip()
    if len(reason) < OVERRIDE_MIN:
        return False
    try:
        log_override(key, reason)
    except OSError as exc:
        print(f"review-evidence: override log write failed ({exc})", file=sys.stderr)
        return False
    print("review-evidence: AGENT_REVIEW_OVERRIDE accepted — override recorded in "
          "review-override.jsonl", file=sys.stderr)
    return True


def check_staged() -> int:
    try:
        key = diff_key_staged()
    except (EvidenceError, OSError, IndexError, UnicodeDecodeError) as exc:
        if try_override(None):
            return 0
        print(f"review-evidence: cannot compute the staged review key ({exc}) — "
              "failing closed (AGENT_REVIEW_OVERRIDE still applies)", file=sys.stderr)
        return 1
    if not key:
        return 0
    if has_external_complete(key):
        return 0
    if try_override(key):
        return 0
    top = git_toplevel(os.getcwd()) or os.getcwd()
    try:
        entries = staged_entries(top)
        files = sorted(classify_risk(top, list(entries)))
    except EvidenceError:
        files = []
    print("review-evidence: risk-area files are staged and no external-vendor review "
          "(status complete) is bound to this staged content:", file=sys.stderr)
    for path in files:
        print(f"  - {path}", file=sys.stderr)
    print("  Run `/council-review --staged` (re-run it after editing any risk file), or, "
          "only when every external lane is down and the user agrees:\n"
          '    AGENT_REVIEW_OVERRIDE="<reason, >=10 chars>" git commit ...\n'
          "  The override is user-only; agents must not set it. It is logged.",
          file=sys.stderr)
    return 1


def read_frontmatter(path: str) -> dict[str, str]:
    fm: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            if f.readline().strip() != "---":
                return fm
            for line in f:
                if line.strip() == "---":
                    break
                k, sep, v = line.partition(":")
                if sep:
                    fm[k.strip()] = v.strip()
    except OSError:
        pass
    return fm


def backend_vendors() -> dict[str, str]:
    path = os.environ.get("AGENT_BACKENDS_FILE") or os.path.join(HERE, "backends.json")
    try:
        with open(path, encoding="utf-8") as f:
            backends = json.load(f).get("backends", {})
        return {n: b.get("vendor") or "" for n, b in backends.items() if isinstance(b, dict)}
    except (OSError, ValueError, AttributeError):
        return {}


def summary(captures: list[str]) -> int:
    vendors = backend_vendors()
    parts: list[str] = []
    external_complete = 0
    for cap in captures:
        fm = read_frontmatter(cap)
        backend = fm.get("backend", "?")
        status = fm.get("status", "unknown")
        vendor = vendors.get(backend) or ("anthropic" if backend == "claude" else "")
        good = status == "complete"
        advisory = fm.get("role", "").startswith("advisor")
        if good and vendor and vendor != "anthropic" and not advisory:
            external_complete += 1
        parts.append(f"{backend} {'✓' if good else '✗'} ({status})")
    if not external_complete:
        print(SINGLE_VENDOR)
    print("Lane status: " + " | ".join(parts))
    return 0


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
    if argv == ["check", "--staged"]:
        return check_staged()
    if argv[:1] == ["summary"]:
        return summary(argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
