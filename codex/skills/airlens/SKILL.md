---
name: airlens
description: Project-specific guidance for AirLens work. Use for any AirLens feature, refactor, database change, Edge Function, ML pipeline, or frontend task.
---

# AirLens

Use this skill for any work in the AirLens repo.

## Core Rules

- Follow the repo's existing patterns first.
- Use Obsidian-airlens as the shared documentation source of truth.
- Keep Supabase RLS enabled on new tables.
- Keep `SERVICE_ROLE_KEY` server-only.
- Prefer `api/` and Edge Functions over direct component-side Supabase access.
- Keep UI and research data paths separate.
- Preserve provenance, dataset versions, and source status.
- Use static JSON or cached views for UI hot paths.

## Current Data Policy

- Active sources are the only inputs for live snapshots.
- WAQI/OpenAQ are historical frozen sources, not active ingest sources.
- Research and backtesting may include frozen sources when the dataset version is explicit.

## Frontend Rules

- Use the existing React 19 / Vite / Supabase patterns in this repo.
- Keep the first screen usable; do not add marketing-style filler.
- Match the repo's scientific, data-dense interface style.
- Verify text fits its container and that key views render across desktop and mobile.

## Database Rules

- Prefer PostgreSQL with PostGIS and the repo's existing migration style.
- Use partitioning or snapshot tables for large time-series paths.
- Keep operational snapshots shallow and fast.
- Add indexes for join keys, time columns, and policy filters.

## ML and Data Rules

- Treat model outputs as versioned artifacts.
- Keep p10/p50/p90 and quality metadata visible where predictions are shown.
- Prefer reproducible dataset snapshots for research and policy analysis.

## Workflow

1. Read the relevant code paths first.
2. Plan the change if it touches multiple files or systems.
3. Make the smallest coherent edit.
4. Verify with tests or a targeted runtime check.
5. Review the diff before finishing.

## Agent Runtime Boundary

- Claude agents live under `AirLens-web/.claude/**` and are not directly executable as Codex agents.
- Codex uses `AirLens-web/.codex/skills/**` or `/Users/user/.codex/skills/**`.
- Keep Claude-only hook, command, and `subagent_type` behavior out of Codex skills.
- Record cross-runtime decisions in `Obsidian-airlens/wiki/**`, then update `Obsidian-airlens/index.md` and `Obsidian-airlens/log.md`.

## Good Fit

Use for:

- AirLens schema work
- Supabase migrations and RLS
- Edge Functions
- ML pipeline outputs
- UI changes that depend on AirLens data contracts

## Bad Fit

Do not use for:

- unrelated repos
- generic non-AirLens tasks
- one-line edits that do not need project context
