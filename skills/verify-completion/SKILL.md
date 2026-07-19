---
name: verify-completion
description: Independently re-verify a completion claim in a separate context — mechanical evidence (files/tests/assertions) plus a refute-by-default semantic judge — before a wave or task is allowed to be called "done". Emits the shared verdict schema. NOT for code-style review (that is a reviewer's lane) and NOT for verifying work you authored in the same context — the verifier must be a fresh spawn.
when_to_use: A builder/executor has just reported a task or wave complete and you need a second, independent check before accepting it — "verify completion", "is this actually done", "/verify-completion <claim>", or the completion step of /supervise.
tools: Bash, Read, Grep, Glob
---

# /verify-completion

## Goal

Re-check a **completion claim** from a context that did **not** build the work
(the hooks-mastery builder-validator pattern), so "the builder says it's done"
is never the last word. It answers one question with evidence: *does the claim
match reality?* — and defaults to **REFUTED** on any doubt.

Two layers, and you run **both**:

1. **Deterministic** — `core/infra/completion-verify.py` mechanically checks
   that every cited file exists (and contains its declared substring), every
   cited test exits 0, and every cited assertion holds. This catches the common
   failure ("claimed file X" when X does not exist; "tests pass" when they fail)
   and cannot be argued with.
2. **Semantic** — a refute-by-default judgment that scripts cannot make: does
   the code actually *do* what the claim says, are the tests *meaningful*
   (not trivially-green), does the artifact match the stated intent? This is the
   LLM-judge layer of the eval harness.

Both emit the **same verdict schema** (`docs/scoring-convention.md`).

## The claim

A claim is a JSON/YAML file (by convention `.agent/claims/<slug>.yml`) the
builder writes, or that you reconstruct from the builder's report:

```yaml
claim:
  summary: "what the task asserts it accomplished"
  files:                       # each must exist; optional substring must be present
    - { path: "core/hooks/x.py", contains: "def new_guard" }
  tests:                       # each command must exit 0
    - "bash core/tests/x-test.sh"
  assertions:                  # mechanical claim<->artifact checks (each exits 0)
    - "grep -q start_new_session core/hooks/x.py"
```

If no claim file exists, **build one** from the builder's own words before
verifying — turning a vague "I added X and the tests pass" into a checkable list
is itself half the value.

## Steps

### 1. Deterministic pass

```bash
python3 core/infra/completion-verify.py --root "$PWD" .agent/claims/<slug>.yml
```

- Exit 0 + `"verdict":"CONFIRMED"` → every cited fact held. Proceed to the
  semantic pass (a green mechanical pass is necessary, **not** sufficient).
- Exit 1 + `"verdict":"REFUTED"` → **stop here for those items.** Report the
  `refutations[]` verbatim; the claim is false as stated. Do not "fix and
  re-run" silently — the builder owns the fix.

### 2. Semantic pass (independent context)

Spin up a **fresh** verifier context that has NOT seen the builder's reasoning —
dispatch `code-reviewer` (or `security-reviewer` if the change touches
auth/secrets/input handling), or a general reviewer subagent — a general
(unpinned) reviewer must carry an explicit `model` override at the workhorse
tier, or it silently inherits the session top model — and give it only:
the claim, the deterministic verdict JSON, and the actual diff/artifacts. Ask it
to **refute**, not confirm:

- Do the changed lines actually implement what `summary` claims, or do they only
  *look* like they do?
- Are the cited tests real assertions on behavior, or green-by-construction
  (asserting `true`, testing nothing, or not exercising the new path)?
- Is anything the claim omits that a reviewer would call incomplete (an
  unhandled case the summary implies is handled)?

Default each open question to **REFUTED**. A confirmation needs a reason; a
refutation is the resting state.

**Optional: a project rubric.** If the project defines `.agent/rubric.yml`
(from `templates/rubric.yml.template`), its dimensions are the project's own bar
for "done" — fold them into this pass. The *deterministic* dimensions are already
scored per commit by the `rubric-commit-judge` hook (advisory, appended to
`.agent/logs/rubric-score.jsonl`); refresh them with
`python3 core/infra/rubric-score.py --root "$PWD"`. The *semantic-only*
dimensions (those with no `grader_check`) are yours to judge here,
refute-by-default, exactly like the questions above. A failing rubric dimension
is a refutation like any other — this is the semantic half of the two-layer
rubric design, the deterministic half being the commit hook.

**Optional flag `--second-opinion`** — attach a cross-vendor opinion as
additional evidence input to this pass. Ask the user for cost approval, then:

```bash
AGENT_WORKER_YES=1 bash core/infra/call-worker.sh second-opinion-verify \
    < <claim + diff/artifacts>          # prints .agent/workers/<ts>-…md
```

Hand the captured file to the semantic verifier alongside the claim and diff.
The gate logic is unchanged: a second opinion is one more input the judge
weighs — it never replaces the judge, and a missing/failed worker call never
converts to a pass (dispatcher contract: `docs/model-routing.md`
§ Cross-vendor second-opinion lane).

**Judge tier floor: never below the workhorse (sonnet-class) tier**
(`docs/model-routing.md`). This judge is a completion gate — a low-tier judge
produces plausible-sounding false CONFIRMED verdicts and silently disables the
gate. If the session itself runs on a low tier, the judge dispatch must carry
an explicit `model` override up to the workhorse tier.

### 3. Combine and gate

Merge the two passes into one verdict (`docs/scoring-convention.md` schema):

- `CONFIRMED` **only if** the deterministic pass confirmed AND the semantic pass
  found nothing that survives scrutiny.
- Otherwise `REFUTED`, with every refutation (mechanical + semantic) listed.

Report:

```
verify-completion <slug>: CONFIRMED | REFUTED   (score S)
  mechanical: files P/T, tests P/T, assertions P/T
  refutations:
    - <verbatim, most-load-bearing first>
```

## Hard rules

- **Independent context is not optional.** The value is a second pair of eyes
  that did not build the thing. If you built it, you are not the verifier —
  dispatch one.
- **Refute-by-default.** Ambiguity, a missing file, an unverifiable claim, a
  trivially-green test → REFUTED. Never upgrade a doubt into a pass.
- **Never edit the work to make the claim pass.** The verifier reports; the
  builder fixes. Verifying and fixing in one context is the self-approval this
  skill exists to prevent.
- **A CONFIRMED verdict cites its evidence.** Score, dimension counts, and
  (for the semantic pass) the reason each doubt was resolved.
- **Evidence means artifacts, never replayed reasoning.** Grade files, diffs,
  exit codes, and tool-call results. Never ask the builder to reproduce or
  narrate its reasoning chain as proof — on frontier models that can trigger
  reasoning-extraction refusals, and it was always self-assessment, not
  evidence (`docs/concepts/fable-5-prompting.md` rule 8).
- **A dead reviewer is not a clean review.** An aggregated result of `raised: 0`
  (or `findings: 0`) is NOT clean when any dispatched agent errored or died at
  its session limit (`agents_error > 0`, session-limit failures, empty agent
  results) — check the run's journal/agent logs directly and re-run the dead
  reviews before accepting the aggregate. (Recurred twice in the field: the
  review never ran but looked passed.)
