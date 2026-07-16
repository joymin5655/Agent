---
name: supervise
description: Dispatch a multi-wave plan to specialist agents with audit + risk-area abort. Supports --auto-push, --auto-merge, --goal-mode for budgeted runs. NOT for writing the plan itself (that is /spec), and NOT for a single small edit with no waves — just make the edit.
when_to_use: User has a written plan and says "run the plan", "/supervise <slug>", or "full auto".
tools: Bash, Read, Write, Edit, Grep, Glob
---

# /supervise

## Goal

Take a written plan (`~/.agent/plans/<slug>.md` with Wave 1..N sections)
and run it end-to-end, dispatching the right specialist agent for each
wave, auditing after each wave, and aborting on risk-area violations.

## Modes

| Mode | Behavior |
|---|---|
| `/supervise <slug>` | Default: full-auto. Dispatch, audit, advance. Stops on Wave fail or safeguard. |
| `/supervise <slug> --goal-mode` | Tracks state in SQLite via `core/infra/supervisor-goal.sh`. Resumable across sessions. |
| `/supervise <slug> --auto-push` | Each wave commits + pushes + opens PR. User merges. |
| `/supervise <slug> --auto-merge` | Each wave commits + pushes + admin-merges via `auto-ship.sh`. |

## Permission friction (plan-scope-allow prerequisite)

/supervise does not grant itself permissions. Whether wave edits hit the
native permission prompt is decided by the `plan-scope-allow` gate
(`docs/gate-registry.md`), which is active only when `AGENT_PLAN_ALLOW_MODE=on`
is exported, or — with the env unset — when the workspace resolves to the
`personal` trust tier (`docs/customization.md` § Trust tiers). In `collab`
workspaces, expect a prompt per edit; prefer report-first waves there.
Coverage is Write/Edit/MultiEdit only — Bash/MCP wave commands always keep
their own gates and prompts (extension is backlog LE-1). Hard safeguards
(risk-area abort, R4 mutex, gitleaks, test-failure abort) bind in every tier
and every mode, including full-auto.

### Dispatch pre-flight (before any edit wave leaves the main loop)

A dispatched subagent cannot answer a native permission prompt, and a
**background** dispatch auto-denies any tool call that would prompt — so an
edit wave dispatched without cleared permissions doesn't fail loudly, it
silently loses its Edit/Write calls and reports garbage. Before dispatching
an execution (file-editing) wave, confirm at least one of:

1. The plan-approval flag exists — `[[ -f /tmp/agent-plan-approved ]]`
   (written on ExitPlanMode approval; wiped at every SessionStart), which
   arms the `plan-scope-allow` gate above, **or**
2. The project's `.claude/settings.local.json` carries `Edit`/`Write`/
   `MultiEdit` in `permissions.allow` (project-layer rules are the reliable
   layer — subagents do not dependably inherit user-level allows).

If neither holds: dispatch the wave **foreground** (prompts then reach the
user) or stop and tell the user which of the two to set up. Never send an
edit wave to a background dispatch on an unverified permission surface.

## Model policy

Who runs on which model — and what enforces it:

| Work | Model | Enforced by |
|---|---|---|
| **Judgment** — planning/design, wave dispatch decisions (who does what), gate verdicts & abort/advance, result synthesis | The main session's top model. Runs in the main loop, or via an agent **without** a `model:` pin (inherit). Never dispatch judgment work to an agent pinned below the session model. | This rule — a convention (frontmatter absence = inherit; a call-time choice is not CI-checkable) |
| Specialist dispatch (`code-reviewer` → sonnet, `security-reviewer` → opus) | Each agent's own `model:` frontmatter | Runtime applies frontmatter; `validate-plugin` CI drift guard keeps `agents/master-registry.json` in sync |
| **Execution dispatch** — implementation waves | Workhorse (MID) tier, via an explicit `model` override on the Agent dispatch (no executor agent is shipped) | Delegation-contract `model` field (`skills/supervise/templates/delegation-contract.md`). CI guards the guardable half: the template's model field and reviewer/verifier read-only toolsets (registry-drift gate); the call-time override itself stays a convention |
| Mechanical fixes (build/type/lint cleanup), lookups, fan-out workers | Low tier, via an explicit `model` override | Per-call override — a convention |

The orchestrating session keeps judgment and dispatches hands: when a wave is
execution work, dispatch it at the tier the table names instead of doing it
inline at the session model. Inline execution at the top tier is the expensive
default this rule exists to prevent.

The supervise loop itself never overrides a model. `core/hooks/supervisor.py`
is a dispatch-suggestion stub — it matches intent to a specialist from the
registry; it does not read or set `model`. If you add an agent whose role is
planning or deep design, leave `model:` out of its frontmatter.

This table is the enforced (Claude) instance of the cross-runtime tier policy
in `docs/model-routing.md` — see that document for the Codex/Gemini columns,
the verify-judge floor, and the fan-out worker default.

## Steps

### 1. Plan validation

