# Concept — Memory Discipline

When an AI is told to "remember" something or asked "do you remember X?", the answer should come from the **persistent memory file system**, not from speculation.

See [`../../rules/memory-discipline.md`](../../rules/memory-discipline.md) for the canonical R1-R5 rules.

---

## Three memory systems coexist

| System | Purpose | Lifetime | Authority |
|---|---|---|---|
| AI session context | Current conversation | Until session ends | What's in the chat window |
| File-based memory | User profile, project state, decisions, references | Across sessions | `~/.<ai>/projects/<repo>/memory/` |
| External plug-in memory (Claude-Mem, etc.) | Auto-captured session debugging context | Across sessions | Plug-in's SQLite or vector store |

The framework treats **file-based memory** as the authoritative SoT for facts. Plug-in memory is for retrieval-augmented context only — never edits user decisions.

---

## R1-R5 (canonical, summarized)

- **R1** — When user mentions a topic that might be in memory, READ the memory file BEFORE responding. Don't speculate.
- **R2** — Index entries (1-line summaries) are NOT the source of truth. The file body is.
- **R3** — If you find yourself writing "might be a fake variable" / "probably not real" / "I think it's..." → STOP and read the memory file. The answer is likely already there.
- **R4** — User-decision memory (`feedback_*` / `project_*`) is locked-in. The AI must not declare these "invalid" or "outdated" without re-reading the body and checking the conditions.
- **R5** — If memory index and body conflict, the BODY wins. Report the inconsistency to the user.

---

## File layout (recommended)

```
~/.<ai>/projects/<repo-name>/memory/
├── MEMORY.md                      # index (1-line per file)
├── user_role.md                   # user profile
├── feedback_<topic>.md            # user-stated preferences / corrections
├── project_<topic>.md             # project state, decisions, dates
└── reference_<topic>.md           # external resource pointers
```

---

## What memory is NOT for

The auto-capture plug-ins (Claude-Mem, etc.) are tempting but dangerous when they auto-edit user-facing files:

- **Don't** let auto-memory edit `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, or project docs.
- **Do** let it append to its own private store (`~/.claude/auto-mem/...`) for retrieval.

---

## Why this matters

A 2026-05 incident in another project:
- User asked "why doesn't this env var work?"
- AI read MEMORY.md index summary → speculated "probably fake variable"
- The body file explicitly stated "restart required after change"
- Result: user spent 20 min debugging a phantom bug

The fix: hooks + discipline. R1 (read body before responding) catches this.

---

## See also

- [`../../rules/memory-discipline.md`](../../rules/memory-discipline.md) — R1-R5 canonical
- [`../../rules/policy/subagent-memory-policy.md`](../../rules/policy/subagent-memory-policy.md) — subagent memory scoping
