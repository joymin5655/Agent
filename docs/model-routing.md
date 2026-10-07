# Model routing — cross-runtime tier policy

One canonical mapping from **work class → model tier**, applied across the
three supported runtimes (Claude Code, Codex CLI, Gemini CLI). In the Claude
column, **specialist pins are enforced** (agent frontmatter + the
`validate-plugin` CI drift guard — see `skills/supervise/SKILL.md` → Model
policy); the judgment-unpinned rule and per-call MID/LOW dispatch overrides
are documented conventions (CI cannot check a call-time value). The Codex and Gemini columns
are **conventions carried by the adapter templates**: those runtimes read
their own config files; the harness never switches a model at runtime.

## The ladder

Three rungs, plus an orthogonal *effort* dial (reasoning effort / thinking
budget) that exists on every rung:

| Rung | What runs here | Cost intuition |
|---|---|---|
| **LOW** | Mechanical work: build/type/lint cleanup, lookups, searches, fan-out workers | ~0.1–0.2× the workhorse |
| **MID** (workhorse) | Implementation, code review, verification judges | baseline |
| **TOP** | Planning, architecture, orchestration judgment, deep design (opus-class @ high effort) | 2–5× the workhorse |
| **TOP-F** | Security review, completion verdicts only — a reserved sub-rung, not a general escalation target (fable-class @ max effort) | ≥TOP |

TOP and TOP-F are both "the top rung" for cost-intuition purposes; the split
is about which two verdict-shaped tasks are allowed to reach past TOP into
the fable-class ceiling, not a new cost tier for everything else (`spec.md`
§7 Q3). The exact model alias behind each class still lives only in its
consumer — an agent's `model:` frontmatter, an adapter's tier file — never
here.

**Effort before tier-up.** Before promoting a task one rung, raise the effort
dial *within* the rung first. A MID model at high effort beats a TOP model at
low effort for most bounded tasks, at a fraction of the cost. Frontier-model
vendor guidance now says the same — effort is the primary cost/latency dial;
prompt-side implications live in `docs/concepts/fable-5-prompting.md`.

## Work class → tier

Example IDs are a 2026-07 snapshot — model names drift; the tier semantics do
not. Prices are deliberately kept out of this document (they change faster
than any doc review cycle).

| Work class | Tier | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|---|
| Planning / architecture | TOP | Session's top model — agents **unpinned** (frontmatter absence = inherit) | `--profile deep` | top-tier model, caller-explicit `-m` |
| Orchestration judgment — work distribution, gate verdicts, result synthesis | TOP | Session's top model, main loop (never dispatched below the session model) | `--profile deep` | top-tier model, caller-explicit `-m` |
| Security review | **TOP-F** | `security-reviewer` pin — see the `model:` pin in `agents/security-reviewer.md` | `--profile deep` | top-tier model, caller-explicit `-m` |
| Code review | MID | `code-reviewer` pin (sonnet-class) | mid model, caller-explicit `-m` + high effort | workhorse model |
| Persona/citizen review | MID | `persona-review-orchestrator` pin (sonnet-class) | mid model, caller-explicit `-m` + high effort | workhorse model |
| Implementation | MID | Dispatched at workhorse tier — explicit `model` override on the Agent dispatch; the session keeps judgment and dispatches hands | config default (unprefixed) | workhorse model |
| Verification judge (interim checks) | **MID floor** | **never below sonnet-class** — see Floors | mid model, high effort or above | workhorse model or above |
| Completion verdict (`/verify-completion` terminal judge) | **TOP-F reserved** | may escalate past the MID floor to the `security-reviewer`-class pin when the dispatch is the terminal verdict, not an interim check | `--profile deep` | top-tier model |
| Mechanical fixes | LOW | per-call `model` override on the Agent dispatch (no low-tier agent is shipped) | `--profile quick` | lightest model |
| Lookups / search | LOW | per-call low-tier override | `--profile quick` | lightest model |
| Fan-out workers | **LOW default** | low-tier override; promote individual workers only when a task demands it | `--profile quick` | lightest model |

Implementation dispatches additionally require a cleared permission surface
before leaving the main loop: a background subagent auto-denies any tool call
that would prompt, and the shipped specialists are read-only — see
`skills/supervise/SKILL.md` § Dispatch pre-flight.

## Built-in agents (Claude Code)

