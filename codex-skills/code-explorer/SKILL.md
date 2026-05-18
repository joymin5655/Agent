---
name: code-explorer
description: Survey a codebase area before changing it. Maps file tree, traces dependencies, identifies idioms.
when_to_use: User asks "where is X" or "how does Y work" or before any non-trivial change.
---

# code-explorer

## Goal

Build a small, accurate mental model of a codebase area before touching
it. Don't modify anything — this skill is read-only.

## Process

1. **Top-down**: read directory listing, identify the entry point
   (`main.*`, `index.*`, `app.*`).
2. **Trace** from the entry point: follow imports two or three hops
   deep, noting which files are infrastructure vs business logic.
3. **Read 2-3 sibling files** to learn the codebase's idioms — error
   handling style, naming conventions, test layout.
4. **Find the test for the area** — tests document expected behavior
   better than comments.
5. **Identify constraints** — read any `rules/`, `docs/`, or top-level
   `CLAUDE.md`/`AGENTS.md` that affect this area.

## Output

```
Area: <path>
Entry point: <file>:<symbol>
Key files:
  <file>: <one-line role>
  …
Idioms observed:
  - <pattern>
  - <pattern>
Tests:
  <path> — covers <what>
Constraints:
  - <rule or doc>
Open questions (for the user):
  - <…>
```

## Don't

- Don't read more than ~15 files. If you need more, the question is
  too broad — narrow with the user first.
- Don't write code.
- Don't speculate about behavior you haven't read.
