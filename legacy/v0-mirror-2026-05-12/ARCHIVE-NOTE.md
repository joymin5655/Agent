# 2026-05-12 AirLens-Mirror Skeleton — Archived

This directory preserves the original `joymin5655/Agent` repository state from `main` HEAD prior to the AI-agnostic rewrite of 2026-05-18.

## Why archived

The original skeleton was scoped as an **AirLens-platform mirror** (per `README.md`: "AirLens agent/runtime mirror repository ... not as a deployable AirLens checkout"). It documented AirLens-specific assets (`Obsidian-airlens/`, `apps/web/`, `claude/rules/root/**`) and only the bootstrap files (`README.md`, `MANIFEST.md`, `setup.sh`, `gitleaks.toml`, `.gitignore`) were written — the planned subdirectories (`claude/`, `codex/`, `docs/`, `github/`, `scripts/`) remained empty.

On 2026-05-18 the project was re-scoped as an **AI-agnostic agent framework** usable from any project, with any AI runtime (Claude Code / Codex CLI / Gemini CLI). The AirLens-mirror intent is incompatible with that goal — every documented path needed sanitization or removal. Rather than overwrite in-place, the original skeleton was preserved here for historical reference.

## What's here

| File | Purpose (original) |
|---|---|
| `README.md` | AirLens mirror intro + reuse guide + layout table referencing AirLens paths |
| `MANIFEST.md` | Asset group inventory + exclusion policy + verification commands |
| `setup.sh` | 2-mode installer (global Karpathy + optional `--project` scaffold with AirLens-tinted `.claude/rules/`) |
| `gitleaks.toml` | Base ruleset + AirLens-specific allowlist (placeholder paths, i18n keys, `models/`, `platform-data/`, `Obsidian-airlens/`) |
| `.gitignore` | Runtime exclusions (logs, locks, secrets, `Data/`, `Obsidian-airlens/`, `.worktrees/`) |

## Replacement

The new structure lives at the repo root (`README.md`, `setup.sh`, `gitleaks.toml`, `core/`, `adapters/`, `rules/`, `agents/`, `skills/`, `codex-skills/`, `templates/`, `docs/`).

Key differences:

- **No AirLens references** — paths, domain terms (PM2.5/AOD/DQSS/Glass-box), and policy specifics (5 가드 영역) replaced with config-driven generic constructs.
- **3 AI adapters** (Claude Code / Codex CLI / Gemini CLI) — single canonical hook protocol with per-AI bridge.
- **Project-agnostic** — `setup.sh --project` scaffolds a generic `CLAUDE.md` template, not an AirLens-tinted one.
- **YAML-driven customization** — `templates/hook-config.yml.template` lets each project define its own risk areas, resources, and policy patterns.

## Migration

Existing consumers referencing legacy paths:

| Old (AirLens-mirror) | New (AI-agnostic framework) |
|---|---|
| `~/agent/setup.sh` | `~/agent/setup.sh` (4-mode: `--claude`/`--codex`/`--gemini`/`--project`/`--hooks-only`) |
| `~/agent/claude/global/CLAUDE.md` | `~/agent/templates/CLAUDE.md.template` (generic) + Karpathy bundled separately |
| `~/agent/claude/rules/root/**` | `~/agent/rules/*` + `~/agent/rules/policy/*` (sanitized) |
| `~/agent/scripts/hooks/**` | `~/agent/core/hooks/**` |
| `~/agent/scripts/infra/**` | `~/agent/core/infra/**` |
| `~/agent/gitleaks.toml` | `~/agent/gitleaks.toml` (base ruleset, no allowlist) + `~/agent/templates/gitleaks.toml.template` (user-customizable) |

## Restoring

If for some reason the old skeleton needs to be restored:

```bash
cd /path/to/Agent
git mv legacy/2026-05-12-airlens-mirror/{README.md,MANIFEST.md,setup.sh,gitleaks.toml,.gitignore} .
git rm -r legacy/2026-05-12-airlens-mirror/
```

But the new structure is recommended — it has no AirLens dependencies and works with any project and any AI.

---

Archive date: 2026-05-18
Reason: AI-agnostic framework rewrite (see `CHANGELOG.md` v0.1.0)
