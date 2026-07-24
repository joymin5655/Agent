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

### Spot re-check — 2026-07-16 (dispatch + knowledge tooling)

Two projects benchmarked in depth this session; three adoptions shipped.

- **netwaif/multi-agent-starter** (★76, v3.3.0, pushed 2026-07-13) — a small
  deterministic harness *generator*: role→backend worker dispatch
  (`backends.json` + `call_worker.sh`), generate→`validate.py` PASS/FAIL
  pairing, file-as-memory. Low stars, but three of its patterns closed real
  gaps here (design borrowed, no code): (1) the **cross-vendor
  second-opinion lane** — `core/infra/backends.json` +
  `core/infra/call-worker.sh` (v0.4.0); before it, the adapters only
  translated hooks *into* Codex/Gemini, and no path existed for a Claude
  session to call them as workers; (2) **install→validate pairing** —
  `setup.sh` now ends every install in the read-only `--doctor` diagnosis
  (v0.3.0); (3) **checksum update mode** — idempotent `apply_template()`.
  Its deliberately minimal generated tree also prompted the `legacy/` diet
  (tree-is-the-package makes git removal + archive tag the only mechanism).
- **inkeep/open-knowledge** (★2,936, v0.33.0-beta.5, GPL-3.0, pushed
  2026-07-16) — a productized LLM wiki (external-sources → research →
  articles consolidation, near-isomorphic to the personal vault's raw→wiki
  distillation). Sandbox trial 2026-07-16: default `ok init` wrote **11
  user-global/project targets** (MCP registrations across four editors +
  global skills — the config-pollution class this drive's rules forbid);
  the contained recipe `--scope project --no-skills` verified clean.
  Verdict: **conditional adoption** in the vault, re-evaluate ~2026-10
  (daily-commit beta). GPL boundary: tool use and pattern reference only —
  no code into this repo. Pattern candidate logged: **skill-symlink SSOT**
  ("write once, install everywhere") as an alternative to `setup.sh`'s
  copy-drift.
- Session observation, same date: the execution-dispatch **permission
  surface was implicit** — a background subagent auto-denies prompting
  calls, and the shipped specialists are read-only, so supervise edit waves
  could silently lose their writes. Closed by the `/supervise` dispatch
  pre-flight (`skills/supervise/SKILL.md`). The model-override convention
  stays measured-not-enforced (7/7 TOP-inherit in the 2026-07-11 audit;
  observer hook only).

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

## Public setups benchmark — 2026-07-25 (R6)

Six well-known **public** Claude-Code-adjacent setups, scored against this
harness's own 3-layer model: **L1** = the agent-harness plugin itself (gates,
review agents, skills, hooks — portable via marketplace); **L2** = curated
third-party plugins/tools (memory layer, token-optimizer hooks, statusline,
search skills); **L3** = personal glue (global CLAUDE.md instruction files,
personal hooks, personal skills). The owner's confirmed weak spot going into
this survey: **zero replication mechanism for L2/L3 on a new machine** — L1
ships via `/plugin marketplace add`, but the personal layer has no bootstrap
story (a parallel wave is building one). Stars pulled live via `gh api` on
**2026-07-25**; CI-workflow presence verified the same way
(`gh api repos/{owner}/{repo}/contents/.github/workflows`), not just claimed
in READMEs — everything else is README-based reading, same caveat as buckets
1–2 above.

