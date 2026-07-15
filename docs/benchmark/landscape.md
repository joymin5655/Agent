# Harness landscape — where agent-harness sits (2026-07)

A survey and self-assessment against the most popular agent harnesses on
GitHub, **not** a run benchmark. The only measured comparison in this repo is
[`results.md`](results.md) (blind reviewer benchmark vs one bundled reviewer);
everything below is positioning based on public documentation. Star counts
were pulled from the GitHub REST API on **2026-07-08** and drift constantly —
see [Review cadence](#review-cadence). A **2026-07-14 spot re-check** (five
parallel research lanes, gh api + README only) landed the corrections marked
"2026-07-14" below; the full audit lives outside this repo (personal drive
audit report).

## Method and caveats

- Two buckets: same-runtime harnesses (Claude Code plugins/skill packs) and
  general coding-agent harnesses with their own runtimes.
- Feature cells come from each project's public README/docs — **we did not run
  them**. A generous reading was used; errors are ours and corrections are
  welcome.
- Stars measure popularity, not quality. They are reported because the survey
  question was "the most popular", not "the best".
- Claims about *this* harness cite repo artifacts (files, CI jobs, test
  fixtures) — the same evidence discipline as `results.md`.

## Bucket 1 — Claude Code ecosystem

Axes: enforcement model (hard `deny`/`ask` hooks vs prompt-only "MUST"),
context footprint, author≠reviewer separation, self-verification CI (does the
project CI-test *itself*), per-task-class model tiering, cross-runtime
support, shipped eval suite.

| Project (stars 2026-07-08) | Enforcement | Footprint | Author≠reviewer | Self-verify CI | Model tiering | Cross-runtime | Eval suite |
|---|---|---|---|---|---|---|---|
| superpowers (248.7k) | prompt-only | medium (skill pack) | partial (review skills) | no | no | Claude Code | no |
| gstack (120.3k) | partial (warn-level skills) | large (120+ skills) | **yes** (cross-model review) | partial | yes (profiles) | partial (codex/gemini bridges) | partial (model judge) |
| claude-flow (63.5k) — renamed **ruflo** 2026-02-27; npm/CLI still `claude-flow` (2026-07-14) | partial (pre/post hooks) | large (~87 MCP tools) | partial | no | multi-provider | MCP-based | claimed, unverified |
| BMAD-METHOD (50.2k) | prompt-only (workflow gates) | large (agile ceremony) | partial (QA role) | no | manual per-agent | **yes** (IDE-agnostic) | no |
| wshobson/agents (37.6k) | none (catalog) | small per-agent | n/a | no | hints only | **yes** (6 runtimes) | no |
| oh-my-claudecode (37.5k) | **yes** (real hooks) | large (eager context) | **yes** (verifier lane) | no | yes (manual 3-tier) | partial (worker CLIs) | no |
| **agent-harness (this repo)** | **yes** (deny/ask hooks, fail-open) | **small** (2 agents, 4 skills) | **yes** (skill-mandated separate-context verify) | **yes** (4 CI jobs on itself) | policy + config templates (not runtime-enforced) | **yes** (3 adapters) | **no → E-1** |

Cut for space: SuperClaude 23.5k (persona prompt-pack, prompt-only),
claude-squad 8.1k (parallel-session TUI, a runner not a harness), agent-os
5.0k (lighter spec workflow).

## Bucket 2 — general coding harnesses

Same axes plus sandboxed runtime (these ship their own execution
environment; a plugin-layer harness inherits its host's).

| Project (stars 2026-07-08) | Enforcement | Sandboxed runtime | Author≠reviewer | Model tiering | Eval suite |
|---|---|---|---|---|---|
| OpenHands (79.9k) | confirmation modes + security analyzer | **yes** (Docker) | partial | manual (any model) | **yes** (SWE-bench native) |
| goose (50.8k) | permission modes | process-level | no | **yes** (lead/worker split) | thin |
| Aider (47.2k) — effectively stalled: last release 2025-08, last push 2026-05 (2026-07-14) | git auto-commit (trivial revert) | no (host) | no (single agent) | **yes** (architect/editor) | community leaderboards |
| SWE-agent (19.7k) | cost caps | **yes** | no | config routing | **yes** (SWE-bench DNA) |

LangGraph (36.7k) is excluded: a graph orchestration *library* you build a
harness with, not a harness.

### Field shift — native orchestration (2026-07-14)

Anthropic's **Dynamic Workflows** went GA (2026-05-28, extended to the Pro
plan 2026-07-02): the host runtime now writes and executes orchestration
scripts natively (up to 1,000 subagents). This erodes the reason-to-exist of
orchestration-first third parties (claude-flow/ruflo class). It does **not**
collide with this harness's position — enforcement, curation, and
self-verification are governance concerns the native orchestrator does not
own. The 2026-07-14 re-check also found no top-bucket project that has closed
the "prompt-only enforcement" gap (real deny/ask hooks + self-verify CI +
author≠reviewer isolation remain absent from all six surveyed leaders).

## What the field invests in vs where it is thin

Consistent investments across the popular projects:

1. **Hard eval suites** — OpenHands and SWE-agent are eval-native; even
   skill packs ship model-judge scoring. This is the field's strongest card.
2. **Sandboxed runtimes** — container/process isolation as a safety layer.
3. **Distribution** — marketplaces, installers, usage dashboards.
4. **State/memory infrastructure** — checkpointers, cross-session stores.

Consistent thinness:

1. **Enforcement is overwhelmingly prompt-only.** "You MUST" instructions
   dominate; real PreToolUse `deny`/`ask` paths are rare.
