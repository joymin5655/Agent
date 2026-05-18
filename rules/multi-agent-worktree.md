# Multi-Session Worktree Coordination

Rules for running multiple AI sessions (Claude / Codex / Gemini, or
multiple instances of one) against the same repo without conflict.

## R1 — Worktree isolation (MUST)

- The main checkout is the **integration baseline** — read-only for
  long-running sessions, write only for merging PRs.
- Each session creates a fresh worktree: `.worktrees/<agent>-<task-slug>/`.
- Branch naming: `<agent>/<task-slug>` (e.g., `claude/feat-auth`,
  `codex/refactor-db`, `gemini/docs-update`).
- Override: `--shared-tree` or user says "work in main" — see R8.

### R1.1 — Read-only ops can use shared-tree

The R1 enforcement applies to **code-modifying** work. Read-only
operations (grep, file reads, audit) are more efficient in the main
checkout because each worktree startup loads ~46k tokens of context.

| Operation | Recommended |
|---|---|
| File reads / grep / code search | shared-tree |
| Audit / status / doc reads | shared-tree |
| Simple Q&A from memory | shared-tree |
| Write/Edit | worktree |
| PR / push / commit | worktree |
| Merge / deploy / migrate | worktree + R4 mutex |

**Heuristic**: if `git diff --stat` will be empty at the end, shared-tree.
Otherwise, worktree.

Entering shared-tree mode requires an **explicit user signal** —
`--shared-tree` or "work in main". The AI doesn't decide unilaterally.

## R2 — Session lock registration (MUST)

- `.agent/locks/active-sessions.json` (gitignored).
- On session start, append an entry; on stop, remove it.
- Atomic write: temp file → `mv` rename → `flock`.
- Helper: `bash core/infra/agent-session.sh start <task-slug>`.

## R3 — Heartbeat & stale GC (SHOULD)

- Active sessions refresh `heartbeat_at` every 5 min via
  `core/infra/agent-session.sh heartbeat`.
- On next session start, GC removes entries where PID is dead or
  `now - heartbeat_at > 30min`.
- Manual: `core/infra/agent-session.sh gc`.

## R4 — Shared-resource mutex (MUST)

Resources that can only be touched by one session at a time:

- Production database migration apply (`production-db`)
- Production deploy (`production-deploy`)
- Serverless function deploy (`edge-function-deploy`)
- Payment-system live calls (`payment-live`)

Resource patterns are configurable via `hook-config.yml` —
see `docs/customization.md`.

Manual:
```bash
core/infra/agent-session.sh claim <resource>      # must succeed
# ... do the work ...
core/infra/agent-session.sh release <resource>    # 1h auto-expire
```

Automatic (PreToolUse hook): `core/hooks/r4-mutex-check.sh` maps known
tool calls to resources and returns `permissionDecision="ask"` when
another session owns the lock.

### R4.1 — File-level mutex

In addition to resource mutex, code files in flight are tracked.
`core/hooks/r4-file-mutex-check.sh` emits
`permissionDecision="ask"` when a Write/Edit targets a file that
another active session has touched in the last N minutes.

## R5 — PR / merge serialisation (MUST)

- Each session does its own push + PR creation.
- Merging to `main` is **serialised by a human**.
- After merge, other sessions rebase: `git fetch && git rebase origin/main`.

### R5.1 — `--auto-merge` opt-in

User can delegate the push → CI watch → admin merge → main pull chain
to `core/infra/auto-ship.sh` *per PR* with explicit invocation
keywords:

- `/wrap --auto-merge`
- `/supervise <plan> --auto-merge`
- "admin merge" or "proceed all the way to merge"

The script aborts automatically on any risk-area violation
(`docs/customization.md §risk_areas`).

## R6 — Don't touch other agents' branches (MUST NOT)

A session running under one AI must not push to / force-push / delete
another AI's branch (`<other-agent>/*`). User must explicitly authorise
any cross-agent intervention.

## R7 — Session start procedure

Manual:
```bash
export AGENT=claude   # or codex / gemini

core/infra/agent-session.sh list                  # show active sessions
core/infra/agent-session.sh gc                    # remove stale entries
core/infra/agent-session.sh start feat-auth-mfa   # creates worktree + lock
cd .worktrees/claude-feat-auth-mfa

# ... work ...

core/infra/agent-session.sh stop                  # release lock
```

Wrapper-based (preferred):
```bash
core/infra/claude-session.sh feat-auth-mfa       # claude
core/infra/codex-session.sh refactor-models      # codex
core/infra/gemini-session.sh docs-update          # gemini
```

These wrap the AI binary, register the session, run a 5-min heartbeat
loop, and clean up on exit.

## R8 — User-explicit override

The user can override R1 with `--shared-tree` or an explicit phrase.
R2 (lock registration) and R4 (resource mutex) still apply.

## R9 — Heavy-dep sharing (opt-in)

Re-installing `node_modules` / `.venv` in every worktree wastes disk
and time. When you know branches share the same lockfile state, opt
in to symlinks:

```bash
cd .worktrees/claude-feat-auth-mfa
core/infra/worktree-link-deps.sh
```

Override targets via `AGENT_LINK_DIRS` env var (see script header).
Don't install in main and worktree simultaneously.

## R10 — Untracked file protection

Don't `mv` untracked files to `/tmp` during rebase/merge — system
cleanup deletes them. Use:

1. `git stash --include-untracked --message "<reason>"` — git-internal, persistent.
2. `core/infra/safe-stash.sh save <slug>` — snapshot to `~/.agent/backup/`,
   prune with `safe-stash.sh prune 30`.

## R11 — SessionStart dashboard (SHOULD)

`core/hooks/agent-session-start.sh` runs at session start and emits a
dashboard JSON: other active sessions, recent work-feed events, current
locks. Silent failure if `session_store.py` is missing.

### R11.1 — Main-tree session visibility

Sessions running in the main checkout (R1.1 read-only or R8 override)
also register so the dashboard shows them. session_id is stable per
binary PID: `<agent>-main-<pid>`.

## R12 — Decision broadcasts (SHOULD)

Call `core/infra/agent-session.sh broadcast <event> "<msg>"` at
meaningful moments:

| Event | When |
|---|---|
| `started` | New worktree / session beginning. |
| `intent` | User clarifies what they want. |
| `decision` | Option-fork choice, new plan, dep added. |
| `committed` | After `git commit` — pass `--files <list>`. |
| `pr_opened` | After `gh pr create`. |
| `blocked` | See R13. |
| `handoff` | Passing work to another session. |
| `done` | Wave / task complete (Stop hook auto-fires). |

Events append to `.agent/locks/work-feed.jsonl` (30-day rotation).

## R13 — Blocked broadcast (MUST)

When you cannot proceed because:

- Another session must finish first → emit `handoff`.
- User decision pending while a peer session is touching the same area → emit `blocked` with `--to <peer>`.
- R4 / R4.1 mutex collision → emit `blocked` with the conflict reason.

Use `handoff` for typed transfer, `blocked` for "I'm stuck and waiting".

## R14 — Deferred-item workflow

When deferring an item ("revisit after T+30d", "needs separate plan"),
record it in the plan's "Open Items" section with a trigger condition.
Don't silently drop it.