Claude Code ships unpinned built-in subagents; with no frontmatter they inherit
the session's top model, which makes them the largest silent TOP-leak (a
2026-07-11 transcript audit measured 7/7 dispatches at the session top model).
The tier assignment:

| Built-in | Tier | How |
|---|---|---|
| `Plan` (design/architecture) | TOP | No override — inherit is intended; this is judgment work |
| `Explore` (codebase exploration) | **MID default** | Explicit `model` override on every dispatch. Deliberate exception to the fan-out-LOW default: exploration quality degrades visibly below MID, and a wrong map costs more than the tier saves |
| `Explore` (simple file/pattern lookups) | LOW | Explicit low-tier override when the task is a bounded search, not comprehension |
| `general-purpose` and other unpinned types | MID default | Same rule: an unpinned dispatch without an override is a policy violation, not a neutral default |

Synthesis of subagent results stays in the main loop (TOP — orchestration
judgment). `core/hooks/model-routing-observer.py` records every Task/Agent
dispatch's verdict (`override` / `pinned_specialist` / `inherit_top`) to
`.agent/logs/model-routing.jsonl`, so this convention is measured, not assumed.
`core/infra/manager-audit.sh` (consumed by `/manager-audit`) audits those
records after a supervise run — TOP-inherit leaks, floor violations, and a
relative spend ranking whose tier multipliers (LOW 0.15 / MID 1 / TOP 3.5)
are midpoints of the relative ranges above, never prices. Its `--global`
mode drops the plan-slug and run scope to sweep the *whole* routing log for
the same leaks that happen outside any supervise run — ad-hoc `Explore` /
execution dispatches that silently inherit the session top model — so the
convention is measured for one-off work too, not only inside `/supervise`.
Measurement alone doesn't change behavior — a 2026-07-11 audit found 7/7
dispatches inheriting silently even with the observer live — so
`core/hooks/model-routing-advisor.py` adds a decision-time counterpart: a
PreToolUse advisory on the same Task/Agent dispatches, one line of
`additionalContext` when a call is about to leak (see "What this policy
deliberately does not do" for why this stays advisory, not enforcement).

These two hooks only fire when a dispatch is *attempted* — they are blind to
the leak where the TOP model does the implementation directly and no
Task/Agent call happens at all. A 2026-09-02 transcript audit measured that
leak: 511 direct main-loop Edit/Write calls across 26 sessions (17 sessions
with 10+ edits, one at 65), with earlier single-fire advisories proven
insufficient — ignored well past their first warning. `core/hooks/top-edit-advisor.py`
adds a third, accumulation-time layer: a PostToolUse advisory on the TOP
model's own Write/Edit/MultiEdit calls that repeats every +15 measured edits
(env `AGENT_TOP_EDIT_THRESHOLD`) instead of warning once and going silent,
and never caches a not-TOP verdict, since the session model can switch
mid-session. Same boundary as the other two: advisory only, never blocks,
never switches a model.

## Intelligence placement — the advisor pattern

Three placements of TOP-tier intelligence exist, chosen by task shape
(economics and published measurements: `docs/concepts/cost-effective-harnesses.md`):

| Placement | When | This harness's instance |
|---|---|---|
| **Orchestrator** | Judgment concentrates upfront (plan, decompose, delegate) | The main-loop judgment rows above; `/supervise` wave dispatch |
| **Advisor** | Judgment is *scattered* across an exploratory task — each result reshapes what's worth trying next | `/supervise` audit-after-wave: a TOP-judgment checkpoint re-ranking MID execution mid-run |
| **Verifier / judge** | Judgment concentrates at review | `/verify-completion` refute-by-default judge (MID floor, below) |

Orchestrator corollary: **the brief's clarity is a cost control with the same
leverage as the tier pin.** The largest published orchestrator measurement
(Cursor's 2026-07 swarm run — same task, same final score, TOP-planner +
cheap-workers at roughly **1/8** the cost of TOP-everywhere) also measured the
failure mode: a frontier planner whose briefs were less explicit made the
cheap workers burn several times the tokens filling the gaps, erasing the
hybrid saving (`docs/concepts/cost-effective-harnesses.md`). An ambiguous
delegation contract silently converts planner savings into worker spend —
which is why the restatement-quality audit lane and the dispatch-prompt rules
(LE-9) sit in the cost path, not the style path.

The advisor rule worth encoding: **checkpoints stay TOP-tier and recur
mid-run.** A single upfront TOP ranking is not where advisor value
concentrates — measured on an exploratory ML-engineering task, the frontier
model's initial ranking was *anti-correlated* with outcomes, while recurring
mid-run checkpoints captured ~90% of frontier-solo quality at ~34% of the
cost (details in the concept doc). Cheap executors hill-climb marginal gains;
the checkpoint's job is stepping back and re-prioritizing. This stays a
documented convention — no new agent, no new mechanism, consistent with the
no-runtime-switching decision below.

## Floors

- **Verify/judge floor: never below the workhorse (MID) tier.** The
  refute-by-default judge in `/verify-completion` is a completion *gate*; a
  low-tier judge produces plausible-sounding false CONFIRMED verdicts and
  silently disables the gate. If the session itself runs on a low tier, the
  judge dispatch must carry an explicit model override up to MID.
- **Fan-out workers default LOW.** Sub-agents dominate token spend in
  multi-agent runs (~15× a single-context chat session —
  anthropic.com/engineering/multi-agent-research-system), which makes worker
  tier the single largest cost lever. Default fan-out workers to LOW and
  promote individually — never promote the whole wave.
- **Coordination-cost floor — when not to delegate.** Every handoff carries a
  roughly fixed cost: boundary tokens are billed at least twice (the lead
  writes a brief the worker reads; the worker writes a report the lead
  reads), and non-communicating parallel workers duplicate reads. Below a
  threshold task size this inverts the economics — on a small research task,
  solo TOP was measured *cheaper* than TOP-orchestrator-plus-cheap-workers
  (+60% markup for no benefit), while the same split on a large task hit 96%
  of the score at 46% of the cost
  (`docs/concepts/cost-effective-harnesses.md`). Delegate only when the
  delegated volume dwarfs the handoff; a dispatch whose payload is comparable
  to its own brief+report boundary has negative savings — do the work inline
  or fold it into an adjacent dispatch.
- **Prompt-cache preservation — reuse workers.** Each worker maintains its
  own prompt cache. Route repeat calls at the same context to the *same*
  worker (continue the live subagent with a follow-up message) instead of
  fresh-spawning per request — a fresh spawn re-pays the full context write
  uncached, and a low cache hit rate can erase the entire benefit of a
  cheaper per-token worker. Standing exception: **verifiers are always fresh
  spawns** — the verifier-isolation floor beats the cache saving.
- **Long-horizon implementation is not a LOW-tier task.** An external
  benchmark with a program-based verifier (github.com/datacurve-ai/deep-swe:
  113 long-horizon SWE tasks, 0.3% false-accept; leaderboard as of 2026-05,
  press-reported) shows light-tier models trailing the top tier by ~40+
  points on this class of work. Cited here as cost/performance reference
  data, not as a harness design source. LOW is for *bounded* mechanical work
  — lint/type cleanup, lookups, fan-out scans — where the task either
  succeeds cheaply or fails visibly. A light model that fails the task saves
  nothing; its cost saving is negative.

## The effort axis

Tier (which model) and effort (how hard that model thinks) are two separate
dials — a vendor-published 2026-09 study ("Spending your effort", vendor
blog, 2026-09) measured effort as the primary *verification-budget* dial:
raising it buys large accuracy gains only in domains with many hidden edge
cases (security 64%→87%, hardware 34%→75% in the cited study), and buys
almost nothing in ops/docs-shaped work — because a detailed enough spec
already forecloses most of the edge cases effort would otherwise have to
find. That is the same finding `spec-gate` already assumes operationally: a
task that passed the spec gate with a concrete spec is safe to implement at
low effort, because the spec did the edge-case work up front; a task with no
spec is where effort has to do it instead.

Default effort per pipeline stage (a starting point per call —
`docs/concepts/fable-5-prompting.md` rule 1, "effort before tier-up", still
governs promoting effort before promoting tier):

| Stage | Default effort | Why |
|---|---|---|
| `/spec` (brainstorm → spec.md/plan.md) | low | Interview + read-only probing do the edge-case-finding; the model is drafting against what the user already surfaced, not discovering it |
| `/supervise` implementation waves | low → medium | A wave dispatched against an approved, concrete plan is spec-gated work — the plan already forecloses most hidden edge cases; promote to medium only for a wave with no prior spec-gate pass |
| Code review (`code-reviewer`, council lanes) | high | Reviewing is exactly the "hidden edge case" shape the vendor study measured gains in — a shallow pass misses the defect it exists to catch |
| `/verify-completion` terminal verdict | high | A refute-by-default judge that verifies at low effort silently degrades into a rubber stamp — the gate's entire value is in the verification budget |
| Security review (`security-reviewer`) | max | The domain the vendor study measured the largest gain in (64%→87%); this is also the one TOP-F reservation (see The ladder) — tier and effort both maxed together, deliberately, for the one review class where a missed finding is a security incident |

**How the harness records this today.** Effort is not yet a silent default —
it is a stated field: agents carry an `effort:` value alongside their
`model:` pin in frontmatter, and the dispatch-observation hooks that already
log tier decisions (`model-routing.jsonl`) log the effort level a call
actually ran at, so the table above is checked against what happened, not
just what this doc recommends.

## Enforcement map

| Runtime | Mechanism | Where |
|---|---|---|
| Claude Code — specialist pins | `model:` frontmatter, **enforced**: CI `validate-plugin` drift guard reconciles registry ↔ frontmatter | `agents/*.md`, `agents/master-registry.json` |
| Claude Code — judgment unpinned / per-call MID (execution dispatch) & LOW overrides; coordination-cost check and worker-reuse (cache) | Convention, documented not CI-checked (frontmatter *absence*, call-time overrides, and call-time reuse-vs-spawn choices are not statically verifiable) | `skills/supervise/SKILL.md` Model policy |
| Claude Code — decision-time reminder | `model-routing-advisor.py` (PreToolUse Task/Agent), advisory: one-line `additionalContext` nudge, never blocks, decision stays with the dispatcher | `core/hooks/model-routing-advisor.py`, `docs/gate-registry.md` GATE model-routing-advisor |
| Claude Code — accumulation-time reminder | `top-edit-advisor.py` (PostToolUse Write/Edit/MultiEdit), advisory: `systemMessage` every +15 measured main-loop edits, never blocks | `core/hooks/top-edit-advisor.py`, `docs/gate-registry.md` GATE top-edit-advisor |
| Codex CLI | GPT-6 named profiles (per-profile config files): `quick` = LOW (`gpt-6-luna` @ low effort), default = MID (`gpt-6-sol` @ medium effort), `deep` = TOP (`gpt-6-astra` @ xhigh effort); `model_reasoning_effort` is the effort dial | `adapters/codex/codex-config.toml.template` + `quick.config.toml.template` / `deep.config.toml.template` |
| Gemini CLI (direct `oauth-personal`) | `settings.json` default model = workhorse; callers escalate with explicit `-m`. Retired for individuals (2026-07-17) — see the Cross-vendor lane note below; kept here only as the adapter-template record | `adapters/gemini/gemini-settings.json.template` |
| Antigravity (the live gemini lane) | Tiers keyed by model ID in a single tiers file the antigravity-worker resolves per call — MID/TOP entries, moved from the vendor-owned directory to a harness-owned path so an agy CLI reinstall can't silently reset the pin; `--effort` flag optional alongside the tier's own baked-in reasoning level | `~/.agent/antigravity-tiers.json` (installed from `adapters/antigravity/antigravity-tiers.json.template`), `adapters/antigravity/antigravity-worker.sh` |
| Claude Code — purpose launchers | Session-start human choice of tier/gateway (`claude-build`/`claude-quick`/`claude-research`/`claude-ox`); a launcher presets the model before the session exists — the allowed side of the no-runtime-switching line | `adapters/claude-code/launchers/`, `docs/launchers.md` |

**Codex pin drift**: the Codex row's model IDs are a snapshot. Which family each tier uses
lives in `~/.agent/codex-tiers.json` (`adapters/codex/codex-tiers.json.template`, families
only — no model IDs, same rule as the antigravity tiers file), and
`core/infra/codex-models.py` resolves the current ID from codex's local catalog, probes it,
and updates the profile on request (models whose probe failed are skipped for 30 days, so an
unusable catalog entry does not re-raise the advisory). `call-worker.sh` also retries once on the successor
when codex rejects a pinned model. Details: `adapters/codex/README.md`.

## Cross-vendor second-opinion lane

A Claude session can dispatch Codex as a review/verification **second
opinion** — a different vendor's model judging the same diff or claim, so a
shared blind spot doesn't survive review.

- **SSOT (machine-readable): `core/infra/backends.json`** — role → backend →
  CLI argv. Roles shipped: `second-opinion-review` and `second-opinion-verify`
  (codex primary, `kiro-openai` fallback). Model names deliberately never
  appear in the registry or the dispatcher: each vendor's adapter profile owns
  its tier (the rows above — `codex --profile deep` is the TOP-tier reasoning
  profile; `kiro --agent <profile>` pins its model in
  `adapters/kiro/*.json.template`), so tier policy stays in one place.
- **Gateway backends (2026-07-30).** Kiro CLI is one credential reaching many
  vendors, so it registers as several backends — `kiro-openai`, `kiro-zhipu`,
  `kiro-anthropic` — each carrying the vendor it actually reaches plus
  `"gateway": "kiro"`. The split is not cosmetic: a second opinion is only
  independent when its vendor differs from the dispatching session's, and a
  single `"vendor": "aws"` entry would hide a Claude-session-reviewing-Claude
  lane behind a label that looks cross-vendor. Kiro lanes are read-only by
  profile — verified that a profile's tool list overrides even
  `--trust-all-tools` — so they carry review/verify/advisor, never
  `implementer`. Auth is `KIRO_API_KEY` (Pro-tier) and no kiro-cli subcommand
  reports auth failure via exit code, hence the `kiro-preflight` probe — a real
  round trip that must get one exact token back, composed from the registry's own
  `cmd` + `tier_args` so it exercises the `--agent` resolution the dispatch uses
  (billable: it rides the lane's cheapest profile). `adapters/kiro/README.md` has
  the measurements, the cost note and the lapse path.
- **Gateway isolation.** A gateway CLI resolves its profile from the working
  directory first (`./.kiro/agents/<name>.json` beats `~/.kiro/agents/...` —
  measured), so `call-worker.sh` dispatches any backend carrying `"gateway"` from
  a neutral `mktemp -d` it owns, never the caller's cwd. Otherwise the repository
  under review could replace a read-only profile with a `shell`+`write` one; a
  pre-dispatch scan cannot close that (plant-after-scan wins). Non-gateway
  backends still inherit the caller's cwd.
- **Gemini backend: retired (2026-07-17) for direct `oauth-personal` access,
  re-enabled (2026-08-20, #114) via an Antigravity worker bridge.** Upstream
  deprecated `oauth-personal` for individuals (gemini-cli 0.44–0.46 throws
  `IneligibleTierError`; a cached credential got 401 UNAUTHENTICATED). Rather
  than wait on that path, the `gemini` backend in `core/infra/backends.json`
  now dispatches through `antigravity-worker` (`cmd`) with an
  `antigravity-preflight` health probe — `enabled: true`, `third-opinion-review`
  live. `third-opinion-review` still carries `fallback: null` on purpose —
  falling back to `kiro-openai` would duplicate the codex lane's vendor and
  fake the council's independence signal; an absent lane is reported absent
  instead of silently substituted.
- **Grok advisor lane (2026-08-19).** `grok` registers enabled as vendor `xai`
  carrying the **`advisor-third`** role only — deliberately wired to NO gate
  role: Grok 4.6 benchmarks a tier below the frontier on code correctness, so
  the lane exists for perspective diversity, is opt-in per consumer
  (`/council-review --with-grok`), and its findings are tagged
  `[grok:advisory]` and never flip a verdict. Read-only is OS-enforced by
  `grok-worker.sh` (sandbox-exec deny-write + neutral cwd) because the CLI's
  own flags demonstrably do not block writes — measurements in
  `adapters/grok/README.md`.
- **Dispatcher: `core/infra/call-worker.sh <role> < prompt.md`** — captures
  the reply to `.agent/workers/<ts>-<role>.md` and prints the path. External
  calls cost money: without `AGENT_WORKER_YES=1` it refuses (exit 3). The
  gate is env-only by design — a headless caller cannot answer an interactive
  confirm; the session that owns the user relationship asks first, then sets
  the env per invocation. A missing CLI names the missing tool (exit 127), a
  fallback records why the primary was skipped, a hung worker is killed at
  `timeout_s` (exit 124).
- **Consumption**: `/verify-completion --second-opinion` attaches the capture
  as evidence input to the semantic judge; the gate logic itself is unchanged
  (a second opinion informs the verdict, it never replaces the judge).
  `/council-review` consumes the review roles in parallel — codex
  (`second-opinion-review`, implementation-correctness lens) + gemini
  (`third-opinion-review`, architecture/consistency lens) beside the Claude
  `code-reviewer` agent, grok (`advisor-third`) opt-in and deliberately
  unscoped — and synthesizes with citation verification against the actual
  files. Lens preambles (emphasis, not permission) live in
  `skills/council-review/SKILL.md` step 1.
- **Conditional council auto-escalation (2026-08-20).** A council-scale diff
  (changed lines ≥ `AGENT_COUNCIL_LINES` [200], changed files ≥
  `AGENT_COUNCIL_FILES` [10], or a risk-area path — `core/infra/council-threshold.sh`,
  mirroring `spec-gate.py`'s `GUARD_PATTERNS`) denies a plain Claude-solo
  `code-reviewer` dispatch (`core/hooks/council-escalation-gate.py`, PreToolUse
  Task/Agent) and points the caller at `/council-review --staged` instead. This
  is a LANE decision (Claude-solo vs. multi-vendor council), not the MODEL-tier
  escalation the policy rejects above — the per-call model still is whatever
  the dispatcher chooses; the gate only routes which reviewer(s) run. The
  per-invocation cost-approval prompt (`AGENT_WORKER_YES=1`) is unchanged —
  the gate enforces routing, it does not pre-approve spend. Small/routine
  diffs are unaffected (silent allow); a diff below threshold never touches
  this gate.
- **Review cadence (2026-09-02).** Review dispatches are the second-largest
  routing cost after implementation, so cadence is a lever alongside model
  tier. `core/infra/review-tier.sh` (`skills/wrap/SKILL.md` step 1d's SSOT;
  it delegates the tier-2 judgment to `council-threshold.sh` rather than
  re-mirroring its risk-area patterns) assigns every diff exactly one tier:
  **tier 0** — docs-only or ≤`AGENT_REVIEW_SKIP_LINES` (default 50) non-risk
  code lines — skip, self-check only, no reviewer dispatch; **tier 1** — the
  common case — one `code-reviewer` pass at wrap/commit time; **tier 2** —
  council-scale (line/file threshold or a risk-area path) — `/council-review`.
  Risk-area paths (auth/secret/billing/migration) still get immediate review
  regardless of tier — `security-reviewer`'s dispatch timing is unchanged by
  this policy.
- **Lane cost models (2026-08-20).** Onboarding is `/worker-setup`; this is
  its SSOT for what each lane actually costs. **grok** — the user's xAI
  account, operated on the free tier by design; a rate-limit hit fails open
  (lane skipped, retry later, no upgrade prompt — see the rate-limit
  contract above). **antigravity (gemini lane)** — the user's Google account
  quota (Antigravity free/AI Pro tiers), authenticated via the OS keyring.
  **codex** — the user's ChatGPT subscription quota. **kiro-* (openai/zhipu/
  anthropic gateway lanes)** — `KIRO_API_KEY`, metered/paid per call, and the
  preflight itself is a real billable round trip on the lane's cheapest tier
  (`adapters/kiro/README.md` § Cost of a preflight) — never free to check.
  **openrouter (`advisor-free`, 2026-08-25)** — OpenRouter `:free` routes,
  zero-cost by design (20 req/min, 50 req/day; 1,000/day after a one-time
  ≥$10 credit purchase); a 429 fails open exactly like grok. Free is not
  costless: a `:free` route's upstream provider may retain/train on prompts,
  so the worker refuses sensitive working directories (shared
  `~/.config/agent-harness/sensitive-paths` guard) and prints a retention
  warning on every dispatch — non-voting `advisor-free` role only, opt-in via
  `/council-review --with-free` (`adapters/openrouter/README.md`).
- **Free-lane allocation (designed 2026-08-25,
  `.agent/plans/free-lanes-and-launchers/spec.md`).** The former
  "tier/cost-aware task allocation" follow-up is now designed, and the
  allocation mechanism is deliberately *human-held and deterministic*: a
  purpose launcher chosen at session start (`docs/launchers.md`) decides the
  session's tier, and opt-in council flags (`--with-grok`, `--with-free`)
  decide which free advisory lanes run — prefer-free-over-metered is a
  standing caller guideline, never a classifier (see § What this policy
  deliberately does not do). New free lanes are wired only when all four GO
  criteria hold (sustained card-free quota; OpenAI-compatible endpoint; ToS
  clean for proprietary code; adds a vendor not already in the roster) AND a
  consumer role needs the lane. Evaluated 2026-08-25: **NVIDIA NIM —
  deferred** (trial-only credit pool; API Trial ToS forbids confidential
  input §2.6(a) yet collects content to improve NVIDIA models §3.3);
  **Groq — strongest future candidate** (sustained, OpenAI-compatible,
  ~14,400 req/day), unwired pending a role that needs its Llama/GPT-OSS-class
  roster; full survey in the spec doc.
- **Tests**: `core/tests/call-worker-test.sh` — PATH-stubbed backends, every
  contract path (including gateway cwd isolation), zero paid calls in CI.

## What this policy deliberately does not do

- **No runtime model-switching hooks.** A per-prompt classifier that picks a
  model was evaluated and rejected (config-coupled, opaque, and it moves a
  human-auditable decision into a hook). `/manager-audit` stays on the right
  side of this line: it detects violations after the fact and writes patch
  *proposals* for user approval — it never switches anything at runtime.
  `model-routing-advisor.py` also stays on this side: it is a *deterministic*
  PreToolUse reminder (fixed classification, fixed message, no model logic),
  it never sets `permissionDecision`, and it never touches `model` — the
  dispatcher reads the nudge and still makes the call. `top-edit-advisor.py`
  is the same shape one layer later: a deterministic PostToolUse reminder
  keyed on a measured edit count, never a decision. The boundary is
  narrower than "no automated behavior at decision time"; it is "no automated
  *decision*" — a reminder is inside that line, a classifier or a switch is not.
- **No automatic tier escalation.** Promotion is a caller decision, made
  per-task, visible in the invocation.
- **No dedicated low-tier agents.** The LOW rung is reached with a per-call
  override, not by shipping more agents; the agent roster stays curated.
- **No price constants.** Tiers are relative; absolute prices live outside
  the repo.

## Currency log

Dated re-verifications of this policy against the live model landscape (the
tier table itself is generation-agnostic, so entries here record *that* the
mapping was checked, not new mappings):

- **2026-07-27** — verified against official vendor docs. Claude: the shipped
  reviewer pins are generation-neutral aliases (`sonnet` / `opus`) which the
  runtime resolves to the current generation (Claude 5 family at check time),
  so the pins self-update and need no edit; the LOW rung's `haiku` alias is
  likewise current. Codex: the adapter profile templates (quick=low-effort
  light tier, deep=high-effort top tier, PR #88) match the current GPT-5.6
  lineup; a newer above-top variant (client-side since 2026-07) is a **watch
  item** for the deep profile — per effort-before-tier-up, no promotion
  without benchmark evidence (backlog MC series,
  `internal/harness-improvement-plan.md` §4.13). Intro/promotional pricing on the current mid tier is noted as a
  cost tailwind but changes no mapping (no price constants in-repo).

- **2026-08-25** — free-lane wiring + launcher set landed (spec:
  `.agent/plans/free-lanes-and-launchers/`). OpenRouter `:free` catalog
  re-verified: DeepSeek/Qwen free variants delisted during 2026; lane pin =
  `nvidia/nemotron-3-super-120b-a12b:free` (live preflight pass), alternate
  `z-ai/glm-5.2:free` (research shortlist #1, but 429 on both live probes)
  (tiers file only — no registry constants). NIM evaluated and deferred
  (ToS), Groq noted as strongest future free candidate. Kiro:
  kiro-cli reinstalled (brew cask 2.19.1) after being found absent — the
  binary absence itself needed no registry change (enabled=policy /
  preflight=machine-reality), but the 2.19.1 roster turned out to have
  dropped all OpenAI models and `claude-opus-5`, which IS registry territory:
  `kiro-openai` disabled (dated reason), its same-vendor fallbacks nulled on
  the codex roles, `kiro-anthropic-top` re-pinned to `claude-sonnet-4.5`
  (`adapters/kiro/README.md` § Tier ladder has the roster-recheck rule).
