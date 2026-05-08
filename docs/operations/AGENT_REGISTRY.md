# AirLens Agent Registry Mirror

Last updated: 2026-05-08

Target audience: AirLens maintainers reviewing Claude/Codex runtime assets outside the main AirLens repository.

Prerequisites: read access to the AirLens workspace and this `Agent.git` mirror.

## Purpose

This file documents the registry state mirrored into `Agent.git`. The generated registry files are:

| Path | Role |
|---|---|
| `claude/agents/root/master-registry.json` | Current root generated registry mirror |
| `claude/agents/root/master-registry.md` | Human-readable generated registry mirror |
| `docs/operations/master-registry.json` | Documentation copy of the generated JSON registry |

The operational source remains the AirLens workspace. This repository preserves the registry output for review and backup; it is not the authoring location unless the user explicitly promotes it.

## Current Registry Snapshot

The mirrored root registry reports:

- Total agents: 64
- Tier split: 12 tier1, 31 tier2, 21 tier3
- Scope split: 21 `apps/web`, 37 `global`, 6 `apps/app`, 0 `models`
- Model split: 9 `haiku`, 12 `opus`, 43 `sonnet`
- AirLens modes: 35 `direct`, 15 `approval_required`, 14 `reference_only`

## Runtime Boundaries

- Claude agents and registries live under `claude/agents/**`.
- Codex skills live under `codex/skills/**`.
- Claude hook and worktree orchestration scripts live under `scripts/hooks/**` and `scripts/infra/**`.
- GitHub Actions files are mirrored under `github/workflows/**` so they are inspectable but inactive in this repository.

Do not copy Claude `Agent(subagent_type=...)` behavior into Codex skills. Do not claim a hook is active unless it is wired in the relevant AirLens `settings*.json`.

## Update Procedure

1. Update the AirLens registry source in the AirLens workspace.
2. Regenerate the AirLens registry outputs there.
3. Mirror the generated outputs into `claude/agents/root/` and `docs/operations/master-registry.json`.
4. Run the verification checklist in `MANIFEST.md`.
5. Push a branch to `joymin5655/Agent.git` and open a PR. Main merges remain human-serialized.
