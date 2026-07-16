# Concept — Cost-Effective Harnesses (intelligence placement)

Most tasks have **intelligence asymmetry across their tokens**: a small share
of the tokens need frontier-tier judgment, the bulk are execution a cheaper
model absorbs equally well. A cost-effective harness recognizes that shape and
places frontier intelligence only where it pays. This document distills the
external evidence; the harness's normative tier policy lives in
`docs/model-routing.md` — this doc supplies the economics *behind* it and never
duplicates the ladder.

Sources (accessed 2026-07):
- "Cost effective harnesses with Fable 5" — https://www.happytlog.com/2026/07/fable-5-opus-4-8-management-style-ai-cost.html
- ClaudeDevs thread (2026-07-08) — advisor/orchestrator patterns with published
  SWE-bench Pro / BrowseComp numbers
- Anthropic advisor-tool docs — https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool
- Anthropic cookbook, plan-big-execute-small managed-agents notebook —
  https://github.com/anthropics/claude-cookbooks

---

## Three intelligence-placement patterns

| Pattern | Shape | Frontier model's tokens |
|---|---|---|
| **Orchestrator** | Frontier plans and delegates; cheap workers absorb execution tokens | Plan + briefs + reading reports |
| **Advisor** | Cheap executor works; frontier is *called* for guidance at checkpoints | A few consultations per task |
| **Verifier / judge** | Cheap (or mid) model produces; frontier grades the result | Judging only |

These compose: the strongest published combo is frontier planner → mid coder →
frontier judge (Hashimoto: planning+judging costs land in the low single-digit
dollar range vs $50+ full frontier round trips, at API pricing).

### The advisor finding — checkpoints beat upfront advice

The Parameter Golf experiment (ML-engineering loop: edit training code, run,
read results, pick next experiment; frontier=Fable 5, executor=Sonnet 5)
measured **~90% of frontier-solo improvement at ~34% of the token cost** —
but *where* the advisor value came from is the load-bearing result:

- **Upfront advising was not the benefit.** The frontier model's initial
  experiment ranking was *anti-correlated* with what actually worked.
- **Mid-run advisory checkpoints were.** The cheap executor hill-climbs
  marginal gains with no tendency to step back and re-rank; the frontier
  checkpoint's value is steering and re-prioritization *after results exist*.

Generalization: when a task is exploratory — each result reshapes what's worth
trying next — judgment must be **scattered across** the task, not front-loaded.
A single upfront frontier plan is the wrong spend; recurring frontier
checkpoints over a cheap executor are the right one. (When judgment genuinely
concentrates upfront or at review, orchestrator/verifier placement wins
instead.)

Published advisor numbers: SWE-bench Pro, mid executor + frontier advisor tool
called ~once per task → **~92% of frontier score at ~63% of the price**.

---

## Coordination cost — why delegation isn't free

Every handoff between models carries a roughly **fixed per-handoff cost**,
independent of how much work is delegated:

- **Boundary duplication** — every token crossing the boundary is billed at
  least twice: the lead *writes* a brief, the worker *reads* it; the worker
  *writes* a report, the lead *reads* it.
- **Fan-out overlap** — parallel workers don't communicate, so their research
  partially duplicates (each re-reads context the others already read).

The BrowseComp measurement shows the inversion point directly:

| Task size | Result |
|---|---|
| Small (~0.37M read-tokens/problem) | Frontier **solo was cheaper** — orchestration added a **60% markup for no performance benefit** |
| Large (~31M read-tokens/problem) | Frontier orchestrator + cheap workers hit **96% of the score at 46% of the cost** |

The rule: **the token volume delegated to cheap workers must offset the
per-handoff coordination cost.** Two corollaries:

1. A dispatch whose delegated volume is comparable to its own brief+report
   boundary saves nothing — its "saving" is negative.
2. Frontier models are typically more *token-efficient* per task than cheaper
   models (fewer wasted attempts), which raises the delegation bar further:
   the cheap worker must absorb enough volume to beat a smaller frontier
   token count, not an equal one.

---

## Four guidance points for a cost-effective harness

1. **Examine the task shape.** Judgment scattered across the task
   (exploratory, result-driven) → cheap executor + frontier **advisor**
   checkpoints. Judgment concentrated upfront or at review → frontier
   **orchestrator** or **verifier**.
2. **Use delegation heuristics.** Give the harness priors for worker
   selection (models ranked by capability axes), so tier choice is a stated
   convention, not per-call improvisation.
3. **Assess the coordination cost.** Delegate only when the delegated token
   volume clearly offsets the per-handoff fixed cost (see the inversion table
   above).
4. **Ensure prompt caching.** Each worker maintains its own prompt cache —
   route repeat calls at the same context to the **same** worker so its cache
   accumulates. Spawning a fresh worker per request re-pays the full context
   write every time; a low cache hit rate can erase the entire benefit of a
   cheaper per-token worker.

---

## How this maps to the harness (2026-07-16 audit)

| Guidance | Harness state | Verdict |
|---|---|---|
| 1. Task shape / advisor | Orchestrator and verifier placements exist (`/supervise` judgment-vs-hands split; `/verify-completion` judge). The advisor instance exists *unnamed*: supervise's audit-after-wave is a TOP-judgment checkpoint over MID execution — exactly the mid-run re-ranking the advisor finding calls for | Partial → named in `docs/model-routing.md` § Intelligence placement (M-7) |
| 2. Delegation heuristics | Present — the LOW/MID/TOP ladder and work-class table in `docs/model-routing.md`; the `model` field in `skills/supervise/templates/delegation-contract.md` | Met |
| 3. Coordination cost | Was named once repo-wide (fan-out cap rationale in the delegation contract); no when-NOT-to-delegate floor existed | Gap → coordination-cost floor in `docs/model-routing.md` § Floors (M-7) |
| 4. Prompt caching | Zero mentions repo-wide; no worker-reuse rule — fresh spawn per request was the implicit default | Gap → worker-reuse rule in `docs/model-routing.md` § Floors + delegation contract (M-7); measurement is open (M-8) |

Related: `docs/benchmark/landscape.md` found per-work-class model tiering to be
an open niche field-wide — this doc is the economic argument for keeping that
investment. Backlog: M-6/M-7 shipped with this doc, M-8 (telemetry for
spawn-reuse ratios and per-wave delegated volume) tracked in
`docs/harness-improvement-plan.md` § 4.10.
