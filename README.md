# Agent

AirLens agent/runtime documentation repository.

This repository is a standalone mirror for agent-only assets from the AirLens platform workspace. It keeps Claude agent definitions, routing registries, workflow rules, Codex skill docs, and Obsidian agent/harness reference docs in one place.

Last updated: 2026-04-30

## Layout

| Path | Contents |
|---|---|
| `claude/agents/root/` | Root master agent registry generated from the AirLens registry SOT |
| `claude/agents/web/` | AirLens-web Claude agent definitions, registry JSON, and workflow routing |
| `claude/agents/models/` | AirLens-models reference specialist agents and registry |
| `claude/rules/` | Claude routing, public repo, plan-first, and project rules |
| `claude/commands/` | Claude command docs for harness/research/review workflows |
| `codex/skills/` | AirLens Codex skill documents used by Codex/GPT runtimes |
| `docs/operations/` | Agent harness and registry canonical docs |
| `docs/concepts/` | Agent runtime, dispatch, collaboration, and harness concept docs |

## Excluded

The mirror intentionally excludes runtime logs, local settings, secrets registries, `.env` files, and session artifacts. In particular, `SECRETS-REGISTRY.md` and `.claude/logs/*` are not included.

## Source Of Truth

The operational source of truth remains the AirLens workspace unless this repository is explicitly promoted to the primary agent registry. Regenerate AirLens registry outputs with:

```bash
PYTHONPYCACHEPREFIX=/tmp python3 scripts/sync_agent_registry.py --check
```

## Sync Notes

This initial import was prepared from `/Volumes/WD_BLACK SN770M 2TB/AirLens-platform` and pushed to `https://github.com/joymin5655/Agent.git`.
