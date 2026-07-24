# mattpocock/ai-sdk-tips

- **Clone**: `_repos/reference/mattpocock-ai-sdk-tips` (shallow) — actual repo name on disk is
  the AI SDK v5 tutorial companion (`package.json` name: `ai-sdk-5-tutorial`,
  `repository: ai-hero-dev/ai-sdk-5-tutorial` — same content, published under mattpocock's
  personal namespace as `ai-sdk-tips` per the task's repo list and confirmed reachable at
  `github.com/mattpocock/ai-sdk-tips`).
- **License**: **GPL-2** (unusual for a tutorial companion repo — worth flagging; most of
  mattpocock's other repos here are MIT) · **Stars**: 121 · **Pushed**: 2025-10-28 (~9mo
  stale relative to today)

## Purpose

Companion exercises for an AI SDK v5 tutorial on aihero.dev — hands-on exercises (`exercises/`)
covering Vercel AI SDK usage: streaming, tool calls, evals (`evalite` is itself a dependency
here — this repo is a *consumer* of evalite, not evalite itself), OpenTelemetry instrumentation,
Tailwind/React chat UI scaffolding.

## Architecture

- `exercises/`, `shared/`, `internal/` — course-exercise layout, driven by `ai-hero-cli
  exercise` (same course CLI as `ai-hero-cli.md`'s dossier — this repo depends on it via the
  `dev`/`exercise` npm scripts).
- Dependency list confirms a full modern AI SDK stack: `@ai-sdk/{anthropic,google,react}`,
  `ai@5.0.57`, `drizzle-orm`, `@opentelemetry/*`, `evalite`, `@tavily/core` (search tool),
  `js-tiktoken` — a teaching artifact showing how these pieces fit together, not a reusable
  library.

## Install / distribution mechanism

N/A — a course companion repo cloned/forked by students, not installed as a package. No
`postinstall` script (grep confirmed).

## Key patterns worth absorbing

None found beyond what's already covered by the `ai-hero-cli` and `evalite` dossiers (both of
which this repo merely consumes as dependencies). No original pattern specific to this repo
justifies separate analysis depth.

## Overlap with this harness

None — Vercel AI SDK application-building tutorial content, unrelated to this harness's
workflow-governance and verification concerns.

## Security notes

None applicable beyond the standard "course repo, don't reuse its `.env`-adjacent example
patterns verbatim in production" caveat, which isn't specific to this repo.

## Verdict

REJECT. Course/tutorial content, stale (9mo), no engineering pattern distinct from repos
already covered in this batch (`ai-hero-cli`, `evalite`).
