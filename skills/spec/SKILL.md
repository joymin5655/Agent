---
name: spec
description: Upstream planning-discipline — brainstorm a feature into spec.md + plan.md under .agent/plans/<slug>/, then route to plan approval. Enforced by the spec-gate tool boundary, not prompt coercion. NOT for trivial/test/doc-only edits (the gate scopes those out), and NOT for executing an already-approved plan (that is /supervise).
when_to_use: Before starting substantive implementation on a non-trivial feature or change — "spec this", "/spec <slug>", or when spec-gate asks you to plan first before an edit. Add --interview when the request is fuzzy enough that a wrong guess would commit the spec to the wrong shape (structured question loop before writing).
tools: Bash, Read, Write, Edit, Grep, Glob
---

# /spec

## Goal

Turn a fuzzy request into two committed artifacts — a **spec** (what/why) and a
**plan** (how, in waves) — before any implementation edit, then hand the plan to
the user for approval. Approval is what unlocks editing: `plan-gate.py` writes the
plan-approval flag, and `spec-gate.py` (a PreToolUse gate) stops asking once that
flag exists.

This skill supplies the *methodology*; the *enforcement* is a tool boundary. You
cannot prompt your way past `spec-gate` — you produce the artifacts and get the
plan approved, or you flip the mode. That separation is the point.

## Steps

### 1. Brainstorm

Explore the request before committing to a shape:

a. Restate the request in one sentence and name the success criterion.
b. Surface the 2-3 plausible approaches and the tradeoff between them; pick one
   and say why. If the request is ambiguous, ask — don't guess.
c. List what's explicitly **out** of scope (prevents scope creep later).

#### `--interview` — opt-in deep-interview submode

The default brainstorm is a single pass. `/spec <slug> --interview` replaces
step 1b's one-shot "ask if ambiguous" with a structured question loop for
requests fuzzy enough that a wrong guess commits the whole spec to the wrong
shape. It is opt-in by design: simple requests keep the single pass, and the
enforcement story is untouched — the spec-gate tool boundary neither knows nor
cares which submode produced the artifacts.

1. **Unknowns table.** List every unknown in the request; mark each
   **decision-changing (Y/N)** — would different answers produce different
   specs? N-unknowns are implementation details; leave them to the plan.
2. **Batch-question the Y rows only** — at most **4 questions per round**,
   each naming the options and your recommended default.
3. **Re-score after the answers.** Answers resolve rows and surface new
   unknowns; add those to the table and mark them Y/N. This is the
   decision-tree pruning: each round should shrink the Y set.
4. **Terminate on either condition** (whichever comes first):
   - the table has **zero open decision-changing unknowns**, or
   - **3 rounds** have run.
   Unresolved rows carry into `spec.md` under `## Open questions` — named and
   deferred beats silently guessed.

The interview's Q/A trail is recorded in `spec.md` under `## Interview log`
(one line per question: the question, the answer, the decision it settled),
so the spec shows *why* it has its shape, not just the shape.

### 2. Write `spec.md`

Pick a short kebab-case `<slug>` and write `.agent/plans/<slug>/spec.md`:

```markdown
# <slug> — spec

## Problem
<the one-sentence problem + why it matters>

## Success criteria
- <falsifiable, checkable outcomes>

## Approach
<the chosen approach + the tradeoff rejected>

## Out of scope
- <explicitly deferred>

## Interview log            <!-- --interview runs only -->
- Q: <question> → A: <answer> → settled: <the decision it fixed>

## Open questions           <!-- --interview runs only -->
- <unresolved decision-changing unknown, carried, with its default>
```

The last two sections appear only on `--interview` runs; a single-pass spec
omits them.

### 3. Write `plan.md`

Write `.agent/plans/<slug>/plan.md` as ordered waves — the shape `/supervise`
consumes:

```markdown
# <slug> — plan

## Wave 1: <name>
- <step> → verify: <check>

## Wave 2: <name>
- <step> → verify: <check>
```

Every step names its verification. A plan whose steps aren't checkable isn't done.
Default each `→ verify:` to an **executable check** — a command whose exit code
decides (`bash core/tests/<battery>.sh`, `grep -q <artifact>`); prose
verification is allowed only with a stated reason why no command can check it.

### 4. Route to approval

Present the plan to the user and **exit plan mode** (ExitPlanMode). User approval
is what triggers `plan-gate.py` to write `/tmp/agent-plan-approved`. From that
point `spec-gate` allows edits for the rest of the session (the flag is the dedup —
approve once, not per-edit). SessionStart/Stop clear the flag, so each new session
starts unapproved.

This skill is complete when `spec.md` and `plan.md` both exist under
`.agent/plans/<slug>/` and the plan has been routed through ExitPlanMode —
approval itself is the user's move, not yours.

## Enforcement — the tool boundary, not prompt coercion

`core/hooks/spec-gate.py` runs on every `Write|Edit|MultiEdit`. When no plan is
approved this session and the target is substantive impl code (matches the scope
regex, not a test/type/config/doc/meta file, not a risk area), it acts:

| `AGENT_SPEC_GATE_MODE` | Behavior |
|---|---|
| `off` | Gate disabled — no-op. |
| `dryrun` (default) | Logs the verdict to `.agent/logs/spec-gate.jsonl`; advisory only, never stops an edit. |
| `block` | Emits `permissionDecision: "ask"` — surfaces the missing plan; the user approves to proceed or dispatches this skill. |

**Deny vs ask.** The gate uses `ask`, not `deny`. A planning-discipline gate is
reversible — the edit isn't destructive and the escape is trivial — so `ask` (the
harness default for reversible gates) is more defensible than a hard `deny`, and it
de-risks a false positive by leaving the user in control.

## Escapes

Two, both named in the gate's own reason message:

1. **Approve a plan** via ExitPlanMode (this skill's normal path) → the flag is
   written and edits are allowed for the session.
2. **Set `AGENT_SPEC_GATE_MODE=off`** → disable the gate entirely.

## Hard rules

- **Spec and plan before impl.** The artifacts come first; editing is what they
  unlock.
- **Never hand-write the approval flag.** It's written by `plan-gate.py` on real
  approval — forging it defeats the gate.
- **The scope is substantive impl code only.** Tests, types, config, docs, and
  `.agent/` meta are out of scope by design; risk-area paths defer to their own
  hooks. Don't widen the gate to nag on trivial edits.
