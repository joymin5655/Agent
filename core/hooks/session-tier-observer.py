#!/usr/bin/env python3
"""session-tier-observer.py — detect the session's model tier; advise, never switch.

Matcher: SessionStart (registered after session-init.py).

docs/model-routing.md routes work classes by tier (judgment at TOP, execution
at MID, mechanical at LOW) but nothing tells the running session which rung IT
occupies — an expensive session doing mechanical work inline is the leak the
routing policy exists to prevent. This observer detects the session model
best-effort and makes the routing guidance visible, staying strictly on the
allowed side of the policy's "no runtime model-switching" line: it reads and
reports; every dispatch decision remains the caller's, made visibly.

Detection sources, first hit wins (each is optional — the SessionStart payload
carries no model field as of 2026-07, verified empirically):

  stdin            — event["model"]["id"] / ["display_name"] / plain string,
                     future-proof for runtimes that surface it (statusline
                     already does)
  transcript       — tail of event["transcript_path"]: last "model": "..."
                     record (live on resume/compact, empty on cold start)
  settings-default — the "model" key in ~/.claude/settings.json; labeled as
                     the configured default, which a per-session override
                     may differ from

Family → tier map: fable/opus → TOP, sonnet → MID, haiku → LOW, else unknown.

Output: one stderr advisory line when a tier is detected (stdout stays empty —
SessionStart stdout injects session context, and an observer must not add
decision surface), plus a JSONL record for /manager-audit cross-checks.

Pure observer: never blocks, always exits 0, all exceptions swallowed.

Seams: AGENT_SESSION_TIER_SINK (default <cwd>/.agent/logs/session-tier.jsonl;
an override is confined by REALPATH to <cwd>/.agent/logs or the system temp dir,
else it falls back to the default — same contract as verify-observer.py),
AGENT_CLAUDE_SETTINGS (default ~/.claude/settings.json), AGENT_SESSION_ID.

Hardening (ports of verify-observer.py's sink contract, 2026-07-30 incident):
sink and transcript opens are O_NONBLOCK + fstat-S_ISREG guarded — a FIFO at
either path must not hang SessionStart; the detected model string is stripped
of C0/C1/DEL control bytes and length-capped before it reaches stderr or the
record (terminal/log injection).
Registered in docs/gate-registry.md (GATE session-tier-observer).
"""

import json
import os
import re
import stat
import sys
import tempfile
from datetime import datetime, timezone

TIER_MAP = (("fable", "TOP"), ("opus", "TOP"), ("sonnet", "MID"), ("haiku", "LOW"))

TRANSCRIPT_TAIL_BYTES = 65536
MODEL_RE = re.compile(r'"model"\s*:\s*"(claude-[A-Za-z0-9:._\[\]-]{1,60})"')
MODEL_MAX_CHARS = 200
_CTRL_RE = re.compile("[\x00-\x1f\x7f-\x9f]")  # C0 + DEL + C1 (U+009B is a one-byte CSI)
_MODEL_ALLOW_RE = re.compile(r"[^A-Za-z0-9:._\[\]-]")  # model-id alphabet (telemetry-digest allowlist + brackets for [1m])


def clean_model(model_id):
    """ALLOWLIST the model id (anything outside the model-id alphabet becomes
    "?") and cap length before the value reaches stderr or the record. A
    denylist here under-claims: C0/C1 stripping alone still passes bidi
    overrides and zero-width characters to the terminal — the allowlist is
    telemetry-digest.sh's model sanitizer, so both ends of the pipe agree."""
    if not model_id:
        return None
    cleaned = _MODEL_ALLOW_RE.sub("?", model_id)[:MODEL_MAX_CHARS].strip()
    return cleaned if cleaned and cleaned.strip("?") else None


def tier_of(model_id):
    lowered = (model_id or "").lower()
    for family, tier in TIER_MAP:
        if family in lowered:
            return tier
    return "unknown"


def from_stdin(event):
    model = event.get("model")
    if isinstance(model, dict):
        for key in ("id", "display_name"):
            value = model.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    if isinstance(model, str) and model.strip():
        return model.strip()
    return None


