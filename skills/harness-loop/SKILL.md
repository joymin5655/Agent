---
name: harness-loop
description: The §5 autonomous-improvement-loop procedure specialized to this harness's own reviewer prompts (agents/code-reviewer.md + agents/security-reviewer.md) — the mission-specific 9-step regulation layered on skills/loop's generic mechanics. NOT for an arbitrary mission (use /loop for that), and NOT for editing core/tests/, evals/, or the guards themselves — that is the grader's own surface and is off-limits to any candidate this loop produces.
when_to_use: The user wants to run the harness's own autonomous reviewer-improvement loop — "run harness-loop", "/harness-loop", "improve the reviewer prompts autonomously" — or is resuming a prior harness-loop session.
tools: Bash, Read, Write, Edit, Grep, Glob
---

# /harness-loop

> **HUMAN-ONLY-EDITED.** This file is the §5 "program.md analog"
> (`docs/harness-improvement-plan.md` §5.1): it states the loop's own rules.
> The loop agent reads it every iteration but must never edit
> `skills/harness-loop/SKILL.md` itself — TARGET below is fixed to the
> reviewer-prompt pair precisely so a candidate cannot rewrite the regulation
> it runs under. Changing this file is a deliberate, human-reviewed act
> outside any loop session.

## Mission

Apply the autonomous-improvement-loop procedure (§5,
`docs/harness-improvement-plan.md`) to this harness's own reviewer prompts.
Default TARGET (the only files a loop iteration may edit): `agents/code-reviewer.md`
and `agents/security-reviewer.md`. A hook-surface mission (editing
`core/hooks/`) is allowed only when the target hook already has its own
per-hook test battery (P1-3) — otherwise the grader's signal doesn't cover it
and the loop would be scoring blind.

This skill specializes `/loop` (`skills/loop/SKILL.md`) to one fixed
mission; all mechanical enforcement is still `core/infra/loop-run.sh` —
nothing here duplicates it.

## Procedure

Work on branch `harness-loop/<tag>` (e.g. `harness-loop/reviewer-precision-2026-08`).
Steps 2–9 repeat per attempt, subject to the cap, timeout, and
circuit-breaker checked in step 9.

1. **Check git state.** Confirm the current branch and commit (`git status`,
   `git log -1`) before touching anything — the loop must know exactly what
   "the mission's starting ref" (`--base`) means for this run.

2. **Edit TARGET only.** Pick one improvement idea and change only the
   declared TARGET files — by default `agents/code-reviewer.md` and
   `agents/security-reviewer.md`. No other file changes in this step,
   tracked or untracked.

3. **Commit.** `git commit` the TARGET-only change. This commit is the
   candidate `loop-run.sh attempt` will grade.

4. **Grade.** Run:
   ```bash
   bash core/infra/loop-run.sh attempt <slug> --desc "<idea, <=80 chars>"
   ```
   Internally this calls `bash core/tests/grade.sh --base <base ref> --target
   'agents/(code-reviewer|security-reviewer)\.md'` with output redirected to
   a run log — never straight into this conversation, which would be context
   pollution (C1 in the security review). **`--base` and `--target` are
   mandatory**: an unscoped grading call skips the TARGET-boundary check
   entirely, and `grade.sh` fails closed to `harness_score: 0` rather than
   score blind.

5. **Read the score / crash policy.** `loop-run.sh attempt` runs the
   `grep '^harness_score:'` on the run log for you: an empty match means the
   grader crashed (not a score of zero) — a genuine syntax-level crash gets
   ONE retry; a deeper defect discards the attempt with `status=crash` in the
   ledger, no retry.

6. **Off-target diff is an unconditional discard.** `grade.sh`'s INTEGRITY
   phase (armed by step 4's `--base`/`--target`) rejects any candidate whose
   committed diff touches a file outside TARGET — including the
   grader/verifier surface itself (`core/tests/`, `evals/`, the guards).
   There is no override for this from inside a loop iteration.

7. **Record the result.** `loop-run.sh attempt` appends exactly one row to
   `.agent/loop/results.tsv` via `core/infra/loop-ledger.sh` (append-only —
   `results.tsv` itself stays uncommitted; it is run state, not source).

8. **Keep or discard.** If the score improved — or tied AND the diff got
   smaller (the simplicity rule: a tie only keeps when it shrinks the diff,
   never when it grows it) — keep the commit and move the branch forward.
   Otherwise `git reset --hard` back to the pre-attempt commit before
   starting the next attempt.

9. **Check cap / timeout / circuit-breaker, then continue or stop.**
   `loop-run.sh attempt` enforces all three and prints the verdict itself:
   cap 5 attempts per session, each attempt killed at a 600-second
   (10-minute) timeout and recorded `status=timeout`, and two consecutive
   `harness_score: 0` attempts trip the circuit-breaker and abort the run.
   On `LOOP: continue`, return to step 2. On `LOOP: stop(cap)` or
   `LOOP: stop(circuit-breaker)`, stop: summarize attempts, kept commits, and
   best score, then offer `/wrap` on the kept branch. Merging is never
   automatic — a human reviews the PR.

## Notes

- `core/hooks/loop-write-guard.py` is defense-in-depth while the loop's
  active flag is set: it escalates a write to the grader/verifier surface to
  a human `ask`. It does not replace step 6 — `grade.sh`'s own INTEGRITY
  phase is the primary boundary.
- Manual trigger only. A human starts each `/harness-loop` session and
  reviews its output before the next one begins.
