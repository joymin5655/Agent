# Model routing — cross-runtime tier policy

One canonical mapping from **work class → model tier**, applied across the
three supported runtimes (Claude Code, Codex CLI, Gemini CLI). The Claude
column is **enforced** (agent frontmatter pins + the `validate-plugin` CI
drift guard — see `skills/supervise/SKILL.md` → Model policy). The Codex and
Gemini columns are **conventions carried by the adapter templates**: those
runtimes read their own config files; the harness never switches a model at
runtime.

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
| Security review | TOP | `security-reviewer` pin (opus-class) | `--profile deep` | top-tier model, caller-explicit `-m` |
| Code review | MID | `code-reviewer` pin (sonnet-class) | mid model, caller-explicit `-m` + high effort | workhorse model |
| Implementation | MID | Session model, main loop | config default (unprefixed) | workhorse model |
| Verification judge | **MID floor** | **never below sonnet-class** — see Floors | mid model, high effort or above | workhorse model or above |
| Mechanical fixes | LOW | per-call `model` override on the Agent dispatch (no low-tier agent is shipped) | `--profile quick` | workhorse model |
| Lookups / search | LOW | per-call low-tier override | `--profile quick` | lightest model |
| Fan-out workers | **LOW default** | low-tier override; promote individual workers only when a task demands it | `--profile quick` | workhorse model |

## Floors

- **Verify/judge floor: never below the workhorse (MID) tier.** The
  refute-by-default judge in `/verify-completion` is a completion *gate*; a
  low-tier judge produces plausible-sounding false CONFIRMED verdicts and
  silently disables the gate. If the session itself runs on a low tier, the
  judge dispatch must carry an explicit model override up to MID.
- **Fan-out workers default LOW.** Sub-agents dominate token spend in
  multi-agent runs (~15× a single-context run is the documented consensus),
  which makes worker tier the single largest cost lever. Default fan-out
  workers to LOW and promote individually — never promote the whole wave.

## Enforcement map

| Runtime | Mechanism | Where |
|---|---|---|
| Claude Code | Frontmatter pins (specialists), frontmatter *absence* (planning = inherit), per-call `model` override (mechanical/LOW) | `agents/*.md`, `agents/master-registry.json`, CI `validate-plugin` drift guard |
| Codex CLI | `config.toml` profiles: default = workhorse, `quick` = LOW, `deep` = TOP; `model_reasoning_effort` is the effort dial | `adapters/codex/codex-config.toml.template` |
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
