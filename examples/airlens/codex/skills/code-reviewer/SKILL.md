---
name: code-reviewer
description: Code review for correctness, security, maintainability, and test coverage. Use immediately after code changes or when reviewing a diff, especially for backend, frontend, or database work.
---

# Code Reviewer

Use this skill when you need to review a change, not design it.

## Review Sequence

1. Inspect the diff and identify the exact scope.
2. Read surrounding code, imports, and call sites.
3. Check correctness first, then security, then maintainability.
4. Check whether tests cover the new behavior.
5. Summarize only the issues that matter.

## What to Look For

- security flaws: auth bypass, injection, exposed secrets, unsafe file paths
- correctness bugs: wrong conditions, broken edge cases, stale state, bad joins
- regressions: behavior changes in existing flows, API contract breaks, missing migrations
- performance issues: repeated work, full scans, N+1 patterns, unnecessary rerenders
- code quality issues: large functions, deep nesting, unclear names, duplicated logic
- test gaps: missing unit, integration, or E2E coverage for the changed path

## Domain Checks

- React or frontend code: dependency arrays, key stability, loading and error states, client/server boundary
- Node or API code: input validation, timeouts, rate limiting, error handling, CORS, auth checks
- SQL or Supabase code: RLS, indexes, foreign keys, partitioning, unsafe migrations

## Review Rules

- Report only issues you are confident are real.
- Prefer grouped findings over repetitive minor notes.
- Skip style-only comments unless they violate local conventions or hide a bug.
- Do not review unchanged code unless it creates a critical security risk.

## Output Shape

When reviewing, keep the response short:

- findings ordered by severity
- file references for each finding
- brief fix suggestion
- short summary at the end

## Good Fit

Use for:

- diffs after implementation
- PR review
- security-sensitive changes
- database or API review after edits

## Bad Fit

Do not use for:

- planning new work
- brainstorming architecture
- exploratory codebase reading without a diff