| Project (★ 2026-07-25, license) | Philosophy | Install / bootstrap | Self-verify CI | Curation vs. bulk | Memory / continuity | Multi-vendor | Security posture |
|---|---|---|---|---|---|---|---|
| **obra/superpowers** (260.6k, MIT) | prompt-only skill/methodology pack | marketplace-driven across many runtimes (Claude Code, Antigravity, Cursor, Gemini CLI, Copilot CLI, Kimi Code); no manual clone | **partial** — ships `evals/` (drill-eval harness cloned from `superpowers-evals`, skill-behavior tests) + `tests/` plugin-infra (`npm test`) — deeper than the 2026-07-08 snapshot in Bucket 1 recorded as "no"; flagged for the next R1 refresh, not corrected here | bulk-leaning — broad catalog, prompt-only "MUST" enforcement (matches Bucket 1 finding) | none documented — stateless design→plan→execute; git worktrees isolate workspace, not context | **yes** — dedicated install path per runtime | telemetry opt-out env var only; no secret scanning or deny/ask hooks documented — prompt-instruction-only |
| **mattpocock/skills** (186.7k, MIT) | personal "skills for real engineers" catalog, published `.agents` directory | `npx skills@latest add mattpocock/skills` (skills.sh) or Claude Code plugin marketplace, per-agent targeting | not documented — mutation testing (Stryker) is a *skill the pack teaches*, not CI on the pack itself | engineering/productivity axis split, user-invoked vs. auto-discovered — organized, no hard roster cap | CLAUDE.md persists guidance; no session-state mechanism documented | **yes** — skills.sh explicitly supports 40+ agents | none documented (repo nav shows "Security and quality 0") |
| **disler/claude-code-hooks-mastery** (3.8k, no LICENSE detected) | hooks-first reference architecture — demonstrates all 13 lifecycle hook points | manual clone; UV single-file scripts (per-hook inline deps, no venv) | **no** — no `.github/workflows` (verified via API); relies on runtime hook-based validators (ruff/ty on PostToolUse) instead of a test suite | reference/demo scope, not a daily-driver roster | not a focus — session/subagent hooks only, no cross-session store | **no** — Claude Code only | **partial real enforcement** — PreToolUse blocks dangerous commands (`rm -rf`, `.env` access, `chmod 777`) via exit-code-2 blocking; closest peer to hard deny/ask gates among the six |
| **anthropics/skills** (163.9k, license unspecified) | official first-party skills reference/distribution | 3 channels — Claude Code marketplace, claude.ai (paid plans), Claude API | **no** (verified via API, no workflows) — explicit disclaimer: "test skills thoroughly in your own environment before relying on them" | demonstration-only, no documented quality gate | none — stateless instruction sets | n/a (defines the platform rather than consuming other runtimes) | none documented |
| **poshan0126/dotclaude** (829, MIT) | "standard `.claude/` folder" personal template, marketplace-distributed | `/plugin marketplace add` + `/plugin install setupdotclaude@dotclaude` → `/setupdotclaude` deep-scans the target codebase (manifests, source/test files, git workflow, existing AI configs) and *proposes* component placement — evidence-based install | **yes** — `ci.yml` (verified via API) + `bash hooks/tests/run-all.sh` fixture tests across Linux/macOS + `claude plugin validate --strict` | curated, fixed roster — 7 agents, 12 skills, 6 rules, 8 hooks | `/claude-md audit` captures durable learnings into CLAUDE.md; `/catchup handoff` rebuilds context post-`/clear` + writes `HANDOFF.md`; `.dotclaude.json` project fingerprint drives session-start drift warnings — most developed continuity story of the six | **no** — Claude Code only | **yes**, real hard hooks — `protect-files.sh`, `scan-secrets.sh`, `block-dangerous-commands.sh`, `warn-large-files.sh`, all PreToolUse; explicit confirm-before-apply discipline |
| **citypaul/.dotfiles** (693, MIT) | personal dotfiles repo that "became unexpectedly popular" for its CLAUDE.md; now a curated aggregation point | `git clone` into a dotfiles-managed home; `--with-opencode` flag copies Claude-Code-specific agents/commands into OpenCode equivalents | **yes** (verified via API) — `ci.yml` runs `test/opencode-compat.sh` (cross-runtime compat test) + changesets validation on every PR | explicit provenance — vendors 18 design skills from `pbakaus/impeccable`, 6 from `addyosmani/web-quality-skills`, 3 from `vercel-labs/next-skills`, 1 from `mattpocock/skills` (`grill-me`), 1 from `coreyhaines31/marketingskills`, each credited by source repo | `expectations` skill captures learnings ("would save future developers >30 minutes" criterion); no cross-session state store | **partial** — Claude Code + OpenCode via explicit flag, not a generic adapter layer | agent-based advisory only (`tdd-guardian`, `ts-enforcer` are subagents, not PreToolUse hooks) — no secret scanning or hard hooks documented, same prompt-only bucket as the Bucket-1 majority |

### Notable observations

