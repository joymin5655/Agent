---
name: verify-completion
description: Independently re-verify a completion claim in a separate context — mechanical evidence (files/tests/assertions) plus a refute-by-default semantic judge — before a wave or task is allowed to be called "done". Emits the shared verdict schema. NOT for code-style review (that is a reviewer's lane). Work you built in this same session is in scope — the check runs in a fresh spawned verifier, or in the --light pass, which reports that it is not independent.
when_to_use: A builder/executor has just reported a task or wave complete and you need a second, independent check before accepting it — "verify completion", "is this actually done", "/verify-completion <claim> [--light]"; 한국어 "진짜 끝났는지 검증", "완료 검증", "다 된 거 맞아?", "문제 없는거야?", "잘 된건지 확인해줘", "잘 된건지 검증해줘", "검증 완료한거지?", "완료된거야?", "반영 다 된 건지 확인해줘", "검증해줘" — or the completion step of /supervise. When the user asks whether work just reported as done really holds, invoke this before re-running commands or reading files yourself; the checking happens inside this skill. A question about progress on work still running, or a hunt for why something fails, belongs elsewhere. Applies even when you built it and feel sure — your own conviction is not evidence; the claim is checked by a fresh context or the --light single pass.
tools: Bash, Read, Grep, Glob
---

# /verify-completion

## Goal

Re-check a **completion claim** from a context that did **not** build the work
(the hooks-mastery builder-validator pattern; full mode — `--light` is the one
same-session exception and says so), so "the builder says it's done"
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

This skill's verdict stays **advisory** — whether/how to enforce it is a
consumer decision (`docs/scoring-convention.md` "Consuming a verdict": *"That
choice belongs to each consumer"*). The first BLOCKING consumer is
`core/infra/completion-gate.sh` (`docs/gate-registry.md` `completion-gate`
row), invoked from `/supervise`'s wave-audit step with `--verify-blocking`; it
wraps `completion-verify.py --require-evidence --diff-base` behind a liveness
canary and a hard `AGENT_VERIFY_BLOCKING=block` mode. This skill and that gate
are complementary, not redundant: the gate is the deterministic hard stop, this
skill's semantic pass is what a `needs_semantic` claim (one the gate cannot
mechanically refute or confirm) gets routed to next.

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
  decisions:                   # optional: one entry per spec D-ID the work settles
    - { id: D1, evidence: "core/hooks/x.py implements the chosen approach" }
```

`decisions` is optional and advisory (dryrun): the verifier reads
`.agent/plans/<slug>/spec.md` (`slug` = claim `slug`, else the claim file name
minus extension and `-w<N>`) and lists each `## Decisions` D-ID the claim does
not cover (non-empty `evidence`) under `advisories` in the verdict. It never
changes the verdict or exit code.

If no claim file exists, **build one** from the builder's own words before
verifying — turning a vague "I added X and the tests pass" into a checkable list
is itself half the value.

## Steps

### 1. Deterministic pass

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/completion-verify.py" \
    --root "$PWD" .agent/claims/<slug>.yml
```

- Exit 0 + `"verdict":"CONFIRMED"` → every cited fact held. Proceed to the
  semantic pass (a green mechanical pass is necessary, **not** sufficient).
- Exit 1 + `"verdict":"REFUTED"` → **stop here for those items.** Report the
  `refutations[]` verbatim; the claim is false as stated. Do not "fix and
  re-run" silently — the builder owns the fix.

### 2. Semantic pass (independent context)

**Blind to the builder's verdict.** The verifier receives the artifacts (diff,
files) and the **contract** — acceptance criteria, `spec.md` success criteria,
or the plan step — but NOT the builder's completion claim, summary, or "it
works" narrative. A verifier that has read "all tests pass" starts anchored on
it. The claim's *checkable list* (files, tests, assertions) is what step 1 ran;
the semantic judge derives its own expectations from the contract and then looks
at the artifact. Where no contract exists, state the intent in neutral terms
(what was asked for) and withhold how the builder says it went.

**Adversarial instruction wins over persona tone.** Whatever balanced or
courteous persona the dispatched agent carries, the prompt must say: "Your job
is to find why this is NOT done. Do not soften, do not give credit for effort."
**At most 3 cycles** of verify → builder fixes → re-verify; if still REFUTED
after the third, stop and escalate to the user with the open refutations.

Spin up a **fresh** verifier context that has NOT seen the builder's reasoning —
dispatch `code-reviewer` (or `security-reviewer` if the change touches
auth/secrets/input handling), or a general reviewer subagent — a general
(unpinned) reviewer must carry an explicit `model` override at the workhorse
tier, or it silently inherits the session top model — and give it only:
the contract, the deterministic verdict JSON, and the actual diff/artifacts
(not the builder's summary — see above). Ask it to **refute**, not confirm:

- Do the changed lines actually implement what `summary` claims, or do they only
  *look* like they do?
- Are the cited tests real assertions on behavior, or green-by-construction
  (asserting `true`, testing nothing, or not exercising the new path)?
- Is anything the claim omits that a reviewer would call incomplete (an
  unhandled case the summary implies is handled)?
- If the artifact only reveals its correctness when **run**, was it run and
  *looked at* — see the observation rule below?

Default each open question to **REFUTED**. A confirmation needs a reason; a
refutation is the resting state.

**Observation rule — run-only artifacts.** Some artifacts cannot be verified by
reading them: an HTML page, an SVG, a chart, a UI, a game, an animation, a script
whose whole point is its observable output. For those, a completion claim that
cites no observation evidence is **REFUTED**. Three distinctions do the work:

- **Well-formed is not correct.** `xmllint`, `node --check`, `tsc --noEmit`, a
  successful parse — each proves the file is syntactically valid, which is a
  different claim from "it renders and behaves as intended". A static check
  passes straight over an overlay covering the board, a console error, a collapsed
  layout.
- **Produced is not observed.** A screenshot that was generated but never read
  back is not evidence. Neither is "the server started". The claim must cite what
  was actually seen — rendered output read back, console output inspected, the
  state the interaction reached.
- **One clean observation is enough.** Re-rendering unchanged state to accumulate
  confidence spends tokens and changes nothing. Re-render only *after* a change:
  each defect the observation reveals gets one fix and one re-check, and it stops
  again once that check is clean.

Scope it honestly: pure prose, config, and logic that has its own test suite need
no rendering — for those the relevant grounding is the test run, already covered
by the deterministic pass. The trigger is precisely *"could this look or behave
wrong in a way that only shows when it runs?"* The `browse` / `run` skills are the
usual execution route; this rule is about whether the resulting evidence exists,
not about which tool produced it.

**Optional: a project rubric.** If the project defines `.agent/rubric.yml`
(from `templates/rubric.yml.template`), its dimensions are the project's own bar
for "done" — fold them into this pass. The *deterministic* dimensions are already
scored per commit by the `rubric-commit-judge` hook (advisory, appended to
`.agent/logs/rubric-score.jsonl`); refresh them with
`python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/rubric-score.py" --root "$PWD"`. The *semantic-only*
dimensions (those with no `grader_check`) are yours to judge here,
refute-by-default, exactly like the questions above. A failing rubric dimension
is a refutation like any other — this is the semantic half of the two-layer
rubric design, the deterministic half being the commit hook.

**Optional flag `--second-opinion`** — attach a cross-vendor opinion as
additional evidence input to this pass. Ask the user for cost approval, then:

```bash
AGENT_WORKER_YES=1 bash "${CLAUDE_PLUGIN_ROOT}/core/infra/call-worker.sh" second-opinion-verify \
    < <claim + diff/artifacts>          # prints ~/.agent/workers/<project-key>/<ts>-…md
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

**Judge effort floor: `high`** (advisory). Dispatch the judge with
`effort: high` or above — a refute-by-default judge at low effort degrades
into a rubber stamp (`docs/model-routing.md` → The effort axis).
`core/infra/completion-verify.py` is the deterministic pass only (file/test/
assertion checks via `subprocess`); it makes no model call, so it has no
effort parameter — the floor applies to the semantic judge you dispatch here.

### Modes: full vs `--light`

| | full (default) | `--light` |
|---|---|---|
| Context | fresh spawned verifier, blind to the builder's summary | the current session, single pass |
| Passes | deterministic + semantic judge | claim split into units, one refute-first evidence pass |
| Use for | waves, multi-file work, risk areas, anything `/supervise` accepts as done | one small claim ("fixed the typo", "config applied", "page renders") |
| Cost | judge at workhorse tier or above, up to 3 cycles | no dispatch, re-run commands only |
| Independence | yes | no — say so in the report |

`--light` procedure (read-only; fixing is a separate step after the verdict):

1. **Split the claim** into checkable units (e.g. "design applied" → file has the
   change; build passes; the rendered page shows it).
2. **Try to refute each unit first**, with fresh evidence only: `git diff` /
   `git status` or a grep for file claims; **re-run** test/build commands (never
   quote an earlier output, never hide the exit code behind `| tail`); a real
   render or screenshot for UI claims; the live URL's response for deploy claims.
3. **Judge per unit**: `CONFIRMED` with the evidence cited; `UNVERIFIED` when
   evidence is unobtainable (state what is missing — it does not count as done);
   `REFUTED` on any mismatch, reported immediately and never reinterpreted.
4. **Report one table.** Say "done" only when every unit is CONFIRMED, and note
   that same-context checking is weaker than full mode.

Escalate `--light` to full when a unit is REFUTED, when the change touches a risk
area, or when the user asks for independent verification.

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

- **Independent context is the default.** The value is a second pair of eyes
  that did not build the thing. Full mode always runs in a fresh spawned
  verifier — if you built it, you are not that verifier; dispatch one. The one
  exception is `--light` for a single small claim: it runs in this session and
  the report says it is not independent.
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
- **A reviewer that goes idle without a report is a FAILED lane, not a clean
  one.** This is the same trap by a different route: no session-limit error, no
  crash — the lane simply ends and delivers nothing, so the absence of findings
  reads as `raised: 0`. Judge a lane by its *artifact*: no report, no verdict.
  Request the report explicitly, and if it still does not arrive, re-dispatch a
  fresh lane and report the dimension as **unverified** until one completes.
  (2026-07-30: four security dispatches in one batch produced zero reports —
  two silent idles, one session-limit death, one spawn failure — while the code
  lane in the same batch completed normally and raised three confirmed defects.
  Machine-enforcing this is backlog X-4.)

## Credits

The blind-verifier rule, adversarial-over-persona instruction and 3-cycle cap
adapt `doubt-driven-development` in addyosmani/agent-skills (MIT); `--light`
absorbs the user's local `claim-check` skill. Rewritten in this repo's own words.
