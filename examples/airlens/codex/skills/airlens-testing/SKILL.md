---
name: airlens-testing
description: AirLens testing, TDD, E2E, build-failure triage, and TypeScript/JavaScript review guidance. Use for writing or fixing Vitest, Playwright, pytest, coverage, flaky tests, TypeScript build errors, or reviewing TS/JS diffs.
---

# AirLens Testing

Use this skill for AirLens test design, test implementation, E2E coverage, build/typecheck recovery, and TypeScript or JavaScript review.

## Test Stack

| Area | Tooling | Typical command | Location |
| --- | --- | --- | --- |
| Frontend unit/integration | Vitest | `npm run test:run` | `AirLens-web/src/**/*.test.ts(x)` |
| Frontend coverage | Vitest | `npm run test:coverage` | `AirLens-web/` |
| E2E | Playwright | `npm run test:e2e` | `AirLens-web/e2e/` |
| Visual E2E | Playwright | `npm run test:visual` | `AirLens-web/e2e/visual/` |
| ML unit/integration | pytest | `pytest tests/ -v` | `AirLens-models/tests/` |

Prefer project scripts over ad hoc commands when they exist.

## TDD Workflow

1. Red: write a failing behavior-focused test.
2. Verify the test fails for the expected reason.
3. Green: make the smallest implementation change that passes.
4. Improve: refactor only with tests green.
5. Run targeted tests, then broader coverage when risk warrants it.

Coverage target is 80%+ for branches, functions, lines, and statements unless the repo config sets a stricter threshold.

## Test Quality Rules

- Test behavior and user-visible outcomes, not internal implementation details.
- Name tests so a failure explains the broken behavior.
- Mock external services such as Supabase, Open-Meteo, payment APIs, and model endpoints unless doing explicit integration work.
- Prefer deterministic waits and web assertions; do not use fixed sleeps.
- Keep tests independent; avoid shared state and hidden ordering.
- Cover null, empty, invalid, boundary, error, concurrent, large-data, and special-character cases when relevant.
- Do not add `.skip`, `.only`, or quarantine markers without a short reason and issue or follow-up reference when available.

## AirLens E2E Targets

- `/today`: AQI gauge loads, pollutant grid displays, loading and error states work.
- `/globe`: canvas renders, station selection works, overlays do not block core interaction.
- `/news`: article list, empty state, pagination or infinite-loading behavior.
- `/profile`: name editing, plan display, saved-state feedback.
- Auth: login, logout, protected-route redirect, session restoration.

For visual tests, include mobile and desktop breakpoints such as 320, 768, 1024, and 1440 pixels when the changed UI is responsive.

## E2E Stability

- Use role, label, text, and `data-testid` locators before CSS or XPath.
- Assert critical intermediate states instead of only the final URL.
- Capture screenshots, traces, or videos for failures when the local config supports it.
- Re-run suspicious E2E failures enough times to distinguish real regression from flake.
- Quarantine flaky tests only after recording the failure signature and a reason.

## Build and Typecheck Triage

Use this path when a build or TypeScript check fails:

1. Run the repo's canonical typecheck or build command.
2. Collect all errors before editing.
3. Categorize errors as imports, missing types, nullability, generics, config, dependency, or runtime API mismatch.
4. Fix the smallest cause first; avoid architecture changes while resolving build failures.
5. Re-run the same command that failed, then any adjacent tests.

Common minimal fixes include type annotations, null guards, optional chaining with fallback, corrected imports, interface updates that match real data, and config changes that preserve strictness.

## TypeScript and JavaScript Review

When reviewing a TS/JS change:

- Establish scope with `git diff --staged`, `git diff`, or the relevant PR diff.
- Run typecheck and lint if available; report failures before deeper review.
- Read surrounding context and call sites for changed code.
- Prioritize security, correctness, async handling, error handling, type safety, and missing tests.
- Report findings only when they are actionable and grounded in changed code.

Look especially for unsafe `any`, unjustified non-null assertions, casts used to silence errors, unhandled promises, async `forEach`, swallowed errors, unguarded `JSON.parse`, unsafe `innerHTML`, hardcoded secrets, path traversal, weak env validation, React dependency mistakes, index keys in dynamic lists, and request-time synchronous filesystem work.

## Review Output

For code reviews, lead with findings ordered by severity and include file references. If no issues are found, say so and mention any tests that were not run.

For implementation tasks, finish by listing the commands run and the result.
