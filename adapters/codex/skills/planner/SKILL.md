---
name: planner
description: Implementation planning for complex features, refactors, and multi-file changes. Use proactively when the task needs architecture review, dependency mapping, phased execution, or a testing strategy before coding.
---

# Planner

Use this skill when the task is not a single-file change and needs a concrete implementation path first.

## Workflow

1. Inspect the relevant code paths and existing patterns.
2. Identify the minimum set of files, tables, or modules that will change.
3. Split the work into mergeable phases in dependency order.
4. Call out risks, edge cases, and validation steps.
5. Prefer the smallest change that preserves the current architecture.

## Planning Rules

- Be specific about file paths, functions, tables, and endpoints.
- Distinguish blocking work from follow-up work.
- Include tests or verification for each phase.
- Note assumptions explicitly when context is incomplete.
- Avoid speculative redesign unless the current structure is clearly the problem.
- For agent/runtime plans, separate Claude `.claude/**`, Codex `.codex/skills/**`, hook runtime, and knowledge-base responsibilities.

## Output Shape

When you produce a plan, keep it short and operational:

- Overview
- Current state
- Proposed phases
- Risks
- Validation

## Good Fit

Use for:

- new features with multiple touch points
- schema or migration work
- refactors that span backend and frontend
- workflows that need test ordering or rollout sequencing

## Bad Fit

Do not use for:

- one-line fixes
- simple copy edits
- isolated file changes with no dependency chain
