# `.claude/` Directory — Onboarding & Policy

This directory holds Claude Code configuration. As of 2026-05-07
(`hook-commit-policy-rework`), part of it is **git tracked** so new
contributors get the team policy automatically on `git clone`, and part
remains **gitignored** (personal / runtime / re-installable).

## Tracked (in git)

| Path | Why tracked |
|---|---|
| `rules/*.md` (4 정본) | R1-R13 multi-agent worktree rules + contributing + public-repo + external-plugin policy |
| `rules/policy/*.md` (7 정본) | Matt Pocock skills / Firecrawl / HF research / Magic-21st / Notion / sequential-thinking / plan-first-clarifying policies |
| `agents/<name>.md` (21 specialists) | supervisor.py routing depends on these existing |
| `settings.json` | Team-shared hook chain, MCP servers, env defaults |
| `README.md` (this file) | Onboarding pointer |

## Tracked elsewhere (sibling repos)

| Path | Why |
|---|---|
| `scripts/hooks/*.sh` and `*.py` | Already tracked. Implementation of the hook chain referenced from `settings.json` |
| `scripts/infra/agent-session.sh` + `session_store.py` | Tier 2 multi-agent coordination (PR #227) |
| `scripts/infra/TIER-2-COORD-CONTRACT.md` | Mirror of R11-R13 in tracked form |

## Gitignored (NOT in git)

| Path | Why ignored |
|---|---|
| `settings.local.json` | Personal env overrides (auth tokens, model preferences) |
| `locks/` | Run-time multi-agent session state (transient) |
| `logs/` | Session logs (transient, can be huge) |
| `backup/` | Local backup snapshots (machine-specific) |
| `cache/` | MCP / plug-in cache |
| `projects/` | Claude Code per-project memory (personal) |
| `state.local/` | Local state — supervisor flags, hook flags |
| `skills/{superpowers,frontend-design,claude-mem,context-mode,code-review,skill-creator,claude-hud}/` | External plug-ins — re-installable via plug-in marketplace, not team source-of-truth |

## What about `skills/` for in-repo skills?

Project-specific skills (Matt Pocock 6 / `airlens-research` / `dqss-check` / `aod-train` /
`policy-sdid-run` / `weekly-digest` / `firecrawl-wiki-ingest` / `hook-reproduce-test` /
`triage-external-draft` / `design-variant-mockup` / `hf-research-collector` /
`notion-prd-sync` / `airlens-ml-preflight` / `spot-check-calendar`) — currently
gitignored alongside the external plug-ins. Tracking them is a separate plan
(out of scope for the policy-rework PR).

## Adding a new rule, agent, or skill

1. Place file under the right path (see tables above).
2. If it should be team-shared → ensure not matched by gitignored patterns.
3. `git add` + commit + open PR for review.
4. Reference from `CLAUDE.md` Skill routing section if user-invocable.

## Adding a new hook

1. Place script under `scripts/hooks/<name>.sh` or `<name>.py` (already tracked).
2. Wire it in `.claude/settings.json` `hooks.<event>[]`.
3. Document execution order in `.claude/rules/multi-agent-worktree.md` §R7.1.
4. Provide a reproduce test in `.claude/skills/hook-reproduce-test/` or
   `scripts/maintenance/<name>-reproduce-test.sh`.

## Migration history

- 2026-05-07 — `hook-commit-policy-rework` plan. `.claude/` flipped from
  blanket-ignored to whitelist. R11-R13 (Tier 2) became visible in PR diffs.
  Reference: `~/.claude/plans/hook-commit-policy-rework.md`.
