#!/usr/bin/env python3
"""Multi-agent session coordinator — Tier 2 thin Saver/Checkpointer interface.

Backend abstraction over .agent/locks/active-sessions.json + work-feed.jsonl.
Pattern adapted from LangGraph BaseCheckpointSaver. Anthropic Agent Teams
vocabulary (task_state: pending/in_progress/blocked/reviewing/completed). Swarm
Result(...) shape for handoff event payload. Continue-style schema_version on
every event.

Pure stdlib, no external deps. Atomic write via tmp + os.replace + fcntl.flock.

Used by core/infra/agent-session.sh (Tier 2 commands: broadcast, dashboard,
peek, update, tail-feed, subscribe). Backward-compatible with existing JSON
schema (new fields are optional).
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "1.0.0"
TASK_STATES = ("pending", "in_progress", "blocked", "reviewing", "completed")
EVENT_TYPES = (
    "started", "intent", "decision", "committed",
    "pr_opened", "blocked", "handoff", "done",
)
ROTATE_DAYS = 30


def _canonical_root() -> Path:
    """Resolve git common dir to find the canonical repo root (matches
    agent-session.sh resolve_canonical_root). Worktrees and main share one root."""
    try:
        common_dir = subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        if Path(common_dir).name == ".git":
            return Path(common_dir).parent.resolve()
    except subprocess.CalledProcessError:
        pass
    return Path.cwd().resolve()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _omc_tmux_sessions() -> list[str]:
    """Return tmux session names with the OMC team prefix (`omc-team-*`).

    Visibility-only — surfaces oh-my-claudecode tmux workers (third-party tool)
    in the dashboard. Silent fallback to [] when tmux missing or no server running.
    """
    try:
        out = subprocess.run(
            ["tmux", "ls", "-F", "#{session_name}"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=2,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return []
    if out.returncode != 0:
        return []
    return [
        name for name in (out.stdout or "").splitlines()
        if name.startswith("omc-team-")
    ]


class SessionStore:
    """JSON + jsonl backend. Future SQLite/Postgres = swap this class only."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = root or _canonical_root()
        self.lock_dir = self.root / ".agent" / "locks"
        self.lock_file = self.lock_dir / "active-sessions.json"
        self.feed_file = self.lock_dir / "work-feed.jsonl"
        self.archive_dir = self.lock_dir / "archive"
        self.mutex_dir = self.lock_dir / ".mutex.d"
        self.lock_dir.mkdir(parents=True, exist_ok=True)
        self.archive_dir.mkdir(parents=True, exist_ok=True)
        self.mutex_dir.mkdir(parents=True, exist_ok=True)

    # ---------- atomic JSON read/write ----------

    def _read(self) -> dict[str, Any]:
        if not self.lock_file.exists():
            return {"sessions": [], "shared_resource_locks": {}}
        try:
            return json.loads(self.lock_file.read_text())
        except json.JSONDecodeError:
            return {"sessions": [], "shared_resource_locks": {}}

    def _write(self, data: dict[str, Any]) -> None:
        tmp = self.lock_file.with_suffix(".json.tmp")
        with tmp.open("w") as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp, self.lock_file)

    # ---------- session entry API ----------

    def get_session(self, session_id: str) -> dict[str, Any] | None:
        for s in self._read().get("sessions", []):
            if s.get("session_id") == session_id:
                return s
        return None

    def list_active(self) -> list[dict[str, Any]]:
        """Return active session entries with worktree-existence filter applied
        on read. Read-only — does not mutate the lock file."""
        return [
            s for s in self._read().get("sessions", [])
            if Path(s.get("worktree", "")).is_dir()
        ]

    def gc(self) -> int:
        """Drop session entries whose worktree directory no longer exists.
        Returns the number of entries removed.

        Note: PID-dead and heartbeat-stale checks are still performed by
        agent-session.sh::cmd_gc (jq-based, fast). This Python-side gc is
        the worktree-existence layer. The two are complementary — callers
        should run both for full cleanup."""
        data = self._read()
        before = data.get("sessions", [])
        kept = [s for s in before if Path(s.get("worktree", "")).is_dir()]
        removed = len(before) - len(kept)
        if removed > 0:
            data["sessions"] = kept
            self._write(data)
        return removed

    def update_session(self, session_id: str, patch: dict[str, Any]) -> bool:
        """Patch one session entry. Optional Tier 2 fields:
          task_state (pending/in_progress/blocked/reviewing/completed)
          current_intent (str), last_summary (str), last_updated_at (iso)
        Returns True if matched and updated."""
        if "task_state" in patch and patch["task_state"] not in TASK_STATES:
            raise ValueError(f"invalid task_state: {patch['task_state']!r}")
        data = self._read()
        for s in data.get("sessions", []):
            if s.get("session_id") == session_id:
                s.update(patch)
                s["last_updated_at"] = _now_iso()
                self._write(data)
                return True
        return False

    # ---------- resource mutex API ----------

    def claim_resource(self, name: str, owner: str) -> bool:
        data = self._read()
        locks = data.setdefault("shared_resource_locks", {})
        existing = locks.get(name)
        if existing and existing.get("owner") and existing["owner"] != owner:
            return False
        locks[name] = {"owner": owner, "claimed_at": _now_iso()}
        self._write(data)
        return True

    def release_resource(self, name: str) -> None:
        data = self._read()
        data.get("shared_resource_locks", {}).pop(name, None)
        self._write(data)

    # ---------- work feed (append-only jsonl) ----------

    def append_event(self, event: dict[str, Any]) -> None:
        """Append a typed event to work-feed.jsonl. Required: event, session_id.
        Always stamped with schema_version + ts (server-side)."""
        if event.get("event") not in EVENT_TYPES:
            raise ValueError(f"unknown event type: {event.get('event')!r} (expected {EVENT_TYPES})")
        if not event.get("session_id"):
            raise ValueError("session_id is required")
        self.archive_feed_if_due()
        record = {"schema_version": SCHEMA_VERSION, "ts": _now_iso(), **event}
        with self.feed_file.open("a") as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def tail_feed(self, n: int = 20, session_id: str | None = None) -> list[dict[str, Any]]:
        if not self.feed_file.exists():
            return []
        rows: list[dict[str, Any]] = []
        with self.feed_file.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if session_id and row.get("session_id") != session_id:
                    continue
                rows.append(row)
        return rows[-n:]

    def archive_feed_if_due(self) -> bool:
        """Rotate work-feed.jsonl if mtime is at least ROTATE_DAYS old."""
        if not self.feed_file.exists():
            return False
        age_seconds = time.time() - self.feed_file.stat().st_mtime
        if age_seconds < ROTATE_DAYS * 86400:
            return False
        archive_name = f"work-feed-{datetime.now(timezone.utc).strftime('%Y-%m')}.jsonl"
        archive_path = self.archive_dir / archive_name
        if archive_path.exists():
            with self.feed_file.open() as src, archive_path.open("a") as dst:
                fcntl.flock(dst.fileno(), fcntl.LOCK_EX)
                dst.write(src.read())
            self.feed_file.unlink()
        else:
            self.feed_file.rename(archive_path)
        return True

    # ---------- composite views ----------

    def peek(self, session_id: str, n: int = 20) -> dict[str, Any]:
        return {
            "session": self.get_session(session_id),
            "events": self.tail_feed(n=n, session_id=session_id),
        }

    def dashboard(self) -> dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "now": _now_iso(),
            "sessions": self.list_active(),
            "shared_resource_locks": self._read().get("shared_resource_locks", {}),
            "recent_events": self.tail_feed(n=20),
            "omc_tmux_sessions": _omc_tmux_sessions(),
        }

    def dashboard_summary(self) -> str:
        """5-line text summary (token-slim default for SessionStart)."""
        sessions = self.list_active()
        locks = self._read().get("shared_resource_locks", {})
        recent_all = self.tail_feed(n=20)

        cutoff_ts = time.time() - 86400
        last_24h: list[dict[str, Any]] = []
        for ev in recent_all:
            ts_str = ev.get("ts", "")
            try:
                ts_epoch = datetime.strptime(
                    ts_str, "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=timezone.utc).timestamp()
            except (ValueError, TypeError):
                continue
            if ts_epoch >= cutoff_ts:
                last_24h.append(ev)

        sids = [s.get("session_id", "?") for s in sessions]
        sids_show = ", ".join(sids[:3])
        if len(sids) > 3:
            sids_show += f", +{len(sids) - 3} more"
        l1 = f"sessions: {len(sessions)} active ({sids_show or 'none'})"

        lock_names = list(locks.keys())
        lock_show = ", ".join(lock_names[:3])
        if len(lock_names) > 3:
            lock_show += f", +{len(lock_names) - 3} more"
        l2 = f"locks: {len(locks)} shared resources held ({lock_show or 'none'})"

        if last_24h:
            last_ev = last_24h[-1]
            l3 = (
                f"recent: {len(last_24h)} events in last 24h "
                f"(last: {last_ev.get('event', '?')} @ {last_ev.get('ts', '?')})"
            )
        else:
            l3 = "recent: 0 events in last 24h"

        last3 = [ev.get("event", "?") for ev in recent_all[-3:]]
        l4 = f"events: {' -> '.join(last3) if last3 else 'none'} (last 3)"

        oldest_ts: float | None = None
        for s in sessions:
            started = s.get("started_at", "")
            try:
                t = datetime.strptime(
                    started, "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=timezone.utc).timestamp()
            except (ValueError, TypeError):
                continue
            if oldest_ts is None or t < oldest_ts:
                oldest_ts = t
        if oldest_ts is not None:
            age_seconds = max(0, int(time.time() - oldest_ts))
            hours, rem = divmod(age_seconds, 3600)
            minutes, _ = divmod(rem, 60)
            if hours >= 24:
                days, hours = divmod(hours, 24)
                age_str = f"{days}d{hours}h"
            elif hours > 0:
                age_str = f"{hours}h{minutes}m"
            else:
                age_str = f"{minutes}m"
            l5 = f"uptime: oldest active session {age_str}"
        else:
            l5 = "uptime: no active sessions"

        lines = [l1, l2, l3, l4, l5]

        omc = _omc_tmux_sessions()
        if omc:
            shown = ", ".join(omc[:3])
            if len(omc) > 3:
                shown += f", +{len(omc) - 3} more"
            lines.append(f"omc-tmux: {len(omc)} workers ({shown})")

        return "\n".join(lines)


def make_handoff_event(
    *, from_session: str, to_session: str, intent: str,
    context_files: list[str] | None = None, rationale: str = "",
) -> dict[str, Any]:
    """Construct a handoff event payload (Swarm Result(...) shape)."""
    return {
        "event": "handoff",
        "session_id": from_session,
        "to": to_session,
        "intent": intent,
        "context_files": context_files or [],
        "rationale": rationale,
    }


def _print_json(obj: Any) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Tier 2 session store CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_dashboard = sub.add_parser("dashboard")
    p_dashboard.add_argument(
        "--format", choices=("summary", "json"), default="json",
        help="json (default, full payload) | summary (5-line text)",
    )
    sub.add_parser("gc")
    p_peek = sub.add_parser("peek")
    p_peek.add_argument("session_id")
    p_peek.add_argument("--n", type=int, default=20)
    p_tail = sub.add_parser("tail-feed")
    p_tail.add_argument("--n", type=int, default=20)
    p_tail.add_argument("--session-id", default=None)
    p_update = sub.add_parser("update")
    p_update.add_argument("session_id")
    p_update.add_argument("--task-state", default=None)
    p_update.add_argument("--current-intent", default=None)
    p_update.add_argument("--last-summary", default=None)
    p_broadcast = sub.add_parser("broadcast")
    p_broadcast.add_argument("event", choices=EVENT_TYPES)
    p_broadcast.add_argument("message")
    p_broadcast.add_argument("--session-id", required=True)
    p_broadcast.add_argument("--to", default=None)
    p_broadcast.add_argument("--files", default=None, help="comma-separated paths")
    p_broadcast.add_argument("--rationale", default="")
    sub.add_parser("rotate-if-due")

    args = parser.parse_args(argv)
    store = SessionStore()

    if args.cmd == "dashboard":
        if args.format == "json":
            _print_json(store.dashboard())
        else:
            print(store.dashboard_summary())
        return 0
    if args.cmd == "gc":
        removed = store.gc()
        print(f"gc: removed {removed} session(s) with missing worktree dir")
        return 0
    if args.cmd == "peek":
        _print_json(store.peek(args.session_id, n=args.n))
        return 0
    if args.cmd == "tail-feed":
        _print_json(store.tail_feed(n=args.n, session_id=args.session_id))
        return 0
    if args.cmd == "update":
        patch: dict[str, Any] = {}
        if args.task_state:
            patch["task_state"] = args.task_state
        if args.current_intent:
            patch["current_intent"] = args.current_intent
        if args.last_summary:
            patch["last_summary"] = args.last_summary
        if not patch:
            print("update: nothing to patch (provide --task-state / --current-intent / --last-summary)", file=sys.stderr)
            return 2
        ok = store.update_session(args.session_id, patch)
        print("ok" if ok else "session not found", file=sys.stderr if not ok else sys.stdout)
        return 0 if ok else 1
    if args.cmd == "broadcast":
        if args.event == "handoff":
            if not args.to:
                print("handoff event requires --to <session_id>", file=sys.stderr)
                return 2
            event = make_handoff_event(
                from_session=args.session_id, to_session=args.to,
                intent=args.message,
                context_files=args.files.split(",") if args.files else None,
                rationale=args.rationale,
            )
        else:
            event = {"event": args.event, "session_id": args.session_id, "message": args.message}
            if args.to:
                event["to"] = args.to
            if args.files:
                event["files"] = args.files.split(",")
        store.append_event(event)
        return 0
    if args.cmd == "rotate-if-due":
        rotated = store.archive_feed_if_due()
        print("rotated" if rotated else "not-due")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
