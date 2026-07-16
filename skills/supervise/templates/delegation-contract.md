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
  stop and report instead of proceeding>

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

## Wave shaping — fan-out cap and lanes

- **Fan-out cap 3–5** concurrent workers per wave. A wave with more concurrent
  subtasks splits into consecutive waves — coordination costs grow faster than
  the parallelism pays past that width.
- **Handoff must pay for itself**: the contract+report boundary is billed
  twice in each direction (lead writes / worker reads; worker writes / lead
  reads). Do not dispatch a task whose delegated volume is comparable to its
  own boundary — fold it into an adjacent contract or do it inline. This is
  the economic grounding of the fan-out cap above; the coordination-cost
  floor lives in `docs/model-routing.md` → Floors.
- **Write single-threading**: one writer per fileset. Review and verify agents
  carry read-only toolsets (Read/Grep/Glob) — that toolset, guarded by the CI
  registry-drift gate, is the mechanical enforcement point.
- **Worker reuse over fresh spawns**: consecutive subtasks over the same
  fileset or context continue the *same* worker so its prompt cache
  accumulates — a fresh spawn per request re-pays the full context write
  uncached. Verifiers are always fresh (isolation beats cache).
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