def from_transcript(event):
    path = event.get("transcript_path")
    if not isinstance(path, str) or not path:
        return None
    # O_NONBLOCK + fstat on the DESCRIPTOR: a FIFO here is event-supplied
    # (transcript_path comes from stdin), and a bare open() would block
    # SessionStart forever — same class as the 2026-07-30 sink incident.
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        with os.fdopen(fd, "rb") as f:
            fd = -1
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TRANSCRIPT_TAIL_BYTES))
            tail = f.read(TRANSCRIPT_TAIL_BYTES).decode("utf-8", errors="replace")
    except OSError:
        return None
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass
    matches = MODEL_RE.findall(tail)
    return matches[-1] if matches else None


SETTINGS_MAX_BYTES = 262144


def from_settings():
    # Same guarded-open contract as the sink and transcript paths: this env
    # seam is the third trusted-path of the same grade, and a FIFO at the
    # settings path blocked SessionStart forever (security lane, 2026-08-09).
    path = os.environ.get("AGENT_CLAUDE_SETTINGS") or os.path.expanduser(
        "~/.claude/settings.json"
    )
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        with os.fdopen(fd, "rb") as f:
            fd = -1
            raw = f.read(SETTINGS_MAX_BYTES)
        value = json.loads(raw.decode("utf-8", errors="replace")).get("model")
        return value.strip() if isinstance(value, str) and value.strip() else None
    except Exception:
        return None
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass


def resolve_sink():
    """Sink path; an override is confined on its REALPATH to <cwd>/.agent/logs
    or the system temp dir (symlink/`..` escapes fall back to the default) —
    verify-observer.py's resolve_sink contract, including returning the
    RESOLVED path so a post-check symlink swap cannot redirect the open."""
    fallback = os.path.join(os.getcwd(), ".agent", "logs", "session-tier.jsonl")
    override = os.environ.get("AGENT_SESSION_TIER_SINK")
    if not override:
        return fallback
    try:
        candidate = os.path.realpath(override)
        allowed = [
            os.path.realpath(os.path.join(os.getcwd(), ".agent", "logs")),
            os.path.realpath(tempfile.gettempdir()),
        ]
    except OSError:
        return fallback
    for base in allowed:
        if candidate == base or candidate.startswith(base + os.sep):
            return candidate
    return fallback


def append_record(sink, record):
    """Append one JSON line. Never raises, never blocks: O_NONBLOCK open +
    fstat-S_ISREG on the descriptor (a FIFO at the default path would hang
    every SessionStart — verify-observer.py's append_record, 2026-07-30)."""
    try:
        os.makedirs(os.path.dirname(sink), exist_ok=True)
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NONBLOCK", 0)
        fd = os.open(sink, flags, 0o600)
    except Exception:
        return
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fd = -1
            fh.write(json.dumps(record) + "\n")
    except Exception:
        pass
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass


def _session_id(event):
    """String-typed, control-stripped, capped — stdin-supplied like the model."""
    value = event.get("session_id")
    if not isinstance(value, str) or not value:
        value = os.environ.get("AGENT_SESSION_ID", "")
    return _CTRL_RE.sub("", value)[:100]


def main():
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(event, dict):
        return

    model_id, source = None, "none"
    for probe, label in (
        (lambda: from_stdin(event), "stdin"),
        (lambda: from_transcript(event), "transcript"),
        (from_settings, "settings-default"),
    ):
        model_id = probe()
        if model_id:
            source = label
            break

    model_id = clean_model(model_id)
    if not model_id:
        source = "none"
    tier = tier_of(model_id)
    if tier != "unknown":
        note = " (configured default)" if source == "settings-default" else ""
        print(
            f"[model-routing] session={tier} ({model_id}{note}); "
            "execution work classes dispatch at MID/LOW per docs/model-routing.md",
            file=sys.stderr,
        )

    sink = resolve_sink()
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "gate": "session-tier-observer",
        "model": model_id or "",
        "source": source,
        "tier": tier,
        "session_id": _session_id(event),
    }
    append_record(sink, record)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # observer failure must never tax session start
    sys.exit(0)
