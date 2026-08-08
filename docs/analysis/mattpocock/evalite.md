# mattpocock/evalite

- **Clone**: `_repos/reference/mattpocock-evalite` (shallow, monorepo)
- **License**: MIT · **Stars**: 1,625 · **Pushed**: 2026-04-28 (stable, ~3mo since last push)

## Purpose

"The TypeScript-native, local-first tool for testing LLM-powered apps" — a Vitest-based eval
runner: define `evalite("Name", { data, task, scorers })` test files (`*.eval.ts`), run them
like tests, get a local UI dashboard (`evalite-ui`) plus SQLite-backed run history for
trend/regression tracking across runs.

## Architecture (packages/evalite monorepo)

- `evalite.ts` / `run-evalite.ts` — the core runner: wraps Vitest, discovers `*.eval.ts` files,
  executes `data()` → per-row `task(input)` → each `scorers[]` against
  `{input, output, expected}`.
- `create-scorer.ts` — `createScorer({ name, description, scorer })` factory. The wrapped
  scorer function must return either a bare `number` or `{ score: number, metadata? }`; the
  factory validates the return type and normalizes both shapes into
  `{ name, description, score, metadata }`. Deliberately minimal — no built-in scorer library
  ships in this snippet-level read; scorers are user-defined functions.
- `storage/{in-memory,sqlite}.ts` — pluggable result storage; SQLite persists run history so the
  UI can show score deltas between runs (regression detection surfaced visually, not as a CI
  gate primitive itself).
- `reporter/` (`EvaliteRunner.ts`, `events.ts`, `rendering.ts`) — Vitest reporter integration
  that streams eval progress into both terminal output and the `evalite-ui` dev server.
- `trial-count.eval.ts` (example) — repeats each row N times to average out LLM
  non-determinism, i.e. a **pass@k / repeated-trial pattern** at the individual-case level.
- `EvaliteFile` — a typed wrapper so a `task()` can return a file (e.g. generated image) as the
  eval output, not just a string/object — scorers and the UI both understand it natively.
- CI wiring: the monorepo's own `pnpm run ci` = `build && test && lint && check-format` — this
  is CI for *evalite the tool itself*, not a demonstrated pattern for wiring `evalite` eval runs
  into a *consumer* project's CI (no `.github/workflows` example was found gating on eval scores
  in this clone; evalite's docs site, not fetched here, likely covers consumer CI patterns).

## Pattern-lens mapping onto this repo's `evals/`

**A TypeScript runtime dependency is explicitly NOT recommended** — this repo's harness is
Python-stdlib-only by design (`evals/run-evals.py` docstring: "Python 3 stdlib only, no jq, no
PyYAML"), and introducing pnpm/Vitest/tsup as a build chain for one eval tool would be a
disproportionate dependency footprint for a shell/Python harness. The value here is patterns to
imitate in Python, not a package to install.

| evalite concept | This repo's equivalent | Gap / note |
|---|---|---|
| `createScorer({name, description, scorer})` factory, normalizes `number \| {score, metadata}` | `evals/judges/llm-judge.py`, `evals/judges/reference-judge.py` — each is a standalone script invoked via `run-evals.py --verifier PATH`, not a shared factory | This repo's two judges don't share a common "scorer contract" abstraction the way evalite's factory enforces one at the type level. Low priority — only 2 judges exist today, a shared contract pays off at 4-5+. Worth a backlog note, not an active gap. |
| `data()` + `task()` + `scorers[]` — dataset, code-under-test, and grading are three separate hooks | `evals/datasets/*.jsonl` (data) + `core/infra/completion-verify.py` / a skill (task) + judge script (scorer) — already a 3-way separation | Already structurally equivalent. No action. |
| `trial-count.eval.ts` — repeat each row N times, average scores | `run-evals.py`'s Pass^k (repeat the WHOLE suite k times, every case must match every run) | Different granularity: evalite averages a noisy score per-row; this repo's Pass^k requires exact verdict agreement across full-suite reruns (stricter — a flaky verifier fails outright rather than being averaged away). This repo's approach is arguably better-suited to a binary CONFIRMED/REFUTED verdict grader; evalite's per-row averaging fits continuous LLM-judge scores better. No change recommended — the two graders (deterministic vs semantic) already have different rigor conventions per `docs/scoring-convention.md` (referenced in `run-evals.py`, not independently verified in this session). |
| SQLite run-history + UI diffing for regression trend visibility | `evals/baseline*.json` — a static floor (min_cases + accuracy bar), checked in and diffed as a hard CI gate | This repo's approach is fail-closed and CI-enforced; evalite's is a human-facing visual diff tool, not a gate. Different design goals (evalite optimizes for interactive iteration during development; this repo optimizes for a hard merge-blocking floor). Not a gap — a trend-visibility UI is a nice-to-have this repo doesn't need for its current CI-gate-first design. |
| `EvaliteFile` — typed non-text eval outputs | N/A — all of this repo's eval outputs are text/JSON verdicts | Not applicable; this repo's evals never produce file-like artifacts. |

## Overlap with this harness

Strong conceptual overlap (both are "grade an AI-adjacent system against a labeled dataset,
gate CI on the result"), near-zero implementation overlap by design (TS/Vitest vs
Python-stdlib). The comparison confirms this repo's `evals/` layer already independently
converged on the load-bearing ideas (separate data/task/score hooks, repeated-trial rigor,
CI-gating baseline) evalite also arrived at — evidence the existing design is sound, not a
prompt to import evalite's code.

## Security notes

None applicable — a local dev/CI tool with no network-facing surface examined in this pass.

## Verdict

DEFER (pattern-only, no TS runtime). No new pattern found that isn't already present in
`evals/run-evals.py` + judges + baseline files in some form. The `createScorer` shared-contract
idea is noted as a low-priority backlog thought for if/when a 3rd or 4th judge script is added,
not an active adoption.
