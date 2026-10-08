# Concept — Team Patterns (wave design vocabulary)

A `/supervise` plan is a list of waves. Without a shared vocabulary, every plan
re-invents its wave shape ad hoc. This doc names six team-architecture patterns
and maps each to the wave constructs `/supervise` already has — it adds no new
runtime machinery, only a way to choose and to describe a wave's shape.

## Source

The six pattern names come from the external team-architecture benchmark
recorded in the backlog: revfactory/harness (Apache-2.0) —
[`../internal/harness-improvement-plan.md`](../internal/harness-improvement-plan.md)
§4.4 (H series, item H-1) and the source table in §8. This repo's backlog lists
the names only; the one-line definitions below are written for this repo and
tied to the in-repo constructs they map onto. Nothing here is a claim about the
external project's own definitions.

## The six patterns

| # | Pattern | Shape | Use when |
|---|---|---|---|
| 1 | **Pipeline** | Waves run in strict sequence; each wave's output is the next wave's input | Stages have hard data dependencies (schema → code → tests) |
| 2 | **Fan-out / Fan-in** | One wave dispatches N independent workers, then a single join step synthesizes | Subtasks touch disjoint filesets and can run concurrently |
| 3 | **Expert Pool** | A router picks one specialist from a pool per task by content | Task type varies and each type has a distinct specialist |
| 4 | **Producer-Reviewer** | A writer produces; a separate read-only reviewer/verifier checks end-state | Output quality matters more than speed; risk areas are touched |
| 5 | **Supervisor** | One main loop owns judgment, dispatches, audits, and decides advance/abort | Always the outer frame of `/supervise` itself |
| 6 | **Hierarchical Delegation** | A delegate that itself dispatches sub-delegates (multi-level) | Only when a sub-goal is large enough to need its own plan |

## Mapping to `/supervise` wave construction

| Pattern | Wave construction in `/supervise` | Anchored in |
|---|---|---|
| Pipeline | Consecutive waves `Wave 1..N`; step 2d audit (and `completion-gate`) must pass before step 2e advances | `skills/supervise/SKILL.md` Steps 1–2 |
| Fan-out / Fan-in | One wave with 2–5 concurrent delegation contracts (fan-out cap 3–5; more subtasks split into consecutive waves); the main loop does the join. Write single-threading: one writer per fileset | `skills/supervise/SKILL.md` Step 2b rules; `skills/supervise/templates/delegation-contract.md` |
| Expert Pool | Step 2b lane classification routes by wave content: `code-reviewer` (general/core), `security-reviewer` (auth/secrets), `/council-review` (high-stakes, paid) | `skills/supervise/SKILL.md` Step 2b; `rules/policy/specialist-routing.md` |
| Producer-Reviewer | An execution wave (workhorse tier) followed by a review/verify lane: read-only toolset, fresh spawn, no author context, grades end-state only; under `--verify-blocking` a REFUTED claim stops the wave | `skills/supervise/SKILL.md` Step 2b/2d; `skills/verify-completion/SKILL.md` |
| Supervisor | The main loop itself: judgment stays home (planning, dispatch decisions, audit verdicts, synthesis); safeguards abort on risk-area violations | `skills/supervise/SKILL.md` Model policy, Step 3 |
| Hierarchical Delegation | **Not offered as a wave shape.** Subagents inherit no history and `/supervise` keeps one supervisor; a sub-goal that needs its own waves becomes its own plan run via `/spec` + `/supervise` | `skills/supervise/SKILL.md` Hard rules; `docs/concepts/cost-effective-harnesses.md` (coordination cost) |

Patterns compose: the Supervisor is always the frame, and a typical plan is a
Pipeline of waves where some waves are Fan-out/Fan-in and risky ones end with a
Producer-Reviewer pair. Race lanes (`race: true`) are a Producer-Reviewer
variant (two producers, supervisor picks) and spend two fan-out slots.

## Choosing a pattern

1. Hard dependency between stages → Pipeline (the default shape).
2. Independent filesets inside a stage → Fan-out within that wave, capped 3–5.
3. Content decides who should do it → Expert Pool routing for that lane.
4. Risk area touched, or quality over speed → add a Producer-Reviewer lane.
5. Needs its own sub-plan → split it into a separate plan; do not nest.

Coordination is not free (see
[`cost-effective-harnesses.md`](cost-effective-harnesses.md)): prefer the
simplest pattern that fits, and a single wave with no fan-out when one worker
suffices.
