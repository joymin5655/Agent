# Docs Index

| Doc | Read when |
|---|---|
| [`getting-started.md`](getting-started.md) | First-time install — clone, setup, verify |
| [`architecture.md`](architecture.md) | Understanding the framework layers (core / adapters / rules) |
| [Claude plugin lifecycle](claude-plugin-install-lifecycle.md) | Install, activation, hooks, and current gaps |
| [Cross-runtime design](cross-runtime-harness-design.md) | Portable workflow architecture |
| [`hook-protocol.md`](hook-protocol.md) | Writing a new hook OR a new AI adapter (CANONICAL) |
| [`ai-adapters.md`](ai-adapters.md) | Implementing and testing a new AI runtime adapter |
| [Runtime capability matrix](benchmark/runtime-capability-matrix-2026-07.md) | Dated vendor evidence |
| [`customization.md`](customization.md) | Project-specific risk areas, resources, and policy patterns |
| [`skill-authoring.md`](skill-authoring.md) | Writing or editing a skill in `skills/` — vocabulary and principles |
| [`model-routing.md`](model-routing.md) | Which model tier runs which work class — the cross-runtime ladder, floors, enforcement map |
| [`concepts/cost-effective-harnesses.md`](concepts/cost-effective-harnesses.md) | Why the tier ladder is shaped this way — intelligence placement patterns (orchestrator/advisor/verifier) and coordination-cost economics |
| [`concepts/multi-session-worktree.md`](concepts/multi-session-worktree.md) | When you have multiple AI sessions simultaneously |
| [`concepts/security-guards-generic.md`](concepts/security-guards-generic.md) | Project Risk Areas — the 5-layer secret/destructive defense |
| [`concepts/memory-discipline.md`](concepts/memory-discipline.md) | When and how to use AI memory systems |
| [`concepts/plan-mode.md`](concepts/plan-mode.md) | The plan-first workflow + tier classification |
| [`concepts/loop-engineering.md`](concepts/loop-engineering.md) | Designing autonomous loops on top of the harness — building blocks, L0→L3 readiness, 15-criteria checklist |
| [`concepts/fable-5-prompting.md`](concepts/fable-5-prompting.md) | Writing dispatch prompts for frontier (Fable 5.1-class) models — 8 rules mapped to the delegation contract |
| [`concepts/team-patterns.md`](concepts/team-patterns.md) | Six team patterns (Pipeline / Fan-out–Fan-in / Expert Pool / Producer-Reviewer / Supervisor / Hierarchical Delegation) mapped to `/supervise` wave construction |

## Internal notes

Maintainer backlog and dated audits (mostly Korean) are in [`internal/`](internal/README.md).

## Quick links

- [Root README](../README.md) — what this framework gives you
- [AGENTS.md](../AGENTS.md) — agents.md spec for AI agents working in this repo
- [Changelog](../CHANGELOG.md)