2. **Context bloat is the norm** — 100+ skill catalogs, ~87-tool surfaces,
   eager loading that multiplies per spawned agent.
3. **Almost nobody CI-verifies the harness itself** — self supply-chain
   scans, manifest drift guards, and doctor-style environment reconciliation
   are nearly absent.
4. **Author≠reviewer discipline is thin** — most flows let the builder
   approve its own work; separate verification lanes are the exception.
5. **Per-task-class model tiering is mostly absent** — a handful route
   two tiers; routing LOW/MID/TOP by work class is an open niche.
6. **Domain neutrality is rarely a discipline** — packs hard-code their
   author's stack; portability is accidental.

## Where this harness is strong (evidence-linked)

- **Real enforcement with a calibrated ceiling.** 17 registered hook scripts
  (`setup.sh --doctor` checks every registered hook resolves and is
  executable); the `deny` tier is deliberately narrow — destructive fs/git
  operations, secrets access, and design-constant hardcoding — and the
  calibration rule bars adding new `deny` tiers: everything else escalates at
  most to `ask`, and hooks fail open
  (`docs/freedom-enforcement-calibration-2026-07.md` records the calibration
  and its external grounding).
- **Curated surface.** Exactly 2 shipped agents (`agents/master-registry.json`,
  trimmed from 5 on usage evidence) and 4 skills — the anti-bloat position the
  survey shows the field lacks.
- **Self-verification CI.** 4 jobs run against the harness itself
  (`.github/workflows/ci.yml`: manifest/frontmatter drift, domain-neutrality
  sanitize gate, self supply-chain scan, gitleaks) plus `setup.sh --doctor`
  environment reconciliation and 12+ test scripts in `core/tests/`.
- **Author≠reviewer as skill-mandated discipline.** `/verify-completion`
  requires a separate-context, refute-by-default verifier (a skill rule, not
  yet CI-enforced — the mechanical guard is O-1's open done-condition); in
  practice the adversarial review lane has caught MAJOR defects local test
  batteries missed on several consecutive PRs (see CHANGELOG 0.2.x entries).
- **Cross-runtime tier policy.** `docs/model-routing.md` maps work class →
  model tier across three runtimes via documentation and config templates —
  deliberately **not** runtime-enforced (a per-prompt model switcher was
  evaluated and rejected as unauditable; only specialist pins are CI-guarded).

## Where it is behind (each closes on a backlog ID)

- **No shipped eval suite** — the field's strongest card is this repo's
  biggest gap. → **E-1** (public `evals/` with labeled cases, LLM-judge
  scoring, Pass^3, CI regression gate).
- **Orchestration maturity** — supervise lacks the delegation-contract
  template, fan-out caps, and single-writer rule as checkable rules → **O-1**;
  no general fresh-context loop skill → **O-2**.
- **Gates don't teach or report.** Deny/ask messages lack WHY/FIX → **T-1**;
  no gate registry with fire-rate/expiry telemetry → **T-2**; skill
  descriptions lack negative triggers → **T-3**.
- **Cold-install path is unverified in CI** → **M-5** (new, this survey).
- **Doctor can't see tier-profile drift** → **M-4**.

## Non-goals (deliberate, with reversal conditions)

- **Sandboxed runtime.** The host CLI owns permissioning and sandboxing; a
  plugin-layer harness re-implementing it would duplicate a trust boundary.
  Reconsider if the harness ever executes untrusted third-party plans.
- **Marketplace/catalog scale.** Curation is the product; the survey shows
  volume-optimized packs converging on the bloat failure mode. Reconsider
  only if the agent roster itself needs community contribution.
- **Memory infrastructure.** Eager-loaded state is the largest context-bloat
  source observed in the field; state stays minimal (`.agent/`) and
  runtime-native. Reconsider if cross-session state becomes a measured
  bottleneck.
- **Swarm-scale orchestration.** An ~87-tool surface is the same failure
  mode the 5→2 agent trim rejected. Reconsider with evidence that fan-out
  beyond supervise waves improves outcomes for this repo's workloads.

## Gap → backlog map

| Survey gap | ID | Done-condition (from `docs/harness-improvement-plan.md`) |
|---|---|---|
| Eval suite | E-1 | `evals/` exists; ≥10 labeled cases; CI Pass^3 report; regression fails CI |
| Delegation contracts / fan-out / single-writer | O-1 | template file + SKILL.md references 4 rules + CI guards reviewer read-only toolsets |
| General loop skill | O-2 | fixture mission: state file → session restart → resume + cap-stop recorded |
| Teaching gates | T-1 | every deny/ask fixture's decision JSON carries WHY/FIX |
| Gate registry + fire-rate + expiry | T-2 | registry rows for all gates + digest reports DEAD/FATIGUE candidates |
| Negative skill triggers | T-3 | every shipped SKILL.md description has ≥1 negative example |
| Grader failure-mode checklist / write-ban | L-1/L-2 | failure-modes.yaml ≥8 modes; loop-session writes to evals/tests → ask |
| Doctor tier-profile blind spot | M-4 | doctor check + fixtures (profiles present/absent/skip) |
| Clean-install CI smoke | M-5 | bare-checkout install on a scratch config home → doctor 0 fail; sabotaged exec bit → job fails |

## Review cadence

Star counts and feature claims are a **2026-07-08 snapshot**. Re-verify with:

```bash
gh api repos/{owner}/{repo} --jq .stargazers_count
```

Refresh this document at each minor release or quarterly, whichever comes
first; re-check renames (three of the surveyed repos had moved within the
last year).
