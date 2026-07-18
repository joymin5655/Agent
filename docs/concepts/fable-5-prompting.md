# Concept — Prompting Frontier Models (Fable-5 Class)

Frontier reasoning models (Anthropic's Claude Fable 5 / Mythos 5 generation and
peers) change what dispatch prompts, delegation contracts, and verification
gates need to say. Capability went up; several old prompt habits became either
unnecessary or actively harmful. This doc distills the vendor guidance into the
rules the supervisor applies when it writes dispatch prompts — the harness
counterpart of a style guide for delegation.

Sources (accessed 2026-07):
- Anthropic, *Prompting best practices for Claude Fable 5* (platform docs,
  `docs/build-with-claude/prompt-engineering`)
- Anthropic, *How the agent loop works* (Agent SDK docs) — loop-side
  implications are audited separately in
  [`../loop-engineering-audit-2026-07.md`](../loop-engineering-audit-2026-07.md) §4.

Status: **advisory**. The supervise skill cites this doc when shaping dispatch
prompts; no machine gate enforces it yet (candidate manager-audit lane — see
the status table at the end).

---

## Where each rule lands in the harness

| # | Guide rule | Harness surface it shapes |
|---|---|---|
| 1 | Effort is the primary dial | [`../model-routing.md`](../model-routing.md) effort-before-tier-up; delegation-contract `model` field |
| 2 | Turns run longer; don't induce early wrap-up | dispatch prompts; delegation-contract Boundaries |
| 3 | Ground progress claims in tool results | delegation-contract acceptance criteria; `skills/verify-completion/SKILL.md` |
| 4 | State boundaries explicitly; give the why | delegation-contract Goal / Boundaries / constraints re-injection |
| 5 | Parallel subagents are cheap and reliable | wave shaping (fan-out cap, one writer per fileset) |
| 6 | Provide a memory surface | `RECORD.md`, goal-state DB, [`memory-discipline.md`](memory-discipline.md) |
| 7 | Working shorthand ≠ final summary | delegation-contract Output-format element |
| 8 | Never ask the model to reproduce its reasoning | verifier stance: grade artifacts, not replayed thinking |

---

## The eight rules

**1. Effort before tier-up — now with vendor backing.** Frontier models expose
an effort dial (`low`→`xhigh`/`max`); a lower tier at high effort often beats a
higher tier at low effort for bounded tasks. This is the same ladder rule
[`../model-routing.md`](../model-routing.md) already states — the effort dial
is per-dispatch, so a delegation contract that sets `model` should consider
stating the intended effort class too ("mechanical → low effort" / "verify
judge → high effort").

**2. Longer autonomous turns are the norm.** A hard task at high effort runs
minutes per turn and hours per session. Two prompt bugs follow: (a) prompts
that nudge the worker to "wrap up soon" or "summarize and stop" cause premature
turn-ending; (b) visible context-budget countdowns cause the model to
volunteer session handoffs and shrink its own work. Dispatch prompts should
say the opposite, explicitly: *act when you have enough information; do not
stop, summarize, or propose a new session on account of context limits —
continuity is the harness's job (state lives in `RECORD.md` / the goal DB,
not in your transcript).*

**3. Progress claims must be grounded in tool results.** The single
highest-value line to put in any long-running dispatch: *before reporting
progress, audit each claim against a tool result from this session; report
only work you can point to evidence for, and mark the unverified explicitly.*
Vendor testing found this nearly eliminates fabricated status reports. The
harness already institutionalizes the receiving side — verify-completion
grades refute-by-default, and delegation contracts require executable
acceptance criteria — this rule puts the same discipline inside the worker's
own reporting.

**4. Instruction-following is literal now — write boundaries, not lists.**
A frontier worker follows short, principled instructions well enough that
enumerating every forbidden behavior is no longer needed — but it will also
do *exactly* what the prompt says, including unrequested extras when the
prompt is silent. So every dispatch states: the goal, the non-goals ("report
findings; do not apply fixes"), and the *why* (the larger task this feeds,
who consumes the output). Motivation context measurably improves judgment
calls; it is not filler.

**5. Delegation got cheaper — the contract did not.** Frontier models dispatch
and manage parallel subagents reliably, which raises the ceiling on wave
width, not the discipline: the fan-out cap (3–5) and one-writer-per-fileset
still bind, because they guard coordination cost and file collisions, not
model capability. Prefer async dispatch (workers report back; the lead keeps
working) over blocking on each worker.

**6. Give every long runner a memory surface.** Models of this class perform
best when they can write lessons somewhere durable and re-read them at run
start. The harness's surfaces: the plan's `RECORD.md` (append-only run
ledger), the goal-state DB, and the memory conventions in
[`memory-discipline.md`](memory-discipline.md) — one lesson per entry, update
rather than duplicate, delete what proves wrong. A dispatch that spans
sessions should name which surface the worker writes to.

**7. Two registers: working shorthand vs. final summary.** Terse arrow-chain
shorthand between tool calls is fine — that's the worker thinking. The final
message is different: outcome first, complete sentences, no invented labels
or abbreviations from mid-run, written for a reader who saw none of the run.
Delegation contracts encode this in the Output-format element; workers whose
final message is unreadable working-log get their contract tightened, not a
post-hoc rewrite.

**8. Never ask a worker to reproduce its reasoning (hard rule).** Prompts
that instruct a model to transcribe, replay, or explain its internal
chain-of-thought in the response can trigger reasoning-extraction refusals on
frontier models — and they were always verification theater. The harness
stance stays: verifiers grade **artifacts** (files, diffs, exit codes,
transcripts of tool calls), never a worker's self-narrated thinking. When
auditing old skills or templates, delete any "show your reasoning
step-by-step in the output" instruction on sight.

---

## Status against the harness (2026-07)

| Rule | Status |
|---|---|
| 1 effort dial | aligned — `docs/model-routing.md` effort-before-tier-up; effort wording added to the contract template |
| 2 no early wrap-up | edited-now — anti-wrap-up line added to delegation-contract Boundaries |
| 3 grounded claims | edited-now — evidence-citation requirement added to acceptance criteria; verify-completion already refute-by-default |
| 4 boundaries + why | aligned — the four contract elements already carry goal/non-goal/why |
| 5 parallel delegation | aligned — fan-out cap and write single-threading unchanged by design |
| 6 memory surface | aligned — RECORD.md / goal DB / memory-discipline conventions |
| 7 two registers | aligned — Output-format element covers it |
| 8 no reasoning replay | edited-now — stated as a hard rule in verify-completion |
| enforcement lane | backlog — a manager-audit lane checking dispatch prompts against rules 2–4 is a named follow-up, advisory until then |
