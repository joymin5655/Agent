# Supervisor /goal-mode

Long-running multi-wave plan execution backed by a SQLite state machine
(`core/infra/supervisor-goal.sh`). Inspired by Codex `/goal` mode.

## When to use

- Plans with ≥ 3 waves.
- Plans where partial completion is acceptable (token budget can run out).
- Plans you'll want to **resume** in a future session.

## Lifecycle (5 states)

```
init → active → advance-wave (loop) → complete
              ↘ pause / resume
              ↘ track-tokens (budget) → budget_limited
              ↘ abort
```

| State | Meaning |
|---|---|
| `active` | Currently running a wave. |
| `paused` | User explicitly paused (`pause` cmd). |
| `budget_limited` | `tokens_used >= token_budget`. Graceful wrap stub written. |
| `complete` | All waves done OR explicit `complete` cmd. |
| `aborted` | Safeguard tripped OR explicit `abort <reason>`. |

## Commands

```bash
bash core/infra/supervisor-goal.sh init <slug> <total-waves> [budget] [objective]
bash core/infra/supervisor-goal.sh status [<slug>]
bash core/infra/supervisor-goal.sh advance-wave <slug> <wave-num>
bash core/infra/supervisor-goal.sh pause <slug>
bash core/infra/supervisor-goal.sh resume <slug>
bash core/infra/supervisor-goal.sh complete <slug>
bash core/infra/supervisor-goal.sh abort <slug> "<reason>"
bash core/infra/supervisor-goal.sh clear <slug>          # remove from DB
bash core/infra/supervisor-goal.sh track-tokens <slug> <delta>
bash core/infra/supervisor-goal.sh heartbeat <slug>      # touch updated_at
bash core/infra/supervisor-goal.sh check-active          # all active w/ heartbeat <5min
```

## Token budget → graceful wrap

When `track-tokens` pushes `tokens_used >= token_budget`, the state
auto-transitions to `budget_limited` and `_emit_graceful_wrap()` writes
a stub at:

- `$AGENT_GRACEFUL_WIKI_DIR/<slug>-budget-limited-<date>.md`
  (default: `$REPO_ROOT/wiki/synthesis/<slug>-budget-limited-<date>.md`)
- `$AGENT_GRACEFUL_MEMORY_DIR/handoff_<date>_<slug>-budget-limited.md`
  (optional — set the env var to enable; useful for memory-tool integrations)

Resume in the next session:

```bash
bash core/infra/supervisor-goal.sh status <slug>
# user reviews, allocates new budget, then:
bash core/infra/supervisor-goal.sh init <slug> <total> <new-budget>
```

## Audit (per wave)

```bash
bash core/infra/supervisor-goal-audit.sh <slug> <wave-num>
```

Runs the verification commands from the plan's Wave N section, records
JSONL evidence at `.agent/logs/supervisor-goal-audit.jsonl`, scores
against the 5-dimension goal template
(`strong-goal-template.md`), and on FAIL auto-invokes
`supervisor-goal.sh abort`.

Score-only (no command execution):

```bash
bash core/infra/supervisor-goal-audit.sh score --plan <slug> --wave <num>
```

## 5 risk areas (Wave-level safeguard)

Each wave checks for risk-area crossings (see `security-guards.md`).
A crossing doesn't auto-abort; it forces an `ask` decision to the user.

## Recommended invocation pattern

```
1. Write a plan with N waves.
2. supervisor-goal init <slug> N <budget>
3. For each wave i:
   a. Execute the wave.
   b. supervisor-goal-audit <slug> i
   c. If PASS: supervisor-goal advance-wave <slug> i
   d. If FAIL: stop, fix, retry; or abort + revise plan.
4. supervisor-goal complete <slug>
```
