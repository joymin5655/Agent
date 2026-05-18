---
name: supervise
description: Dispatch a multi-wave plan to specialist agents with audit + risk-area abort. Supports --auto-push, --auto-merge, --goal-mode for budgeted runs.
when_to_use: User has a written plan and says "execute", "run the plan", "/supervise <slug>", or "full auto".
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
b. **Dispatch specialist(s)** based on the wave's content:
   - Wave touches `core/hooks/` → `code-reviewer` after
   - Wave touches tests → `test-engineer`
   - Wave touches auth/secrets → `security-reviewer`
   - Build errors mid-wave → `build-error-resolver`
   - New feature design needed → `architect`
c. **Execute** the wave's intended changes.
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

## Hard rules

- **Never skip the audit step.** A wave isn't done until the audit passes.
- **Never auto-retry a failed audit.** Hand off to the user.
- **Never bypass safeguards** even if the user said "full auto".
  "Full auto" = no clarifying-Q at decision forks; it doesn't disable
  safety gates.
- **Always emit broadcasts** at started / decision / committed / pr_opened /
  done / blocked (R12 / R13).
