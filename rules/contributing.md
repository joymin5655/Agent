# Contributing Rules

Project-level coding conventions. Override per-project via your own
`CLAUDE.md` / `AGENTS.md` / `GEMINI.md`.

## Code Style

- **TypeScript**: strict mode, no `any`, explicit return types on exports.
- **Python**: PEP 8, type hints, `ruff` for linting.
- **All user-facing text** uses i18n keys — no hardcoded strings in UI.
- **Constants** in config files, not inline.
- **Functions** under 50 lines (soft guideline).
- **300-line ceiling** applies to docs/markdown context files ONLY.
  Code files split by complexity boundaries (responsibility, abstraction
  layer, domain) — not line count. A 600-line component with one clear
  responsibility beats two 300-line components with leaky boundaries.

## Before Committing

1. Build passes (`npm run build` or project equivalent).
2. Lint passes.
3. No `console.log` in production code.
4. i18n keys added for all locales.
5. New types in dedicated type files (not inline).
6. New/modified code has AAA-pattern unit tests.
7. If full test suite is heavy, run **only the tests for changed files**
   first (e.g., `npm run test:run -- path/to/file.test.ts`,
   `pytest -k <module>`).

## PR Guidelines

- Fill out the PR template completely.
- Include screenshots for UI changes.
- Link related issues.
- Keep PRs focused — one feature or fix per PR.

## Commits

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`,
  `chore:`, `perf:`, `ci:`.
- One logical change per commit.
