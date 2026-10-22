# /supervise --converge

Loaded from step 2d of `skills/supervise/SKILL.md` when `--converge` is set and the
completion gate returns REFUTED (exit 1). It is the only capped exception to "never
auto-retry": the remaining gaps become plan work instead of a STOP, like Spec Kit's
converge step.

1. Save this wave's record from the gate's sink (`.agent/logs/completion-gate.jsonl`,
   or the `AGENT_COMPLETION_GATE_SINK` path when set) to
   `.agent/plans/<slug>/verdict-w<i>.json`. The sink is shared by every run, so select
   by slug and wave, never by position:
   ```bash
   jq -c --arg s <slug> --arg w <i> \
     'select(.slug == $s and (.wave | tostring) == $w and .mode == "block")' \
     "${AGENT_COMPLETION_GATE_SINK:-.agent/logs/completion-gate.jsonl}" \
     | tail -n 1 > .agent/plans/<slug>/verdict-w<i>.json
   ```
   The record is a superset of the `docs/scoring-convention.md` verdict. An empty
   file means the gate logged nothing for this wave: STOP and report it.
2. Run (`<i>` = the refuted wave's number):
   ```bash
   bash "<harness root>/core/infra/plan-converge.sh" <slug> --from .agent/plans/<slug>/verdict-w<i>.json --wave <i>
   ```
   If the remaining gap needs a spec change (a new decision or out-of-scope work),
   not code, add `--spec-change` instead — it stops with exit 7.
3. Act on the exit code:

| Exit | Meaning | Action |
|---|---|---|
| 3 | a `## Wave <N+1>: converge <k>` was appended | under `--goal-mode` run `bash "<harness root>/core/infra/supervisor-goal.sh" add-wave <slug>` BEFORE `advance-wave <i>` (advancing the last wave completes the goal and `add-wave` then refuses); wave i is still advanced, its gap is carried by the converge wave. Re-count the waves and continue |
| 8 | wave i is a planned wave and a converge wave after it is still pending: the new gaps were folded into it | continue; do NOT run `add-wave` (no new wave) |
| 0 | converged (CONFIRMED, no uncovered decision) | continue normally |
| 5 | round cap: 3 converge waves already exist | STOP and report |
| 6 | no progress: wave i is itself a converge wave and the new gaps are a superset of (or equal to) its own fix lines | STOP and report |
| 7 | `--spec-change` | STOP; the user revises the spec |
| 9 | plan/spec already fails `plan-lint` before any change (legacy specs need `## Must not` and `## Edge cases`; `- none — <reason>` is allowed) | STOP; fix the spec or plan, then retry |
| 4 | the written plan failed `plan-lint` (plan restored) | STOP, report as a defect |
| 2 | usage, missing plan or wave, malformed verdict, internal error | STOP, report as a defect |

On any STOP, leftover refutations go to RECORD.md `Outstanding`.

Review-lane must-fix findings may be fed the same way: write a verdict-schema JSON
whose `refutations` are the findings and pass it with `--from`.

`plan-converge.sh` never writes `spec.md`; the spec stays the human's contract.
Gap text comes from verifier output: the script flattens it to one line and
`supervisor-goal-audit.sh` never evaluates a `- fix:` step's text, only its verify command
(`→` or `->` marker); it runs that `completion-gate.sh` check as a dryrun liveness check.
