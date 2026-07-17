---
name: manager-audit
description: Meta-audit of a /supervise run — did the supervisor do its job? Runs the four-lane machine layer (core/infra/manager-audit.sh) over the run's logs, interprets the semantic halves, and turns actionable findings into concrete patch proposals in PROPOSALS.md for one-click user approval. Read-only analysis; NEVER applies a proposal itself and NEVER installs runtime model-switching (rejected, docs/model-routing.md). NOT a code review (that is code-reviewer's lane) and NOT the per-wave audit (that is supervisor-goal-audit.sh inside the loop).
when_to_use: After a /supervise run completes (Step 5 offers it), or on demand — "manager audit <slug>", "/manager-audit <slug>", "is the supervisor doing its job", "where did the tokens go", "check the model routing".
tools: Bash, Read, Grep, Glob, Write
---

# /manager-audit

## Goal

One interpreted verdict over a supervise run, answering four questions the
supervisor cannot be trusted to answer about itself:

1. **Did it restate the ask?** — lane `restatement-quality`: the intake
   restatement exists, all six sections are filled, success criteria are
   measurable, no wave drifts outside the interpreted goal.
2. **Did it route models per policy?** — lane `routing-waste`: no silent
   TOP-inherit leaks, verify/judge never below the MID floor, fan-out at LOW
   (conventions from `docs/model-routing.md`, measured by
   `core/hooks/model-routing-observer.py`).
3. **Where did the tokens go?** — lane `token-spend`: relative dispatch cost
   (tokens × tier multiplier — relative ranges from docs/model-routing.md,
   never prices), top waste sources ranked.
4. **Did it follow its own loop?** — lane `role-compliance`: every wave
   audited, never-auto-retry honored, RECORD.md written, review lane
   dispatched after code waves.

The machine layer *detects*; this skill *interprets and proposes*. The split
mirrors harness-audit: deleting this skill weakens no gate.

## Steps

### 1. Run the machine layer

```bash
bash core/infra/manager-audit.sh <slug> --json
```

Optional: `--session <id>` to scope routing records to one session. Render the
findings as a per-lane table (lane / check / severity / evidence). The script
always exits 0 — severity lives in the findings, not the exit code.

### 2. Interpret the semantic halves

The script flags candidates it cannot judge; judge them here (this is
judgment work — it stays in the main loop, no dispatch):

- **`scope-drift-candidate`** — read the flagged wave and the restatement's
  Interpreted goal. A wave phrased differently but serving the goal is a
  false positive: mark it `dismissed` with one line of reasoning. A wave
  serving an unstated goal is real drift: keep it.
- **`top-inherit-leak`** — an unpinned dispatch is legitimate for judgment
  work (planning, synthesis — the Model policy's inherit lane). Check what
  the dispatched agent actually did; keep only leaks on execution/lookup/
  fan-out work.
- **`top-tier-dominates`** — expected when the run was genuinely
  judgment-heavy; keep only if execution waves ran inline or at TOP.

### 3. Write proposals

For each surviving actionable finding, append a block to
`.agent/plans/<slug>/PROPOSALS.md`:

```markdown
## P<n>: <one-line title>

- **Finding**: <lane>/<check> — <evidence>
- **Patch**:
  <exact edit — a unified-diff snippet, or "file + section + replacement
  line" precise enough to apply without re-deriving anything>
- **Status**: proposed
```

Proposal targets are **conventions, templates, and docs only** — e.g. a
`model:` line in a delegation contract, a wording fix in a SKILL.md lane, a
tier-alias addition. Never propose a hook that switches models at runtime or
auto-escalates tiers: that class is explicitly rejected
(`docs/model-routing.md` — the decision moved judgment OUT of hooks, and this
skill does not move it back).

### 4. Offer one-click approval

End the report with the numbered proposal list and ask which to apply. On
approval, apply the quoted patch verbatim with Edit, flip the block's
Status to `applied`, and route the change through the normal `/wrap` PR flow.
No approval → PROPOSALS.md stays as the record; nothing is touched.

## Report format

```
manager-audit: <slug>
<per-lane table>
semantic verdicts: <kept / dismissed, one line each>
proposals: P1..Pn (see .agent/plans/<slug>/PROPOSALS.md)
apply which? [numbers / none]
```

## Hard rules

- **Never apply a proposal without explicit user approval in this session.**
- **Never propose runtime model-switching or automatic tier escalation.**
- **Never edit anything during analysis** — Write touches PROPOSALS.md only;
  applying an approved patch is the only other write, and it happens after
  the user says so.
- A dead or missing log is a finding (the observer may be unwired), not a
  reason to skip a lane silently.
