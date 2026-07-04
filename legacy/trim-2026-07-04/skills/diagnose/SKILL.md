---
name: diagnose
description: Root-cause analysis for reproducible bugs. Builds a hypothesis tree, runs evidence-gathering steps, narrows to the actual cause before fixing.
when_to_use: User reports a bug that's reproducible but cause is unclear. NOT for fast stack-trace fixes (use a debugger instead).
tools: Read, Bash, Grep, Glob, Edit
---

# /diagnose

## Goal

Find the root cause of a bug — the deepest thing you can change so the
symptom doesn't recur. Don't fix until you've confirmed the cause.

## Steps

### 1. Reproduce

- **Get a minimal reproduction** in your hands. A failing test is ideal;
  a shell command is fine.
- If you can't reproduce, stop. Ask for more info. Don't speculate-fix.

### 2. Hypothesize

List 2-5 candidate causes. For each:
- **What evidence would confirm it?** (e.g., "if log line X appears", "if
  variable Y is null at line Z")
- **What evidence would rule it out?**

Write the list down (in your working memory or a scratch file). Don't
hold it in conversation context only — that gets lost.

### 3. Gather evidence

Run **one targeted probe per hypothesis**:
- Read the relevant code paths.
- Add a temporary log / print (mark it `// DIAGNOSE — remove before commit`).
- Run the repro with the probe active.
- Record the result.

After each probe: which hypotheses are still standing? Cross off the rest.

### 4. Confirm root cause

When one hypothesis stands:
- **State it explicitly** ("Root cause: <thing>").
- **Confirm it's actually the deepest cause**, not a proximate symptom:
  - "Why does <root cause> happen?" — if you can answer that with
    another fix-able thing, *that's* deeper.
  - Stop when "why" goes outside your code (third-party lib, OS,
    user input).

### 5. Fix

Now write the fix:
- Smallest change that addresses the root cause.
- Add a regression test that fails without the fix and passes with it.
- Remove all temporary probes.

### 6. Verify

- Original repro → does not reproduce.
- Regression test → passes.
- Full test suite → still green.

## Output

```
Bug: <one-line>
Repro: <command / test that fails>
Hypotheses:
  H1: <…> — RULED OUT (evidence: <…>)
  H2: <…> — RULED OUT
  H3: <…> — CONFIRMED (evidence: <…>)
Root cause: <…>
Fix: <files touched, smallest diff>
Regression test: <path>:<test-name>
Verification: <repro now> / <test> / <suite>
```

## Hard rules

- **Don't fix before confirming the cause.** Guess-fixing creates churn
  and false-positive PRs.
- **Don't leave probes in the codebase.** Grep for your `DIAGNOSE`
  marker before committing.
- **Don't fix the proximate symptom** and call it done if a deeper
  cause is plausible. Ask "why does that happen?" one more time.
- **Don't suppress** — silenced exceptions and try/except-pass blocks
  are anti-fixes. The error happens for a reason; address it.
