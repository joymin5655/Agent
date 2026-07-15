# Concept — Loop Engineering

The harness (this framework) is the environment ONE agent session runs in — tools,
context, permissions, rules. **Loop engineering is the layer above it**: the system
that finds work, hands it to agents, checks the result, records state, and decides
the next step — on a schedule, without a human typing each prompt.

> "Loop engineering is replacing yourself as the person who prompts the agent.
> You design the system that does it instead." — Addy Osmani

```
loop layer      ← schedule + state + verification chain + escalation
   ↑ built on
harness layer   ← one session's tools, permissions, rules, gates   (this repo)
```

Sources (accessed 2026-07):
- Addy Osmani, *Loop Engineering* — https://addyo.substack.com/p/loop-engineering
- Cobus Greyling, *loop-engineering* reference repo — https://github.com/cobusgreyling/loop-engineering
  (readiness levels, failure-mode catalog, anti-patterns, design checklist)

Harness-specific audit against this doc's checklist: [`../loop-engineering-audit-2026-07.md`](../loop-engineering-audit-2026-07.md).

---

## The five building blocks (+ durable state)

Both sources converge on the same primitives; modern agent CLIs ship all five
natively, so loop design is becoming tool-agnostic.

| Block | What it does | This repo's vocabulary |
|---|---|---|
| 1. Scheduling / automations | The heartbeat — cron-like triggers run discovery/triage on a cadence; empty runs self-archive | `/loop`, cron routines, CI jobs |
| 2. Worktrees | Parallel execution without file collisions — isolated checkout per agent | multi-session worktree ([concept](multi-session-worktree.md)), R4 file mutex |
| 3. Skills | Persistent project knowledge that pays down "intent debt" (agents start every session cold) | `skills/*/SKILL.md` |
| 4. Connectors (MCP/plugins) | Reach into real tools (trackers, PRs, DBs) so the loop can *act*, not just report | MCP servers, `gh` CLI |
| 5. Sub-agents (maker/checker) | "The model that wrote the code is way too nice grading its own homework" — explorer → implementer → verifier split | `/supervise` review lanes, `/verify-completion` (refute-by-default) |
| + Durable state | A spine outside any conversation, read at run start / written at run end — "the agent forgets, the repo doesn't" | `.agent/locks/goal-state.db`, `.agent/plans/<slug>/RECORD.md` |

---

## Readiness levels (L0 → L3)

Trust is earned per loop, in phases. Do not skip straight to unattended.

| Level | Name | Behavior |
|---|---|---|
| L0 | Draft | Intent written down; nothing runs |
| L1 | Report | Loop triages and writes state/reports — **no auto-action** |
| L2 | Assisted | Small auto-fixes allowed, always through an independent verifier |
| L3 | Unattended | Runs without supervision; hard safeguards still bind |

The promotion gate is evidence: an L1 loop earns L2 by producing consistently
correct reports, not by someone feeling optimistic.

---

## Failure-mode catalog (merged from both sources)

The strategic three (Osmani) — these get *worse*, not better, as loops improve:

- **Verification is still on you** — "done" is a claim, not a proof, even with a verifier.
- **Comprehension debt** — the gap between what exists in the repo and what you
  understand grows faster as loops ship more unread code.
- **Cognitive surrender** — "the loop handles it." Designing loops with judgment
  is the cure; using loops to avoid thinking is the accelerant — same action,
  opposite outcome.

The operational catalog (Greyling, incident-style):

| Failure mode | Symptom | Primary mitigation |
|---|---|---|
| Infinite Fix Loop | Same item retried forever | Hard attempt cap + escalation |
| State Rot | State file accumulates stale/closed items | Prune on every run |
| Verifier Theater | Verifier approves everything | Independent session + reject-by-default stance + actually run tests |
| Notification Fatigue | Human mutes the loop | Notify only when a decision is required |
| Token Burn | Cost grows unbounded | Budget ceiling + kill switch |
| Over-Reach | Loop edits outside its declared surface | Scoped watch surface + least-privilege connectors |
| Parallel Collision | Two agents edit the same files | Worktree isolation / file mutex |
| Escalation Failure | Loop stalls silently instead of handing off | Explicit escalation triggers, tested |

---

## Design checklist (normative — 15 criteria)

Audit any loop (or the harness features that host loops) against these:

1. **Explicit goal + non-goals** — one sentence each.
2. **Scoped watch surface** — which repos/branches/paths it touches; nothing else.
3. **Durable cadence** — scheduling survives session/process restart; self-cleans when idle.
4. **Durable external state** — read at run start, written at run end, pruned of stale items; never lives only in a chat transcript.
5. **Maker/checker separation** — implementer and verifier are different sessions/instructions; implementer cannot self-declare "done"; verifier defaults to reject and runs tests rather than eyeballing.
6. **Bounded iteration** — hard attempt cap per item (e.g. 3), mandatory escalation on exceeding it.
7. **Escalation that is actually read** — explicit triggers (max attempts, risk paths, ambiguity); notifications fire only when a decision is genuinely required.
8. **Least-privilege connectors** — read-only first; write scope earned incrementally; deny-list for auth/secrets/infra/payments paths.
9. **No auto-merge without an allowlist** — human merge outside a narrow, explicitly safe path set.
10. **Isolation for parallel work** — worktrees or equivalent; no shared-file collisions.
11. **Phased rollout (L0→L3)** — report-only proven before assisted, before unattended.
12. **Run-log observability** — append-only history of ran/found/did/escalated, auditable without reading raw chat logs.
13. **Cost ceiling** — token/spend budget with a kill switch, not just a cadence.
14. **Anti-flake discipline** — flaky signals are classified/quarantined, not "fixed" with code or blind retries.
15. **Human synthesis cadence** — a human still reads what the loop shipped on a regular beat; the success metric includes quality held, not just volume.

Quick red flags (any one of these = stop and redesign): >3 fix attempts with no
progress · verifier is the same session as the implementer · no state file ·
notify-every-run · auto-merge with no allowlist.

---

## How this maps to the harness

- The maker/checker split is already the harness's spine: `/supervise` dispatches
  execution and routes review to independent lanes; `/verify-completion` judges
  completion claims refute-by-default.
- Bounded iteration and durable state exist in goal-mode
  (`core/infra/supervisor-goal.sh` — SQLite state, budget caps, no auto-retry on
  failed audits).
- Per-project trust tiers (personal vs collaborative) map directly to the L0→L3
  ladder — see `docs/customization.md` § Trust tiers.
- The dated gap analysis lives in
  [`../loop-engineering-audit-2026-07.md`](../loop-engineering-audit-2026-07.md);
  open gaps are tracked as LE-* items in `docs/harness-improvement-plan.md`.
