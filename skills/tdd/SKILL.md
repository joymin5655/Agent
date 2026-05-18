---
name: tdd
description: Enforce Red-Green-Refactor cycle for a feature. Write the failing test first, then minimal implementation, then refactor with tests green.
when_to_use: User starts a new feature, fixes a non-trivial bug, or invokes `/tdd`.
tools: Read, Write, Edit, Bash, Grep, Glob
---

# /tdd

## Goal

Force the discipline of writing the test before the code. Three phases:
Red (failing test) → Green (minimal impl) → Refactor (with tests green).

## Phase 1 — Red

1. **Understand the feature/bug.**
   - One observable behavior, named.
   - Acceptance criteria from `rules/policy/strong-goal-template.md`.
2. **Write the failing test.**
   - One test per observable behavior. Don't pack multiple assertions
     into one test unless they're the same behavior.
   - AAA pattern: Arrange, Act, Assert.
   - Name the test so it documents the intent
     (`when_input_is_empty__should_return_error`).
3. **Run the test. Confirm it fails for the expected reason.**
   - Failure message must match what the spec demands (e.g.,
     `AssertionError: expected ValueError`, not
     `ModuleNotFoundError: foo`).
   - If the failure is unrelated (import error, syntax error), fix
     that first and re-run before moving on.

## Phase 2 — Green

1. **Write the minimum code that makes the test pass.**
   - No extra features. No optimisation. No abstraction.
   - "Make it work, then make it right."
2. **Run the test. Confirm green.**
   - If still red, the impl is wrong. Don't change the test to match.
3. **Run the full test suite for that module.**
   - Make sure you didn't break anything else.

## Phase 3 — Refactor

1. **With tests green, refactor for clarity / dedup / structure.**
   - Each refactor step: small change, run tests, confirm green.
   - If a refactor breaks tests, the design is wrong — back out and
     reconsider.
2. **Final check**: full test suite green, lint green, type-check green.

## Output

```
Phase: Red    | Test added: <path>:<test-name> | Status: FAIL (expected)
Phase: Green  | Impl: <path>:<function>        | Status: PASS
Phase: Refactor | Changes: <bullet list>      | Status: PASS

Suite: <command> → <PASS/FAIL>
Coverage: <% if available>
```

## Hard rules

- **No green-without-red.** If you wrote the impl first, throw it away
  and start over.
- **No "I'll add tests later".** The test is the spec; without it you
  don't know what "done" means.
- **No relaxing assertions** to make a test pass. The test failure
  describes the bug — fix the code.
- **No commented-out tests** in the codebase.

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Writing all tests, then all code | Write one test, then one impl, then loop. |
| Tests that test the implementation, not the behavior | Test inputs → outputs. Don't assert internal state. |
| Mocking everything | Integration tests with real deps catch real bugs. Mock at the system boundary, not internally. |
| One test, multiple assertions for different cases | Split. One behavior per test. |