a. Read `~/.agent/plans/<slug>.md`.
b. Confirm it has Wave 1..N sections.
c. Run `bash core/infra/supervisor-goal-audit.sh score --plan <slug> --wave 1`
   — if verdict is `weak`, warn the user and ask whether to proceed.
d. If `--goal-mode`, initialise:
   ```bash
   core/infra/supervisor-goal.sh init <slug> <N> [<budget>] "<objective>"
   ```

### 2. Per-wave loop

For each wave i ∈ {1..N}:

a. **Read Wave i section** of the plan.
b. **Classify the wave and pick lanes** based on its content:
   - Judgment work (deciding, synthesizing) stays in the main loop.
   - Execution work dispatches with an explicit `model` per the Model policy
     (implementation → workhorse tier, mechanical cleanup → low tier), after
     the dispatch pre-flight above clears the permission surface.
   - Wave touches `core/hooks/` or general code → `code-reviewer` after
   - Wave touches auth/secrets → `security-reviewer`
   - **Never route an execution wave to `code-reviewer` or
     `security-reviewer`** — both carry read-only toolsets (Read/Grep/Glob,
     CI-enforced); they cannot edit a file at all. `core/hooks/supervisor.py`
     suggestions name specialists for the *review* lane, not the execution
     lane.

   Every dispatch is written as a **delegation contract** —
   `skills/supervise/templates/delegation-contract.md` (goal / output format /
   tools & scope / boundaries, plus an explicit `model` field per the Model
   policy). Four orchestration rules travel with it (details in the template):
   - **Fan-out cap 3–5** per wave — a wave with more concurrent subtasks
     splits into consecutive waves (the template shows a worked split).
   - **Write single-threading** — one writer per fileset; review/verify agents
     carry read-only toolsets, which the CI registry-drift gate enforces.
   - **Self-contained contracts** — subagents inherit no conversation history;
     the contract carries every needed path, decision, and constraint, with
     the wave's relevant constraint slice re-stated (not whole rulebooks).
   - **Verifier isolation** — verifiers are fresh spawns with no author
     context or self-assessment; they grade end-state only.
c. **Execute** the wave's intended changes — through the dispatched execution
   lane, not inline at the session model (inline is judgment's lane, not
   execution's).
d. **Audit**:
   ```bash
   bash core/infra/supervisor-goal-audit.sh <slug> <i>
   ```
   - PASS: continue.
   - FAIL: STOP. Report to user. Do not auto-fix and retry — the user
     decides next action.
e. **Advance** (if `--goal-mode`):
   ```bash
   core/infra/supervisor-goal.sh advance-wave <slug> <i>
   ```
f. **Wrap** (if `--auto-push` or `--auto-merge`):
   - Invoke `/wrap` with the appropriate flag.

### 3. Safeguards (immediate abort)

Stop the supervise loop immediately on any of these:

1. User says "stop" / "halt" / "cancel" / "pause".
2. Risk-area violation detected
   (`rules/policy/security-guards.md` 5 areas).
3. R4.1 file mutex blocked.
4. gitleaks failure at any stage.
5. Test suite failure.
6. Type-check / lint failure.
7. A dispatched review/verify agent died (session limit, API error) — treat the
   wave's audit as FAIL even if the aggregate reports 0 findings; a dead
   reviewer is not a clean review (re-dispatch or verify in the main loop).

On safeguard: emit `blocked` broadcast (R13), report state to user.

### 4. Token budget (--goal-mode)

If `--goal-mode` with a budget, after each tool call:

```bash
core/infra/supervisor-goal.sh track-tokens <slug> <delta>
```

When `status` transitions to `budget_limited`, the helper auto-writes
a graceful-wrap stub at `wiki/synthesis/<slug>-budget-limited-<date>.md`
and the supervise loop exits gracefully.

### 5. Completion

When wave N passes audit:

```bash
core/infra/supervisor-goal.sh complete <slug>     # if --goal-mode
```

Report:
```
Plan <slug>: COMPLETE
Waves: N/N
PRs opened: <list>
PRs merged: <list>
Outstanding: <deferred items from the plan>
```

Also write the same facts to `.agent/plans/<slug>/RECORD.md` — the
**repo-native execution ledger** (waves / PRs / audit verdicts / carried
items). The ledger is mechanical facts only; session narrative belongs to the
global recording layer, so the two never duplicate. On `--goal-mode` runs the
`complete` command drops a RECORD.md stub automatically (the deterministic
guarantee the file exists — it never overwrites one you already wrote); on
non-goal runs writing it is this step's discipline. This keeps an execution
record on runtimes that have no global recording layer at all.

## Hard rules

- **Never skip the audit step.** A wave isn't done until the audit passes.
- **Never auto-retry a failed audit.** Hand off to the user.
- **Never bypass safeguards** even if the user said "full auto".
  "Full auto" = no clarifying-Q at decision forks; it doesn't disable
  safety gates.
- **Always emit broadcasts** at started / decision / committed / pr_opened /
  done / blocked (R12 / R13).
