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
| **TOP** | Planning, architecture, security review, deep design | 2–5× the workhorse |

**Effort before tier-up.** Before promoting a task one rung, raise the effort
dial *within* the rung first. A MID model at high effort beats a TOP model at
low effort for most bounded tasks, at a fraction of the cost.

## Work class → tier

Example IDs are a 2026-07 snapshot — model names drift; the tier semantics do
not. Prices are deliberately kept out of this document (they change faster
than any doc review cycle).

| Work class | Tier | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|---|
| Planning / architecture | TOP | Session's top model — agents **unpinned** (frontmatter absence = inherit) | `--profile deep` | top-tier model, caller-explicit `-m` |
| Orchestration judgment — work distribution, gate verdicts, result synthesis | TOP | Session's top model, main loop (never dispatched below the session model) | `--profile deep` | top-tier model, caller-explicit `-m` |
| Security review | TOP | `security-reviewer` pin (opus-class) | `--profile deep` | top-tier model, caller-explicit `-m` |
| Code review | MID | `code-reviewer` pin (sonnet-class) | mid model, caller-explicit `-m` + high effort | workhorse model |
| Implementation | MID | Dispatched at workhorse tier — explicit `model` override on the Agent dispatch; the session keeps judgment and dispatches hands | config default (unprefixed) | workhorse model |
| Verification judge | **MID floor** | **never below sonnet-class** — see Floors | mid model, high effort or above | workhorse model or above |
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
- **Long-horizon implementation is not a LOW-tier task.** An external
  benchmark with a program-based verifier (github.com/datacurve-ai/deep-swe:
  113 long-horizon SWE tasks, 0.3% false-accept; leaderboard as of 2026-05,
  press-reported) shows light-tier models trailing the top tier by ~40+
  points on this class of work. Cited here as cost/performance reference
  data, not as a harness design source. LOW is for *bounded* mechanical work
  — lint/type cleanup, lookups, fan-out scans — where the task either
  succeeds cheaply or fails visibly. A light model that fails the task saves
  nothing; its cost saving is negative.

## Enforcement map

| Runtime | Mechanism | Where |
|---|---|---|
| Claude Code — specialist pins | `model:` frontmatter, **enforced**: CI `validate-plugin` drift guard reconciles registry ↔ frontmatter | `agents/*.md`, `agents/master-registry.json` |
| Claude Code — judgment unpinned / per-call MID (execution dispatch) & LOW overrides | Convention, documented not CI-checked (frontmatter *absence* and call-time overrides are not statically verifiable) | `skills/supervise/SKILL.md` Model policy |
| Codex CLI | Named profiles (per-profile config files on recent CLI builds): default = workhorse, `quick` = LOW, `deep` = TOP; `model_reasoning_effort` is the effort dial | `adapters/codex/codex-config.toml.template` + `quick.config.toml.template` / `deep.config.toml.template` |
| Gemini CLI | `settings.json` default model = workhorse; callers escalate with explicit `-m` | `adapters/gemini/gemini-settings.json.template` |

## What this policy deliberately does not do

- **No runtime model-switching hooks.** A per-prompt classifier that picks a
  model was evaluated and rejected (config-coupled, opaque, and it moves a
  human-auditable decision into a hook).
- **No automatic tier escalation.** Promotion is a caller decision, made
  per-task, visible in the invocation.
- **No dedicated low-tier agents.** The LOW rung is reached with a per-call
  override, not by shipping more agents; the agent roster stays curated.
- **No price constants.** Tiers are relative; absolute prices live outside
  the repo.
