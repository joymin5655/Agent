# Tier 2 Multi-Agent Coordination Contract

Coordination primitives shared by `agent-session.sh` + `session_store.py`. Mirrors rules R11-R13 from `rules/multi-agent-worktree.md`. New contributors should read this file to understand the cross-session work-feed primitives.

---

## R11 — SessionStart dashboard (SHOULD)

The `SessionStart` hook (`core/hooks/agent-session-start.sh`) automatically emits a `additionalContext` JSON containing the `agent-session.sh dashboard` summary before the session takes its first action. The AI sees:

- Other active sessions (with task slug, age, branch)
- Last 20 work-feed events
- Shared resource locks

Silent failure: hook tolerates absence of `session_store.py` so it never blocks session start.

---

## R12 — Decision broadcast (SHOULD)

Call `agent-session.sh broadcast <event> "<message>"` at meaningful moments:

| Event | When |
|---|---|
| `started` | Hook auto-fires on SessionStart |
| `intent` | First user prompt after start (optional, hook-eligible) |
| `decision` | Option-fork decisions, new plan written, dependency added |
| `committed` | After git commit — pass `--files <comma list>` |
| `pr_opened` | After `gh pr create` |
| `blocked` | See R13 (MUST) |
| `handoff` | Passing work to another session |
| `done` | Hook auto-fires on Stop |

Each event appended to `.agent/locks/work-feed.jsonl` with stamped `schema_version: "1.0.0"` and `ts`. 30-day rotate to `.agent/locks/archive/work-feed-YYYY-MM.jsonl`.

---

## R13 — Blocked broadcast (MUST)

When a session cannot proceed because:
- Another session must finish work first → emit `handoff`
- User decision is pending while a peer session is touching the same area → emit `blocked` with `--to <peer-session-id>`
- R4 / R4.1 mutex collision → emit `blocked` with the conflict reason

Use `handoff` for typed transfer, `blocked` for "I'm stuck and waiting".

### Handoff payload (Swarm `Result(...)` shape)

```json
{
  "schema_version": "1.0.0",
  "ts": "2026-05-07T01:39:19Z",
  "event": "handoff",
  "session_id": "claude-wt-foo",
  "to": "codex-wt-bar",
  "intent": "continue PR #X — refactor needed",
  "context_files": ["a.tsx", "b.tsx"],
  "rationale": "I burned context budget; codex resumes from these files"
}
```

Receiving session's SessionStart dashboard surfaces `to == self` events. A subscriber daemon can auto-inject the intent + context_files into the next prompt.

---

## Anthropic Agent Teams vocabulary alignment

`task_state` enum on session entries matches Anthropic Claude Code 2.1+ Agent Teams (experimental) primitives:

| Framework `task_state` | Anthropic Agent Teams |
|---|---|
| `pending` | task pending |
| `in_progress` | task being worked on |
| `blocked` | (extension) |
| `reviewing` | (extension — code review) |
| `completed` | task done |

The R4 mutex + `agent-session.sh claim/release` is the same primitive as Anthropic Agent Teams' file-locked task claim. Vocabulary aligned so contributors reading the official Anthropic docs immediately understand the infrastructure.

---

## CLI quick reference

```bash
# Surface state
agent-session.sh dashboard                          # all active + recent feed (JSON)
agent-session.sh peek <session_id> [n]              # one session + its events
agent-session.sh tail-feed [--n N] [--session <id>] # last N events, filterable

# Mutate self
agent-session.sh broadcast <event> "<message>" \
    [--to <sid>] [--files f1,f2] [--rationale <msg>]
agent-session.sh update --task-state <state> \
    [--current-intent <s>] [--last-summary <s>]

# Subscriber daemons (user-supplied)
agent-session.sh subscribe                          # list available
agent-session.sh subscribe <name>                   # launch in background
```

---

## Backend

`session_store.py` is the single backend. `agent-session.sh` (bash) wraps it for CLI ergonomics. Backend is currently JSON-on-disk (`.agent/locks/active-sessions.json` + work-feed jsonl). Future SQLite/Postgres swap = replace the `SessionStore` class only — CLI and contract unchanged. Pattern follows LangGraph `BaseCheckpointSaver`.
