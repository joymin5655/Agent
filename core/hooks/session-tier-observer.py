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

Seams: AGENT_SESSION_TIER_SINK (default <cwd>/.agent/logs/session-tier.jsonl),
AGENT_CLAUDE_SETTINGS (default ~/.claude/settings.json), AGENT_SESSION_ID.
Registered in docs/gate-registry.md (GATE session-tier-observer).
"""

import json
import os
import re
import sys
from datetime import datetime, timezone

TIER_MAP = (("fable", "TOP"), ("opus", "TOP"), ("sonnet", "MID"), ("haiku", "LOW"))

TRANSCRIPT_TAIL_BYTES = 65536
MODEL_RE = re.compile(r'"model"\s*:\s*"(claude-[^"]+)"')


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
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TRANSCRIPT_TAIL_BYTES))
            tail = f.read().decode("utf-8", errors="replace")
    except OSError:
        return None
    matches = MODEL_RE.findall(tail)
    return matches[-1] if matches else None


def from_settings():
    path = os.environ.get("AGENT_CLAUDE_SETTINGS") or os.path.expanduser(
        "~/.claude/settings.json"
    )
    try:
        with open(path, encoding="utf-8") as f:
            value = json.load(f).get("model")
        return value.strip() if isinstance(value, str) and value.strip() else None
    except Exception:
        return None


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

    tier = tier_of(model_id)
    if tier != "unknown":
        note = " (configured default)" if source == "settings-default" else ""
        print(
            f"[model-routing] session={tier} ({model_id}{note}); "
            "execution work classes dispatch at MID/LOW per docs/model-routing.md",
            file=sys.stderr,
        )

    sink = os.environ.get("AGENT_SESSION_TIER_SINK") or os.path.join(
        os.getcwd(), ".agent", "logs", "session-tier.jsonl"
    )
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "gate": "session-tier-observer",
        "model": model_id or "",
        "source": source,
        "tier": tier,
        "session_id": event.get("session_id")
        or os.environ.get("AGENT_SESSION_ID", ""),
    }
    os.makedirs(os.path.dirname(sink), exist_ok=True)
    with open(sink, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # observer failure must never tax session start
    sys.exit(0)
