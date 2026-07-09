# Eval harness

A labeled-dataset eval for the harness's own graders, run under two rigor
conventions that a plain unit test does not give you: **Pass^k** (repeated
independent runs must all agree) and a **regression gate** against a committed
baseline. It measures a *grader's accuracy against ground truth*, not just
"does the code run".

This first increment is the **deterministic layer**: it evaluates the completion
verifier (`core/infra/completion-verify.py`, P3-5) against a set of claims that
are each labeled with the verdict the verifier must produce. The semantic
(LLM-judge) layer and the skill A/B dataset are later increments that plug into
the same runner and the shared verdict schema (`docs/scoring-convention.md`).

## Layout

| Path | Role |
|---|---|
| `evals/datasets/completion-verify.jsonl` | Labeled cases — one JSON object per line. |
| `evals/run-evals.py` | The runner: grades each case, enforces Pass^k, gates on regression. |
| `evals/baseline.json` | Coverage floor (`min_cases`) and the regression bar. |
| `core/tests/evals-test.sh` | Battery that tests the runner itself (mislabel detection, Pass^k, regression). |

## Run it

```bash
python3 evals/run-evals.py            # full suite, Pass^3, baseline gate
python3 evals/run-evals.py --repeat 1 # a single pass (skip the determinism check)
python3 evals/run-evals.py --quiet    # only the final EVALS PASS / EVALS FAIL line
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
