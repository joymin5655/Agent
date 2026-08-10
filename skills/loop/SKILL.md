---
name: loop
description: Run a mission as a bounded series of fresh-context, one-task-per-turn attempts against core/infra/loop-run.sh — hard attempt cap, per-attempt timeout, and a circuit-breaker on repeated GATE failures, resumable after a restart from on-disk state. NOT for a single one-off task (just do it directly), and NOT for improving this harness's own reviewer prompts (that mission is skills/harness-loop, which specializes this protocol under §5's TARGET/GATE rules).
when_to_use: The user wants a repeated-attempt improvement loop with a hard budget — "run a loop on X", "/loop <mission>", "keep trying with a cap on attempts" — or is resuming a loop session after a restart.
tools: Bash, Read, Write, Edit, Grep, Glob
---

# /loop

## Goal

Run a mission as a bounded series of attempts: pick one idea, make exactly
one change, grade it, keep or discard, and stop at a hard cap, a per-attempt
timeout, or two consecutive GATE failures (circuit breaker) — never on trust
alone. All mechanical enforcement (state, ledger, cap, breaker) lives in
`core/infra/loop-run.sh`; this skill is the iteration protocol that calls it.

## Relationship to skills/harness-loop

This skill is the generic protocol: fresh context per iteration, exactly one
task per iteration, resumable on-disk state, hard budget. `/harness-loop` is
a SPECIALIZATION of it for one fixed mission — improving this harness's own
reviewer prompts under §5's rules (fixed TARGET regex, GATE floor, branch
convention). If the mission is "improve the harness itself", follow
`/harness-loop` instead of the generic steps below — its numbered procedure
is the maintained regulation for that mission.

## Steps

1. **Mission intake.** From the request, determine: a slug (short,
   kebab-case), a TARGET file-path regex the loop may edit, a base ref (the
   mission's starting commit — usually HEAD), an attempt cap (default 5), and
   a per-attempt timeout in seconds (default 600). Confirm any ambiguous one
   with the user — a loop whose edit scope isn't pinned down is not this
   skill's contract.

2. **Initialize.**
   ```bash
   bash core/infra/loop-run.sh init <slug> --target '<regex>' --base <ref> \
     [--cap N] [--timeout-s N] --mission "<one-line description>"
   ```
   This creates the SQLite goal row (`supervisor-goal.sh`, attempts modeled
   as waves), the JSON state file, and the active-loop flag that arms
   `core/hooks/loop-write-guard.py` for the rest of the session.

3. **Iterate.** Each iteration is a fresh context turn — start a new
   conversation turn or subagent dispatch per iteration rather than carrying
   the previous iteration's reasoning forward, so each attempt is judged on
   its own diff, not on accumulated history — doing exactly one task:
   a. Pick one improvement idea within the declared TARGET.
   b. Edit only TARGET files.
   c. `git commit` the change.
   d. Grade it:
      ```bash
      bash core/infra/loop-run.sh attempt <slug> --desc "<=80 char idea summary>"
      ```
   e. Read the `LOOP:` line at the end of the output — the only line to act
      on:
      - `LOOP: continue` — the same output's `ATTEMPT: status=…` line says
        whether to keep this commit or `git reset --hard` back to the
        pre-attempt commit; then start the next iteration.
      - `LOOP: stop(cap)` or `LOOP: stop(circuit-breaker)` — the loop ended
        on its own; go to step 5.

4. **Resume after a restart.** A fresh session picks the loop back up with no
   special handling:
   ```bash
   bash core/infra/loop-run.sh status <slug>
   ```
   prints the state file, the goal's current wave, and the ledger tail —
   attempt numbering continues from there because every field lives on disk
   (SQLite + JSON), not in this conversation. The goal database is
   per-worktree (`.agent/locks/goal-state.db`); resuming from a different
   worktree needs its own `init`.

5. **End of loop — summarize and hand off.** When `loop-run.sh` reports a
   stop, summarize attempts made, best score, and what was kept vs discarded
   (from `.agent/loop/results.tsv`), then offer `/wrap` on the kept branch.
   Merging always requires human approval via `/wrap` — this skill never
   merges on its own; the loop's job ends at "PR ready for review."

## Guardrails

- `core/hooks/loop-write-guard.py` escalates edits to the grader/verifier
  surface (`core/tests/`, `evals/`, the guards themselves) to a human `ask`
  while the active flag is set. It is defense-in-depth, not the primary
  boundary — the primary boundary is `loop-run.sh attempt`'s own grader call,
  which fails closed to a discard on anything outside the declared TARGET.
- Never keep a commit `loop-run.sh attempt` discarded, and never widen the
  TARGET regex mid-loop without calling `stop` and re-`init`.
- If the mission is this harness itself, use `/harness-loop`, not ad hoc
  steps — its procedure is the maintained record of that mission's rules.
