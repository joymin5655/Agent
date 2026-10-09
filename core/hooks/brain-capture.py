#!/usr/bin/env python3
"""Stop hook — leave a session breadcrumb in the brain's raw/ quarantine.

The zero-effort safety net beneath the explicit MCP `brain_capture` tool: every
session that did work-in-progress leaves ONE raw capture even if the agent never
called the tool. Cross-AI by construction — it is driven either by

  * canonical JSON on stdin  (Claude registers it as a Stop hook), or
  * environment             (the codex session wrapper calls it from its
                             stop path: AGENT / AGENT_SESSION_ID set, no stdin),

so all three runtimes converge on the same capture through their own native
stop mechanism.

What it captures: the *uncommitted* working-tree state (git status + diffstat) —
the ephemeral WIP that git history won't preserve — plus which AI, session, and
project. It writes via store.write_raw (provenance kind=generated, raw/ only);
it can NEVER touch notes/ or the vault, and the body is size-capped by write_raw.

Gated to stay quiet: it captures only when the tree has uncommitted changes. A
clean tree (already committed, or a read-only/research session) is a no-op, so
raw/ never fills with empty markers — intentional insights belong in an explicit
MCP brain_capture call, not here.

Claude fires Stop at the end of every turn, not once per session, so a repeat of
the same session's last-captured working-tree status is skipped as well.

Hook protocol: reads stdin (canonical JSON, optional), writes ZERO bytes to
stdout (pass-through observation), exits 0. Fail-open: every error is swallowed —
a capture must never block, delay, or fail a session's end.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# store.py lives in the sibling core/brain/ package; import it by path.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "brain"))
try:
    import store  # noqa: E402
except Exception:  # pragma: no cover - import failure must not break the session
    store = None

_AI_ALIAS = {"claude-code": "claude"}
_GIT_TIMEOUT = 5
_DEDUPE_SCAN = 50  # newest same-slug captures checked for this session


def _git(cwd: str, *args: str) -> str:
    """Run a read-only git command in `cwd`; '' on any failure (never raises)."""
    try:
        out = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True, text=True, timeout=_GIT_TIMEOUT,
        )
        return out.stdout if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _read_event() -> dict:
    """Canonical event JSON from stdin, or {} if stdin is empty/invalid."""
    try:
        raw = sys.stdin.read()
    except Exception:
        return {}
    raw = (raw or "").strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except (ValueError, TypeError):
        return {}


def _event_name(data: dict) -> str:
    """The event type. Claude's native payload uses `hook_event_name`, not the
    canonical `event` — mirror supervisor.py's fallback so the Stop gate reads the
    real field. Env-driven wrapper calls send neither → default to Stop (the
    wrappers only invoke this at stop)."""
    return data.get("event") or data.get("hook_event_name") or "Stop"


def _resolve_ai(data: dict) -> str:
    """Which AI is ending this session. Prefers the canonical `ai` field, then the
    AGENT env (set by the codex session wrapper, or by hand). Claude's native Stop
    payload carries neither — the passthrough adapter doesn't stamp `ai` (a known
    protocol gap: hook-protocol.md §2 lists `ai` as required, adapter.sh just
    exec's) — so fall back to Claude's signature keys rather than mis-filing the
    primary runtime's sessions under 'unknown'."""
    ai = data.get("ai") or os.environ.get("AGENT")
    if not ai:
        ai = "claude-code" if ("hook_event_name" in data or "stop_hook_active" in data) else "unknown"
    return _AI_ALIAS.get(ai, ai)


def _already_captured(ai: str, session: str, slug: str, porcelain: str) -> bool:
    """True if this session's latest capture for `slug` already holds the same
    working-tree status. Keyed on porcelain, not diffstat: line counts grow every
    turn while the WIP file set stays the same. Any error → False (capture anyway)."""
    if not session:  # no id → "same session" is unknowable
        return False
    try:
        d = store.raw_dir() / store.slugify(ai, "unknown")
        block = "```\n" + porcelain.rstrip() + "\n```"
        pattern = f"????????-??????-??????-{store.slugify(slug)}.md"  # write_raw stamp
        for path in sorted(d.glob(pattern), reverse=True)[:_DEDUPE_SCAN]:
            prov = store.parse_note(path)[0].get("provenance")
            if not prov:  # unreadable (e.g. oversize) → can't tell which is newest
                return False
            if prov.get("session") == session:
                return block in path.read_text(encoding="utf-8")
    except Exception:
        return False
    return False


def main() -> int:
    if store is None:
        return 0
    data = _read_event()

    # Only capture at session end.
    event = _event_name(data)
    if event != "Stop":
        return 0

    ai = _resolve_ai(data)
    session = data.get("session_id") or os.environ.get("AGENT_SESSION_ID") or ""
    cwd = data.get("cwd") or os.getcwd()
    transcript = data.get("transcript_path") or ""

    # Gate: only sessions with uncommitted work-in-progress are worth a breadcrumb.
    porcelain = _git(cwd, "status", "--porcelain")
    if not porcelain.strip():
        return 0
    diffstat = _git(cwd, "diff", "--stat", "HEAD")

    root = _git(cwd, "rev-parse", "--show-toplevel").strip()
    project = Path(root).name if root else Path(cwd).name
    slug = f"session-{project}"
    if _already_captured(ai, session, slug, porcelain):
        return 0

    lines = [f"Session `{session}` ({ai}) on **{project}** — uncommitted WIP at session end.", ""]
    if diffstat.strip():
        lines += ["Changed files (diff --stat HEAD):", "```", diffstat.rstrip(), "```", ""]
    lines += ["Working-tree status (porcelain):", "```", porcelain.rstrip(), "```"]
    if transcript:
        lines += ["", f"transcript: {transcript}"]
    body = "\n".join(lines)

    try:
        store.write_raw(
            ai=ai, session=session, slug=slug,
            body=body, source=f"session-capture:{event}",
            title=f"{ai} session on {project}", generated_by="brain-capture",
        )
    except Exception:  # pragma: no cover - fail-open
        return 0
    return 0  # NO stdout — pass-through observation hook


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception:  # pragma: no cover - last-resort fail-open
        raise SystemExit(0)
