# Delegation contract — <wave N / task name>

One contract per dispatched agent. The contract IS the spawn prompt's skeleton:
a subagent does not inherit the lead's conversation history, so anything not
written here does not exist for the worker. Delegation quality is the largest
quality lever in multi-agent work — fill every section or state why it is empty.

## The four elements

- **Goal**: <one falsifiable outcome this dispatch must produce>
- **Output format**: <exactly what the worker's final message must contain —
  structure, required fields, length cap>
- **Tools & scope**: <tool allowlist + the fileset this worker may touch.
  One writer per fileset — never two writers on the same files in one wave>
- **Boundaries**: <what is out of scope, what must not be touched, when to
  stop and report instead of proceeding. Also state the anti-wrap-up rule for
  long runs: do not end the turn early, summarize, or propose a session
  handoff on account of context limits — continuity is the harness's job>

## Model

- **model**: <explicit tier for the work class — workhorse (MID) for
  implementation waves, low for mechanical/bounded fan-out work. OMIT the field
  (inherit the session model) only for judgment work: planning, gate verdicts,
  synthesis. Tier ladder and floors: `docs/model-routing.md`>

## Self-contained (no history assumed)

Write the contract as if the worker has never seen this conversation — because
it hasn't. Never reference prior discussion ("as agreed", "the approach we
chose"); restate the decision itself. Every path, constraint, and prior
decision the worker needs is written into this contract, or it is not part of
the dispatch.

## Constraints re-injection (per wave, relevant slice only)

Each wave's contract re-states the standing constraints that apply to ITS
fileset — the risk-area rules, style rules, or invariants a long-running plan
tends to drift from. Re-inject only the relevant slice, not whole rulebooks:
re-statement fights drift; bulk paste burns the worker's context.

## Executable acceptance criteria

Acceptance criteria are runnable commands by default — a check whose exit code
decides, e.g. `bash core/tests/<battery>.sh` exits 0, or a `grep -q` on a
required artifact. Prose criteria are allowed only with a stated reason why no
command can check the outcome. A dispatch whose completion cannot be checked
is not ready to send.

The worker's progress and done claims follow the same rule: each claim cites a
tool result from its own session (path, exit code, diff) — self-assessment
without evidence is not a status report. Prompt-side rules for frontier-model
dispatches: `docs/concepts/fable-5-prompting.md`.

## Cross-vendor lane dispatch (when the worker is an external CLI)

A dispatch that leaves the Claude runtime — a `core/infra/call-worker.sh` role
(`implementer`, `second-opinion-*`, `advisor`) — carries the same four
elements, plus:

- **Interfaces**: name the exact function/CLI/API surfaces the lane may rely
  on or must expose. An external lane shares no runtime with us, so an
  interface not written here does not exist for it.
- **Verification command**: the runnable acceptance check, stated in the spec
  itself — the lane runs it, and the caller RE-RUNS it on return.
- **Return format**: the lane report
  (`skills/supervise/templates/lane-report.md` — STATUS /
  OBJECTIVE / CHANGES / VERIFIED / LANE SAID / GAPS). The caller reads
  `git diff` and re-runs the verification command before accepting; a lane's
  own success claim is never evidence (claim ≠ evidence).
- **Spec transport**: unique temp file per dispatch, piped via
  `call-worker.sh <role>`; the printed capture's `status:` frontmatter is the
  mechanical record beneath the lane's self-report.

## Wave shaping — fan-out cap and lanes

- **Fan-out cap 3–5** concurrent workers per wave. A wave with more concurrent
  subtasks splits into consecutive waves — coordination costs grow faster than
  the parallelism pays past that width.
- **Write single-threading**: one writer per fileset. Review and verify agents
  carry read-only toolsets (Read/Grep/Glob) — that toolset, guarded by the CI
  registry-drift gate, is the mechanical enforcement point.
- **Verifier isolation**: verifiers are fresh spawns given this contract's
  goal and the end-state only — no author context, no author self-assessment.
  They grade what exists, not what the author says exists.

## Example — a wave split at the fan-out cap (fixture)

A plan wave with eight mechanical migration subtasks does not dispatch eight
workers. It splits:

```markdown
## Wave 2: migrate call sites (batch 1 of 2)
- worker A–D: one module each (model: low) → verify: module battery exits 0

## Wave 3: migrate call sites (batch 2 of 2)
- worker E–H: one module each (model: low) → verify: module battery exits 0

## Wave 4: review lane
- reviewer (read-only) over the combined diff → verify: findings list, zero writes
```

Two batches of four stay inside the cap; the reviewer runs as its own
read-only lane after the writers finish, never concurrently with them on the
same fileset.
