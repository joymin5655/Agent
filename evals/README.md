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

The full LLM-judge semantic layer and the skill A/B dataset are later increments
that plug into the same runner and schema.

## Layout

| Path | Role |
|---|---|
| `evals/datasets/completion-verify.jsonl` | Batch-1 labeled cases — one JSON object per line. |
| `evals/datasets/semantic-judge.jsonl` | Batch-2 labeled cases for the meaningfulness judge. |
| `evals/run-evals.py` | The judge-agnostic runner: grades each case, enforces Pass^k, gates on regression. |
| `evals/judges/reference-judge.py` | Semantic-track judge — flags tests with no real (non-constant) assertion. |
| `evals/baseline.json` | Batch-1 coverage floor (`min_cases`) and the regression bar. |
| `evals/baseline-semantic.json` | Semantic-track coverage floor. |
| `core/tests/evals-test.sh` | Battery that tests the runner itself (mislabel detection, Pass^k, regression). |
| `core/tests/reference-judge-test.sh` | Battery that tests the judge (trivial→REFUTED, real→CONFIRMED, leak-safety). |

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
