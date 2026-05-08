#!/usr/bin/env python3
"""scripts/hooks/sink-threshold-alert.py

Stop * matcher hook. Advisory-only.

Scans .claude/logs/*.jsonl and emits one stderr line per sink that
exceeds the configured threshold. Never blocks. Default threshold is
500 KB (matches AGENT_HARNESS §20.6 jsonl rotation rule and the
airlens-luminous-wind plan W3-B default — the supervisor-routing.jsonl
sink hit ~453 K on 2026-05-06 before W1-B rotated it).

Wire-up: append to .claude/settings.local.json Stop * chain after
session-quality-gate.py / session-daily-summary.py / session-close.sh
/ claude-mem-watch.py.

Action: when this fires, the recommended next step is

    bash scripts/maintenance/log-rotate.sh --apply

which renames sinks > THRESHOLD to ``<name>-YYYY-MM.jsonl`` so the
hook chain creates a fresh empty file on the next event.

Exit code 0 always (advisory). Reads hook JSON from stdin but does not
require it.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
LOGS_DIR = PROJECT_ROOT / ".claude/logs"

# Override via env: SINK_THRESHOLD_KB=200 (or any positive int).
DEFAULT_THRESHOLD_KB = 500


def threshold_bytes() -> int:
    raw = os.environ.get("SINK_THRESHOLD_KB", "").strip()
    try:
        kb = int(raw) if raw else DEFAULT_THRESHOLD_KB
    except ValueError:
        kb = DEFAULT_THRESHOLD_KB
    return max(1, kb) * 1024


def is_rotated_name(name: str) -> bool:
    # Skip files like supervisor-routing-2026-05.jsonl — already archived.
    return name.endswith(".jsonl") and "-20" in name and name.count("-") >= 3


def main() -> int:
    # Drain stdin so the hook protocol stays clean. Body is unused.
    try:
        sys.stdin.read()
    except Exception:
        pass

    if not LOGS_DIR.is_dir():
        return 0

    limit = threshold_bytes()
    breaches = []

    try:
        for path in sorted(LOGS_DIR.glob("*.jsonl")):
            if is_rotated_name(path.name):
                continue
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if size > limit:
                breaches.append((path.name, size))
    except OSError:
        return 0

    if not breaches:
        return 0

    sys.stderr.write(
        f"sink-threshold-alert: {len(breaches)} sink(s) > {limit // 1024}K — "
        "consider `bash scripts/maintenance/log-rotate.sh --apply`\n"
    )
    for name, size in breaches:
        sys.stderr.write(f"  {name}\t{size // 1024}K\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
