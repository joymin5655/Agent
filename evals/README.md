# Eval harness

A labeled-dataset eval for the harness's own graders, run under two rigor
conventions that a plain unit test does not give you: **Pass^k** (repeated
independent runs must all agree) and a **regression gate** against a committed
baseline. It measures a *grader's accuracy against ground truth*, not just
"does the code run".

The runner is **judge-agnostic**: it runs `[python3, <verifier>, --root <root>,
<claim.json>]` and grades the emitted verdict, so any grader that speaks the
shared verdict schema (`docs/scoring-convention.md`) plugs in via `--verifier`.
Two tracks ship today:

1. **Deterministic layer** (batch-1) — evaluates the completion verifier
   (`core/infra/completion-verify.py`, P3-5) against claims labeled with the
   verdict it must produce.
2. **Semantic track, deterministic floor** (batch-2) — evaluates
   `evals/judges/reference-judge.py`, a judge that catches
   **green-by-construction** tests (see *Semantic track* below).

A third track — the **real-LLM judge** (batch-3) — plugs into the same runner and
schema but runs **locally, never in CI** (it calls a real model). See *Real-LLM
track* below. The skill A/B dataset is a later increment.

## Layout

| Path | Role |
|---|---|
| `evals/datasets/completion-verify.jsonl` | Batch-1 labeled cases — one JSON object per line. |
| `evals/datasets/semantic-judge.jsonl` | Batch-2 labeled cases for the meaningfulness judge. |
| `evals/run-evals.py` | The judge-agnostic runner: grades each case, enforces Pass^k, gates on regression. |
| `evals/judges/reference-judge.py` | Semantic-track judge — flags tests with no real (non-constant) assertion. |
| `evals/judges/llm-judge.py` | Real-LLM judge (batch-3, out-of-CI) — flags tests that look real but don't exercise the claimed change. |
| `evals/datasets/llm-judge.jsonl` | Real-LLM track labeled cases — semantic-hard (the deterministic floor can't decide them). |
| `evals/baseline.json` | Batch-1 coverage floor (`min_cases`) and the regression bar. |
| `evals/baseline-semantic.json` | Semantic-track coverage floor. |
| `evals/baseline-llm.json` | Real-LLM track coverage floor (enforced by the LOCAL run, not CI). |
| `core/tests/evals-test.sh` | Battery that tests the runner itself (mislabel detection, Pass^k, regression). |
| `core/tests/reference-judge-test.sh` | Battery that tests the judge (trivial→REFUTED, real→CONFIRMED, leak-safety). |
| `core/tests/llm-judge-test.sh` | Battery that tests the real-LLM adapter with a MOCK backend (no real model). |

## Run it

```bash
python3 evals/run-evals.py            # batch-1 (completion verifier), Pass^3, baseline gate
python3 evals/run-evals.py --repeat 1 # a single pass (skip the determinism check)
python3 evals/run-evals.py --quiet    # only the final EVALS PASS / EVALS FAIL line

# semantic track (batch-2) — grade the meaningfulness judge on its own dataset:
python3 evals/run-evals.py \
  --dataset evals/datasets/semantic-judge.jsonl \
  --baseline evals/baseline-semantic.json \
  --verifier evals/judges/reference-judge.py
```

Exit code is `0` only when every run is perfect, Pass^k holds, and there is no
regression — so the runner is usable directly as a CI gate (it is the `evals`
job in `.github/workflows/ci.yml`). Python 3 stdlib only; no `jq`, no PyYAML.

## A case

Each line of the dataset is one labeled case:

```json
{"slug":"refuted-file-missing","expect":"REFUTED","desc":"a cited file that does not exist is refuted","claim":{"summary":"missing file","files":["absent.txt"]}}
```

- **`slug`** — unique id.
- **`expect`** — the ground-truth verdict the verifier must return (`CONFIRMED` or `REFUTED`).
- **`desc`** — what behavior the case pins.
- **`fixture`** *(optional)* — files to materialize in a hermetic temp root before
  running, as `{ "relative/path": "contents" }`. The claim's paths resolve against it.
- **`claim`** — the object handed to the verifier verbatim (see its `files` /
  `tests` / `assertions` contract).

To add a case, append a line and, if it widens coverage, raise `min_cases` in
`evals/baseline.json`.

## Semantic track — the meaningfulness judge

`evals/judges/reference-judge.py` is the **deterministic floor** of the semantic
layer. A completion claim can cite a test that "passes" while asserting nothing
real — the *green-by-construction* failure that
`skills/verify-completion/SKILL.md` step 2 names ("tests that are
green-by-construction (asserting `true`, testing nothing)"). The judge consumes a
claim of the shape

```json
{ "summary": "...", "test_sources": ["rel/path/to/x-test.sh", ...] }
```

and, for each cited source (a path resolved under `--root`, never escaping it),
classifies the file **meaningful** iff it holds at least one **real, non-constant
assertion**. It emits the shared verdict schema and is **CONFIRMED** only when
every cited source is meaningful; anything else — a constant assertion, a missing
or unsafe path, an empty claim — is **REFUTED**.

Examples it catches (each → REFUTED): a bash test that only `echo`s and `exit 0`s;
`[[ 1 -eq 1 ]]` / `[[ 1 == 1 ]]` / `[ 1 = 1 ]` / `[[ true ]]`; python `assert
True`, `self.assertTrue(True)`, `assert x or True`; a `:` no-op body; an empty
file. Examples it confirms (each → CONFIRMED): `[[ "$out" == "expected" ]] || exit
1`; `grep -q pattern file`; `check "..." $?` after a real `[[ ]]`; `assert
func(x) == 3`; `self.assertEqual(a, b)`; `with pytest.raises(ValueError):`. The
dataset (`evals/datasets/semantic-judge.jsonl`) pins **17** labeled cases (8
CONFIRMED / 9 REFUTED).

Because a completion gate must never bless a green-by-construction test, the
classifier is **biased to false-REFUTED over false-CONFIRMED**: a line matching
both a real and a trivial pattern counts as trivial, output lines (echo/print/…)
are inert, and an unrecognized idiom under-counts rather than over-counts.

### Explicit ceiling (honesty)

This judge catches **syntactic** triviality only — *no real assertion*, or *only
constant assertions* via specific enumerated idioms (a constant literal
comparison, `assert True`/`1`, `assertTrue(True)`, identical-operand
`assertEqual`, and the bash equivalents). It cannot enumerate *every* always-true
expression: an arbitrary boolean combination (`assert True and cond`) or a
container-literal comparison (`assert [] == []`) is not recognized as constant and
counts as real — a documented, deliberately-conservative residual, not a silent
one. It does **not** catch **semantic** triviality: a real-looking assertion that
never exercises the changed code path (asserting on a mock, comparing a value to
itself, testing a branch the change didn't touch). It is line-based and does not
parse shell heredocs or evaluate expressions, so an assertion-shaped string in a
heredoc body can still be miscounted. That deeper
judgment needs a real model and runs via `skills/verify-completion` (the semantic
pass) or a pluggable real `--verifier` — **not deterministically in CI**. The CI
`evals` job runs only this deterministic floor; treat a CONFIRMED here as "the
cited tests are not *obviously* hollow", not "the tests are good".

## Real-LLM track (batch-3, out-of-CI)

`evals/judges/llm-judge.py` is the layer **above** the deterministic floor. It
answers the exact question the floor's honest ceiling names as out of reach:
a cited test can carry a real, non-constant assertion (so the floor **CONFIRMs**
it) while being *semantically disconnected* from the claimed change — asserting on
an unrelated function, on a stale inline copy of the logic, on a mock instead of
the real code, or a tautology (a value compared to itself). Deciding that needs a
model that reads the code. The adapter conforms to the same verifier interface
(`llm-judge.py --root <root> <claim.json>` → shared verdict JSON on stdout), reads
the cited `test_sources` and claimed `files` (bounded, root-contained), embeds them
as clearly-delimited **DATA** in a prompt, and asks a real model — reached via a
subprocess CLI — to judge whether the tests actually exercise the change.

It **runs locally, by choice — never in CI** (CI must never call a model). The
`evals` CI job is unchanged; only the mock-backed battery
(`core/tests/llm-judge-test.sh`) rides along in CI via `verify-all.sh`.

### Run it (local)

```bash
python3 evals/run-evals.py \
  --dataset evals/datasets/llm-judge.jsonl \
  --baseline evals/baseline-llm.json \
  --verifier evals/judges/llm-judge.py \
  --repeat 1
```

**Why `--repeat 1`.** A real model is nondeterministic — it can return different
answers for identical input, especially near the confidence threshold. Grading it
under Pass^k's *identical-verdict-across-runs* rule would be dishonest: it would
either fail on harmless flakiness or paper over it. Flakiness here is a property to
**observe**, not to hide, so the real-LLM track runs a single pass. Pass^3 stays on
the deterministic tracks, where a grader that disagrees with itself is a real
defect.

### Backend configuration

| Env | Meaning | Default |
|---|---|---|
| `LLM_JUDGE_CMD` | CLI as an **argv prefix** (tokenized with `shlex`, not run through a shell). The prompt is delivered on the CLI's **stdin**. | `claude -p` |
| `LLM_JUDGE_MODEL` | Optional; when set, `--model <MODEL>` is appended to the argv. | *(unset)* |
| `LLM_JUDGE_TIMEOUT` | Bounded subprocess timeout, in **seconds**. **Strict integer** — a non-integer (e.g. `2m`) fails closed with a clear error, never silently defaults. | `120` |

### Fail-closed vs. refute-by-default (two different exits)

- **Refute-by-default (a verdict).** Unparseable model output, a missing/mistyped
  key, empty `test_sources`, an unreadable or root-escaping path, or a confidence
  below `0.6` → **REFUTED** verdict on stdout, exit 0. A path defect short-circuits
  to REFUTED *without* spending a model call. Ambiguity never CONFIRMs.
- **Fail-closed (no verdict).** The CLI is absent, times out, exits nonzero, returns
  success with empty stdout, or the timeout config is invalid → a clear error to
  **stderr**, **nonzero exit**, and **nothing on stdout**. An infrastructure failure
  must not masquerade as a confident label; the runner reads stdout and treats an
  absent verdict as a crash (correctly graded incorrect) — the visible fail-closed
  signal. Note this makes the adapter's exit code mean *ran-vs-crashed* (0 = a verdict
  was produced, CONFIRMED or REFUTED), unlike `reference-judge.py` whose exit code is
  the gate result — read `verdict` from stdout for the gate decision.

### Prompt-injection containment

Embedded evidence (test/file content) is untrusted. Two layers keep a hostile
excerpt from escaping its DATA block and posing as a top-level instruction:
**per-call nonce** markers (the closing marker carries a random suffix the content
cannot predict or forge) and **defang** (any marker-shaped substring inside content
is neutralized before embedding). So a test file that embeds a literal closing
marker cannot break out of the quarantine. The schema-checked parse trusts only the
three declared JSON keys. This contains delimiter-injection; it does not neutralize
hostile prose that stays *within* the data block — see the ceiling.

### Honest ceiling

Nondeterminism (a case can flip between runs near the threshold); a residual
prompt-injection risk (delimiter-breakout is contained by nonce + defang, but a
model can still be influenced by hostile prose that stays within the data block —
a mitigation, not a guarantee); and model-availability dependence (no backend →
fail closed). This track sharpens the floor; it does not replace it.

### The dataset (per-case labels)

`evals/datasets/llm-judge.jsonl` holds 10 semantic-hard cases (5 CONFIRMED /
5 REFUTED). Each carries a **real** assertion, so the deterministic floor CONFIRMs
all 10 (5/10 accuracy on this set) — only a model that reads the code separates
them. Each line's `desc` is its one-line label rationale:

| slug | label | why the label holds |
|---|---|---|
| `refuted-unrelated-function` | REFUTED | claim covers `multiply()`; the test only exercises the unrelated `add()` in the same module. |
| `refuted-stale-inline-copy` | REFUTED | the test redefines `slugify()` inline and asserts on its own copy — never imports the changed module. |
| `refuted-tautology-variable` | REFUTED | asserts a hardcoded expected value against the same literal; never calls `discount()`. |
| `refuted-mock-only` | REFUTED | asserts on a `Mock`'s canned return; never calls the real `fetch()`. |
| `refuted-self-written-fixture` | REFUTED | greps a file the test itself wrote with the expected text; never invokes `report.sh`. |
| `confirmed-direct-call` | CONFIRMED | imports the claimed `multiply()` and asserts its computed result. |
| `confirmed-integration-stdout` | CONFIRMED | runs the real `square.py` and asserts on its actual stdout. |
| `confirmed-indirect-real` | CONFIRMED | drives the changed `eval_expr()` through the real `process()` entrypoint. |
| `confirmed-error-path` | CONFIRMED | imports the real `parse()` and asserts it raises `ValueError` on bad input. |
| `confirmed-golden-diff` | CONFIRMED | runs the real `gen.py` and diffs its output against a committed golden file. |

## Why Pass^k and a baseline

- **Pass^k** runs the whole suite `k` times (default 3) and requires every case
  correct in every run *and* identical per-case verdicts across runs. A
  deterministic grader always agrees with itself; a flaky one diverges and fails
  even if one run happened to pass. This becomes load-bearing once the
  nondeterministic LLM-judge layer is added.
- **The baseline** turns the suite into a *regression* gate: fewer cases than the
  floor, or any case now graded wrong, drops the score below the bar and fails
  CI — so a change that quietly weakens a grader cannot land green.

See `docs/harness-improvement-plan.md` (E-1) for the roadmap and
`docs/scoring-convention.md` for the shared verdict schema.
