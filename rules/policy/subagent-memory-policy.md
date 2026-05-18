# Subagent Memory Policy

When using subagents (Anthropic SDK 2.1+, Claude Code Agent tool), each
agent can have its own memory scope. This policy defines where each
scope's memory lives and how the three layers interact.

## Three memory layers

| Layer | Lifetime | Scope | Stored where |
|---|---|---|---|
| **L1 — Session** | Until session ends | One conversation | In-context only |
| **L2 — Project** | Persistent | One repo / one team | `memory/` in the project |
| **L3 — User** | Persistent | One user across projects | `~/.agent/memory/` (or platform-specific) |

## Subagent scopes

Three subagent memory scopes:

| Scope | Lifetime | Visible to | Default |
|---|---|---|---|
| `user` | Persistent | Same user, all projects | OFF — explicit opt-in. |
| `project` | Persistent | Same project, all sessions | OFF — explicit opt-in. |
| `local` | One session | The subagent that wrote it | **Default**. |

`local` is gitignored by design — subagent scratchpads should not
pollute the project history.

## Frontmatter

Subagent SKILL.md / agent-definition frontmatter declares the scope:

```markdown
---
name: my-subagent
description: …
memory:
  scope: local           # or "project" or "user"
  path: .agent/memory-local/<name>/   # only meaningful for non-local
---
```

## Three memory systems (do NOT duplicate state)

Different stores have different roles. Never write the same fact to
multiple stores:

| System | Role | Example |
|---|---|---|
| `MEMORY.md` + `memory/` | **User decisions / feedback / project state** (manual promotion) | "User prefers terse responses." |
| Auto-capture vector DB (claude-mem, etc.) | **Session-level debugging context / code patterns** (auto, read-only search) | "On 2026-05-12 the X bug was caused by Y." |
| Plan / TodoWrite | **Current-conversation state** (ephemeral) | "Wave 3 of 5 in progress." |

If a third-party plug-in auto-edits files in protected paths (your
`memory/`, `rules/`, etc.), **disable that feature** or restrict it
to plug-in-only paths (`.agent/notes/<plugin>/`).

## Default = `local`

The framework default is `memory.scope: local`. This means:

- Subagent scratchpads land in `.agent/memory-local/<agent>/` (gitignored).
- No accidental cross-project leakage.
- No PR-review surprise from auto-edited memory files.

Promote to `project` or `user` scope **only when** the memory has
durable value beyond one session — e.g., a learned pattern that
applies to future work.
