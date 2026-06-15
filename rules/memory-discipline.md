# Memory Discipline — Index ≠ SOT

## Purpose

Index lines (`MEMORY.md` one-liners) are *pointers*. The body file under
`memory/<topic>.md` is the source of truth. Reading only the index and
then *guessing* at the rest violates this rule.

The pattern this prevents: AI sees a one-line summary, infers a meaning,
declares a user-set config "probably fake" or "doesn't work", when the
body clearly states the actual condition (e.g., "needs restart to
activate"). User loses trust; rework follows.

## Rules

### R1 — Keyword match → read the body

When the user's question contains any of these signals, **read the
relevant memory body file before answering**:

| Category | Keywords |
|---|---|
| Config / setup | "why isn't this working", "fails", "doesn't trigger", "error" |
| Past decisions | "we decided", "I remember", "last time", "already set" |
| Token / cost | "context size", "memory usage", "compact", "budget" |
| Policy / rules | "rule", "policy", "risk areas", "mutex", "guard" |
| Skills / agents | "plug-in", "skill conflict", "agent routing", "same-name skill" |

### R2 — Index is not SOT

The one-line summary in `MEMORY.md` says *which file* has the answer.
The body file has **Why / How to apply / Related** — that's the
decision-grade content.

### R3 — Hedge language → read the body

If your response is about to contain any of these, **stop and read the body**:

- "probably …"
- "might be …"
- "I think …"
- "not an official variable" / "fake"
- "not sure but …"

The body usually has the actual answer.

### R4 — User decisions are not "fake"

`feedback_*` and `project_*` memory entries are decisions the user has
already made. Don't override them with speculation. If something looks
inconsistent, read the body for *conditions* (e.g., "needs restart",
"after T+7d measurement", "triggers separate plan") — unmet conditions
mean the rule is *dormant*, not *invalid*.

### R5 — Index can lag the body

The one-liner may not be updated the moment the body is. On conflict,
**trust the body**. Report the lag to the user so they can sync the
index.

## Anti-patterns

- Reading the index, then immediately speculating in the response.
- "I've seen this in memory" — citing without verifying the body.
- Overriding a user's recorded decision because the index summary felt
  ambiguous.
- Treating `MEMORY.md` as authoritative when its truncation warning is
  visible ("only part loaded").

## Working pattern

```
User: "Why isn't X working?"
  ↓
AI:  1. grep MEMORY.md for keywords → identify memory/X.md
     2. Read memory/X.md body → absorb Why + How to apply + Related
     3. Verify the body's *conditions* (restart? T+N? trigger?)
     4. If conditions unmet → report dormant state
     5. If body silent on the point → speculate explicitly: "Body
        doesn't cover this — guess: …"
```

## Related

- `MEMORY.md` — the index (one-line summaries)
- `memory/<topic>.md` — body files (decision-grade content)
- `rules/OVERVIEW.md` — index for this rule
