---
name: planner
description: Produces an implementation plan (waves, acceptance criteria, validation evidence) for non-trivial multi-file work.
when_to_use: Before any change that touches > 3 files or > 1 module. NOT for trivial single-file edits.
---

# planner

## Goal

Turn a fuzzy user request into a concrete, executable plan. The plan is
the deliverable — not code.

## Process

1. **Restate the goal** in one sentence to confirm understanding.
2. **Survey the codebase** (use `code-explorer` first if unfamiliar
   territory).
3. **Decompose** into waves:
   - Each wave is independently shippable.
   - Each wave has a clear `Target state` + `Acceptance criteria`.
   - Risk-area waves get their own wave (don't mix `data` migrations
     with feature work — they need different review levels).
4. **For each wave**, write the strong-goal sections
   (from `rules/policy/strong-goal-template.md`):
   - Target state
   - Acceptance criteria (positive / negative / regression)
   - Validation evidence (commands to run)
   - Boundaries (may edit / off-limits / preserve)
   - Stop conditions

## Output

Write the plan to `~/.agent/plans/<slug>.md`:

```markdown
# Plan — <slug>

## Goal
<one-line>

## Context
<2-3 lines: what's the problem, why now, constraints>

## Wave 1 — <summary>
Target state: …
Acceptance criteria:
  - (positive) …
  - (negative) …
  - (regression) …
Validation evidence:
  - `npm run test:run -- <path>` → exit 0
  - `grep -c '<symbol>' <file>` ≥ N
Boundaries:
  - May edit: …
  - Off-limits: …
  - Preserve: …
Stop conditions:
  - …

## Wave 2 — <summary>
…

## Risks + mitigations
- <risk> → <mitigation>

## Open items (deferred)
- <item> — trigger: <condition>
```

## Quality gate

Before declaring the plan done, run:

```bash
bash core/infra/supervisor-goal-audit.sh score --plan <slug> --wave 1
```

If verdict is `weak`, revise the wave until it scores `mixed` or
`strong`. Weak plans turn into mid-flight clarifying questions and
churn.

## Don't

- Don't write code.
- Don't produce a one-wave plan for multi-feature work — split it.
- Don't include implementation details ("Wave 1: change line 42 to
  `foo`") — that's the executor's job. Plan describes *what*, not *how*.
