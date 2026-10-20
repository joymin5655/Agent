---
name: harness-help
description: Router over the harness skills — which skill fits your situation, and the main flow through them. NOT for performing the routed work itself — it only points; invoke the skill it names.
disable-model-invocation: true
tools: Read
---

# /harness-help

You don't remember every skill, so ask. Most work travels one **main flow**;
everything else is standalone. Each skill below is documented in its own
`skills/<name>/SKILL.md` (core) or `extras/skills/<name>/SKILL.md` — this router
only says *when to reach for which*.

## The main flow: idea → shipped

1. **`/spec <slug>`** — turn a fuzzy request into `spec.md` + `plan.md` under
   `.agent/plans/<slug>/`, then route to plan approval (ExitPlanMode). Add
   `--interview` when the request is fuzzy enough that a wrong guess would
   commit the spec to the wrong shape, or `--score-candidates` when the field
   of problems/approaches is wide enough that the pick should be scored, not
   asserted. Approval is what unlocks editing — `spec-gate` stops asking once
   the plan-approval flag exists.
2. **`/supervise <slug>`** — run the approved plan wave by wave, dispatching
   specialists per the delegation contract and auditing after each wave.
   `--goal-mode` for budgeted, resumable runs.
3. **`/verify-completion <claim>`** — before accepting any "done": a fresh
   context re-checks the claim mechanically, then a refute-by-default judge.
   `/supervise` calls this at its completion step; reach for it directly
   whenever a builder's word is the only evidence.
4. **`/wrap`** — commit + PR with the safety gates (gitleaks, risk areas)
   intact. `--auto-push` / `--auto-merge` are opt-in escalations.

A single small edit needs none of this — just make the edit; the gates scope
trivial work out by design.

## Standalone

- **`/council-review [--staged|--head|<range>]`** — multi-vendor second opinion on a
  diff (Claude reviewer plus codex/gemini lanes), synthesized with citation checks.
- **`/project-init`** (command) — scaffold a consumer project with
  `CLAUDE.md`, rules, and `gitleaks.toml`.

## Extras plugin (`agent-harness-extras`, optional)

Rarely used skills live in a second plugin so the core stays light. Install once
with `/plugin install agent-harness-extras@agent`; its skills appear namespaced as
`/agent-harness-extras:<name>` (the short `/<name>` works when unambiguous — note
`loop` collides with Claude Code's built-in `/loop`, so use the namespaced form).
Each is documented in its own `extras/skills/<name>/SKILL.md`:

- **`/harness-audit`** — read-only health check of the harness itself: one
  `verify-all.sh` dry-run, a per-check table, the doc-reality verdict named.
- **`/manager-audit <slug>`** — meta-audit of a `/supervise` run (restatement,
  routing waste, token spend, role compliance).
- **`/persona-review <target>`** — a panel of grounded Korean citizen personas
  reacts to a piece of UX/copy/content; a user-perspective lens, not a code review.
- **`/reorg-sync <old> <new>`** — after a directory move, sweep orphaned
  absolute-path references; dry-run first.
- **`/code-tour [path|range]`** — write a human reading path through a codebase or
  a just-finished build; edits no source.
- **`/worker-setup`** — install → auth → verify onboarding for the cross-vendor
  worker lanes (codex, antigravity), with a cost briefing before anything installs.
- **`/loop <mission>`** and **`/harness-loop`** — bounded-attempt improvement loop
  (generic, and specialized to this harness's reviewer prompts).
- **`/brain-ingest`** — distill quarantined brain `raw/` captures into curated notes.

## The gates underneath

Skills are the methodology; hooks are the enforcement. When one interrupts you
mid-flow, it names its own escape:

- **spec-gate** asks for a plan on a substantive edit → run `/spec`.
- **tdd-guard** blocks new prod code with no failing test → write the test first.
- **pre-tool-guard / risk-area mutexes** stop destructive or contested
  operations → the user drives those; don't route around them.

## Keeping this router honest

Any skill added to or removed from `skills/` or `extras/skills/` updates this file
in the same commit — a router that lies is worse than no router.
