#!/usr/bin/env python3
"""AirLens — Stop hook for policy/canonical-13 drift observability.

Logs structural drift signals between rule docs and live config to
.claude/logs/policy-drift-watch.jsonl on every Stop event.

Watched signals (T+30d analysis target):
  1. external-plugin-policy.md §4 hook count claim vs ~/.claude/settings.json actual
  2. multi-agent-worktree.md §R7.1 PreToolUse Write|Edit chain length claim vs .claude/settings.local.json actual
  3. mcp-status.md claimed enabled servers vs .claude/settings.local.json enabledMcpjsonServers
  4. .claude/skills/ count + .claude/rules/ count + scripts/hooks/ count snapshot
  5. Each canonical-13 / each rule sha256 + mtime (hash drift indicator)

Silent observability — no alert, no block. T+30d (per matt-pocock-skills.md +
external-plugin-policy.md §5) the jsonl is analyzed for drift events that
warrant rule §History updates.

Refs:
  - Plan: ~/.claude/plans/wondrous-sprouting-riddle.md (P3)
  - Pattern: scripts/hooks/claude-mem-watch.py (silent jsonl + sha256)
  - Drift case study: external-plugin-policy.md §4 claimed 0 / actual 9 (2026-05-06 fix)
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import time
from pathlib import Path
from typing import Optional, Tuple

PROJECT_ROOT = Path(__file__).resolve().parents[2]
LOG_PATH = PROJECT_ROOT / ".claude/logs/policy-drift-watch.jsonl"

LOCAL_SETTINGS = PROJECT_ROOT / ".claude/settings.local.json"
GLOBAL_SETTINGS = Path.home() / ".claude/settings.json"

WATCHED_RULES = [
    # Tier 1 — top-level (auto-loaded into every CLAUDE.md context)
    ".claude/rules/external-plugin-policy.md",
    ".claude/rules/multi-agent-worktree.md",
    ".claude/rules/public-repo.md",
    ".claude/rules/contributing.md",
    # Tier 2 — policy/ subdir (load on demand, moved 2026-05-06)
    ".claude/rules/policy/matt-pocock-skills.md",
    ".claude/rules/policy/firecrawl-policy.md",
    ".claude/rules/policy/notion-external-share.md",
    ".claude/rules/policy/magic-21st-policy.md",
    ".claude/rules/policy/sequential-thinking-routing.md",
    ".claude/rules/policy/hugging-face-research.md",
    ".claude/rules/policy/plan-first-clarifying.md",
]

CANONICAL_13 = [
    "CLAUDE.md",
    "apps/web/CLAUDE.md",
    "apps/app/CLAUDE.md",
    "models/CLAUDE.md",
    "Obsidian-airlens/raw/docs/platform/PLATFORM_PRD.md",
    "Obsidian-airlens/raw/docs/platform/PLATFORM_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/web/WEB_PRD.md",
    "Obsidian-airlens/raw/docs/web/WEB_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/app/APP_PRD.md",
    "Obsidian-airlens/raw/docs/app/APP_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/ml/MODELS_PRD.md",
    "Obsidian-airlens/raw/docs/ml/MODELS_ARCHITECTURE.md",
    "Obsidian-airlens/raw/docs/db/DATABASE_SCHEMA.md",
    "Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md",
]


def measure(path: Path) -> dict:
    if not path.is_file():
        return {"path": str(path), "mtime": None, "hash": None}
    try:
        st = path.stat()
        h = hashlib.sha256(path.read_bytes()).hexdigest()[:8]
        return {"path": str(path), "mtime": int(st.st_mtime), "hash": h}
    except (OSError, PermissionError):
        return {"path": str(path), "mtime": None, "hash": None}


def count_hooks(settings_json: dict) -> dict:
    out = {}  # type: dict
    for event, blocks in settings_json.get("hooks", {}).items():
        n = 0
        for blk in blocks:
            n += len(blk.get("hooks", []))
        out[event] = n
    return out


def write_edit_chain_length(settings_json: dict) -> int:
    n = 0
    for blk in settings_json.get("hooks", {}).get("PreToolUse", []):
        if blk.get("matcher") in ("Write|Edit", "Edit"):
            n += len(blk.get("hooks", []))
    return n


def claimed_global_total(rule_text: str) -> Optional[int]:
    """Parse external-plugin-policy.md §4 '합계 글로벌' line claim."""
    m = re.search(r"합계 글로벌\s*\|.*?\|\s*\*\*?(\d+)\*?\*", rule_text)
    if m:
        return int(m.group(1))
    m = re.search(r"settings\.json[^|]*\|\s*\*?\*?(\d+)\*?\*?\s+\(\d+\s*GSD", rule_text)
    return int(m.group(1)) if m else None


def claimed_write_edit_stack(rule_text: str) -> Optional[int]:
    """Parse multi-agent-worktree.md §R7.1 Write|Edit stack length."""
    m = re.search(r"PreToolUse\s*`Write\|Edit`\s*(\d+)-stack", rule_text)
    return int(m.group(1)) if m else None


def safe_load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def safe_read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def main() -> None:
    session_id = "unknown"
    try:
        raw = sys.stdin.read()
        if raw.strip():
            ctx = json.loads(raw)
            session_id = ctx.get("session_id") or ctx.get("sessionId") or "unknown"
    except (json.JSONDecodeError, ValueError):
        pass

    local_cfg = safe_load_json(LOCAL_SETTINGS)
    global_cfg = safe_load_json(GLOBAL_SETTINGS)

    local_counts = count_hooks(local_cfg)
    global_counts = count_hooks(global_cfg)
    we_chain_actual = write_edit_chain_length(local_cfg)

    epp_text = safe_read_text(PROJECT_ROOT / ".claude/rules/external-plugin-policy.md")
    maw_text = safe_read_text(PROJECT_ROOT / ".claude/rules/multi-agent-worktree.md")

    global_claim = claimed_global_total(epp_text)
    we_claim = claimed_write_edit_stack(maw_text)

    enabled_mcp = local_cfg.get("enabledMcpjsonServers", [])

    skills_dir = PROJECT_ROOT / ".claude/skills"
    rules_dir = PROJECT_ROOT / ".claude/rules"
    hooks_dir = PROJECT_ROOT / "scripts/hooks"

    def count_dir(p: Path, suffix: Optional[Tuple[str, ...]] = None, recursive: bool = False) -> int:
        if not p.is_dir():
            return 0
        if suffix:
            it = p.rglob("*") if recursive else p.iterdir()
            return sum(1 for f in it if f.is_file() and f.name.endswith(suffix))
        return sum(1 for f in p.iterdir() if f.is_dir() and not f.name.startswith("."))

    drift_signals = {
        "global_hook_total_actual": sum(global_counts.values()),
        "global_hook_total_claim": global_claim,
        "global_hook_drift": (
            None if global_claim is None
            else sum(global_counts.values()) - global_claim
        ),
        "write_edit_chain_actual": we_chain_actual,
        "write_edit_chain_claim": we_claim,
        "write_edit_chain_drift": (
            None if we_claim is None
            else we_chain_actual - we_claim
        ),
    }

    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "session_id": session_id,
        "local_hook_counts": local_counts,
        "global_hook_counts": global_counts,
        "drift_signals": drift_signals,
        "enabled_mcp_servers": enabled_mcp,
        "asset_counts": {
            "skills": count_dir(skills_dir),
            "rules": count_dir(rules_dir, suffix=(".md",), recursive=True),
            "hooks": count_dir(hooks_dir, suffix=(".sh", ".py")),
        },
        "rule_files": [measure(PROJECT_ROOT / r) for r in WATCHED_RULES],
        "canonical_13": [measure(PROJECT_ROOT / c) for c in CANONICAL_13],
    }

    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except (OSError, PermissionError) as exc:
        sys.stderr.write(f"policy-drift-watch: log write failed: {exc}\n")

    print(json.dumps({"continue": True, "suppressOutput": True}))


if __name__ == "__main__":
    main()
