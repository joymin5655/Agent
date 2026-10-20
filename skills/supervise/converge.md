# /supervise --converge

Loaded from step 2d of `skills/supervise/SKILL.md` when `--converge` is set and the
completion gate returns REFUTED (exit 1). It is the only capped exception to "never
auto-retry": the remaining gaps become a new plan wave instead of a STOP, like Spec
Kit's converge step.

1. Save the gate's last sink line (`tail -n 1 .agent/logs/completion-gate.jsonl`,
   or the `AGENT_COMPLETION_GATE_SINK` path when set — a superset of the
   `docs/scoring-convention.md` verdict) to `.agent/plans/<slug>/verdict-w<i>.json`.
2. Run:
   ```bash
   bash core/infra/plan-converge.sh <slug> --from .agent/plans/<slug>/verdict-w<i>.json
   ```
   If the remaining gap needs a spec change (a new decision or out-of-scope work),
   not code, add `--spec-change` instead — it stops with exit 7.
3. Act on the exit code:

| Exit | Meaning | Action |
|---|---|---|
| 3 | a `## Wave <N+1>: converge <k>` was appended to plan.md | under `--goal-mode` run `core/infra/supervisor-goal.sh add-wave <slug>`; re-count the plan's waves and continue. The converge wave runs after the remaining planned waves, like any other wave (claim, gate, audit) |
| 0 | converged (CONFIRMED, no uncovered decision) | continue normally |
| 5 | round cap: 3 converge waves already exist | STOP and report |
| 6 | no progress: the gaps repeat the previous converge wave | STOP and report |
| 7 | `--spec-change` | STOP; the user revises the spec |
| 4 | the appended wave failed plan-lint (plan restored) | STOP, report as a defect |
| 2 | usage, missing plan, malformed verdict | STOP, report as a defect |

On any STOP, leftover refutations go to RECORD.md `Outstanding`.

Review-lane must-fix findings may be fed the same way: write a verdict-schema JSON
whose `refutations` are the findings and pass it with `--from`.

`plan-converge.sh` never writes `spec.md`; the spec stays the human's contract.