- **dotclaude is the closest public peer to this harness's enforcement
  model** — real PreToolUse deny/ask hooks plus a CI job, at 829★. It does not
  overturn Bucket 1's field-wide "prompt-only dominates" finding (N=1 among
  six, and none of the mega-star projects match it), but it shows the pattern
  exists in the wild at small scale, not just here.
- **citypaul/.dotfiles is the field's answer to L2 curation** — five
  named upstream skill sources vendored with explicit provenance and license
  attribution per source. This harness's L2 has no equivalent provenance
  ledger; see gaps below.
- **superpowers' actual CI depth exceeds the 2026-07-08 Bucket 1 snapshot** —
  `evals/` + `tests/` were found on this pass. Not corrected in the Bucket 1
  table (out of this wave's scope; flagged for the next scheduled refresh per
  [Review cadence](#review-cadence)).

### Verdict — lacking vs. excessive vs. the owner's setup

| Axis | 부족 (lacking) — evidence | 과잉 (excessive) — evidence | 백로그 ID |
|---|---|---|---|
| Codebase-aware, evidence-based install | dotclaude's `/setupdotclaude` deep-scans manifests/source/tests/git workflow/existing AI configs before proposing placement; `setup.sh` here copies templates with no target-codebase analysis | — | **H-4** (`/project-init` 메타 팩토리 라이트 — same premise: domain analysis → tailored config proposal) |
| Post-install drift detection on the *consumer* project | dotclaude's `.dotclaude.json` fingerprint + session-start "config drift: project manifests changed since setup" warning; this harness's doctor checks (I-2/M-4) watch the harness's own install caches and tier profiles, not whether a consumer project's stack moved since `setup.sh` ran | — | **W-1** (freshness-watchdog — designed but not yet implemented/wired; this finding is a concrete instantiation of its intended scope) |
| Self-verification apparatus vs. shipped-surface size | — | 8 CI jobs + 13+ local test scripts guarding **2 agents + 2 skills**; the two public peers with any CI at all (dotclaude, citypaul) run exactly 1 CI job each covering multiple steps. No surveyed project approaches this jobs-per-shipped-unit ratio. | — |
| Gate telemetry + expiry infrastructure (T-2) at solo-maintainer scale | — | None of the six surveyed setups — including dotclaude, the one peer with real hard hooks — instrument gate fire-rate or run an expiry-review process. T-2's registry+digest infra assumes enough traffic to distinguish DEAD/FATIGUE signal from noise; worth re-checking against this repo's actual single-user fire-rate before investing further here. | — |

Two gaps surfaced with **no existing backlog ID** — per the orphan-zero rule
they are not placed in the table above; they are proposed here as text for
the supervisor to ratify and insert at merge, not edited into
`docs/harness-improvement-plan.md` by this wave:

**Proposed new backlog rows**

- **L2 provenance/license ledger** — citypaul/.dotfiles vendors skills from
  5 named upstream repos, each with source + license attribution inline in
  the README. This harness's L2 (curated third-party plugins/tools) has no
  documented mechanism for tracking *what was vendored from where, under what
  license* if a personal skill/hook is ever adopted from a public source.
  Distinct from W-2 (`/reorg-sync`, which sweeps stale path references, not
  provenance) and from the Non-goals "marketplace/catalog scale" rejection
  (this is about honest bookkeeping for the harness's own occasional L2
  imports, not building a catalog). Done-condition sketch: a
  `docs/l2-provenance.md` (or equivalent) ledger + a doc-reality-style check
  that flags an L2-sourced file with no provenance entry.
- **L2/L3 cross-machine bootstrap** — the confirmed gap driving the parallel
  bootstrap wave in this same campaign (`setup.sh --bootstrap` +
  `local-layer-export`, tracked outside this document). Named here for
  completeness since it is the single largest gap this survey's peer set
  addresses and this repo does not: dotclaude ships one-command evidence-based
  install, citypaul's entire personal layer is one `git clone` away on a new
  machine. No ID exists yet in `docs/harness-improvement-plan.md` — this
  wave does not mint one; the parallel wave's own landing is the natural
  place to register it.

## Review cadence

Star counts and feature claims are a **2026-07-08 snapshot**. Re-verify with:

```bash
gh api repos/{owner}/{repo} --jq .stargazers_count
```

Refresh this document at each minor release or quarterly, whichever comes
first; re-check renames (three of the surveyed repos had moved within the
last year).
