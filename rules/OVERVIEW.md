# Rules — Overview

This directory is the policy SOT (single source of truth) for the framework.
Critical rules are auto-loaded by the AI runtime; lazy rules under `policy/`
are read on-demand by keyword match.

## Critical (auto-load)

| File | Scope |
|---|---|
| [contributing.md](contributing.md) | Code style, test discipline, PR conventions. |
| [public-repo.md](public-repo.md) | Secret hardcoding ban, branch protection, push safety. |
| [memory-discipline.md](memory-discipline.md) | Memory index vs body, source-of-truth reads. |
| [multi-agent-worktree.md](multi-agent-worktree.md) | R1–R14 multi-session coordination protocol. |
| [security-guards.md](policy/security-guards.md) | 5 risk areas (data / secrets / deploy / payment / domain-output). |
| [external-plugin-policy.md](external-plugin-policy.md) | How to adopt third-party plug-ins safely. |

## Lazy (read-on-demand under `policy/`)

| File | When to read |
|---|---|
| [strong-goal-template.md](policy/strong-goal-template.md) | When writing a plan / wave goal — verify it's measurable. |
| [supervisor-goal-mode.md](policy/supervisor-goal-mode.md) | When using `core/infra/supervisor-goal.sh` lifecycle. |
| [actions-billing-admin-merge.md](policy/actions-billing-admin-merge.md) | When CI billing fails but no real leak — admin-merge SOP. |
| [plan-first-clarifying.md](policy/plan-first-clarifying.md) | When triaging a user request — 4-tier classification. |
| [subagent-memory-policy.md](policy/subagent-memory-policy.md) | When using subagents with their own memory scope. |

## Discovery

```bash
grep -l "<keyword>" rules/ rules/policy/   # find which file covers a topic
```
