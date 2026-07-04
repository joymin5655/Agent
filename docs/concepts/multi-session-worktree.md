# Concept — Multi-Session Worktree Coordination

When you run multiple AI sessions on the same repo (Claude in one terminal, Codex in another, Gemini in a third), they collide unless they coordinate.

The framework provides 14 rules (R1-R14) for safe coordination, enforced through `core/infra/agent-session.sh` + lock files + hooks.

See [`../../rules/multi-agent-worktree.md`](../../rules/multi-agent-worktree.md) for the canonical rule list.

---

## Quick summary

```
R1   — Each session creates a git worktree under .worktrees/<agent>-<slug>/
R1.1 — Read-only work CAN happen on shared main checkout
R2   — Sessions register themselves in .agent/locks/active-sessions.json
R3   — Heartbeat every 5 min; stale sessions auto-GC'd
R4   — Shared resources (production DB, deploy, etc.) require explicit `claim`
R4.1 — Code file mutex — another session editing a file → ask before overlapping
R5   — PR/merge serialized via human; no auto-merge for shared branches
R5.1 — Opt-in --auto-merge for single-session workflows (with safeguards)
R6   — Never push to / force-push to / branch -D another agent's branch
R7   — Standard session lifecycle: start → work → broadcast → stop
R8   — User can override R1 (shared-tree) explicitly
R9   — Optional node_modules / .venv symlink sharing (heavy deps)
R10  — Never use /tmp for untracked file backup (use git stash / safe-stash.sh)
R11  — SessionStart dashboard surfaces other active sessions
R12  — Broadcast meaningful decisions to work-feed
R13  — Broadcast "blocked" event when handing off
R14  — 5-deferral safe workflow (advanced)
```

---

## Why this matters

Two scenarios where coordination is critical:

### Scenario 1: Same file, two AIs

Claude in Worktree A edits `src/components/Foo.tsx`. Codex in Worktree B (different branch) also edits `Foo.tsx`. Both commit. Merge → conflict.

**R4.1 protection**: When Codex starts editing `Foo.tsx`, the file-mutex hook sees Claude has touched it in the last hour → returns `ask`. Codex prompts user: "Claude is editing this file in `claude/feat-foo`. Continue anyway?"

### Scenario 2: Same DB, two AIs

Both AIs try to run `supabase db push` at the same time. One succeeds, one fails mid-migration → broken schema.

**R4 protection**: `r4-mutex-check.sh` hook on PreToolUse → first session claims `production-db` resource → second session sees the claim and gets `deny` until first releases or 1 hour timeout.

---

## How to enable

1. Run `bash ~/agent/setup.sh --claude` (or all 3 AIs).
2. At session start: `bash core/infra/agent-session.sh start <task-slug>`
3. Coordination hooks fire automatically thereafter.

---

## When you DON'T need this

If you only ever run one AI session at a time, you don't need most of these rules. The framework still works — hooks are no-ops when only one session exists.

But the discipline of `start` / `dashboard` / `stop` is still useful for:
- Tracking which task each session is on
- Telemetry / time-tracking
- Audit trail in `.agent/logs/`

---

## See also

- [`../../rules/multi-agent-worktree.md`](../../rules/multi-agent-worktree.md) — full rule definitions
- [`../../core/infra/agent-session.sh`](../../core/infra/agent-session.sh) — the implementation
- [`../../core/infra/TIER-2-COORD-CONTRACT.md`](../../core/infra/TIER-2-COORD-CONTRACT.md) — extended Tier 2 protocol (broadcast events)
