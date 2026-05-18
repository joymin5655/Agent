# Agent

AirLens agent/runtime mirror repository.

This repository mirrors AirLens agent-only operational assets without copying application source, runtime state, local settings, or secrets. It is meant for review, backup, and reuse of the Claude/Codex harness, not as a deployable AirLens checkout.

## Reuse In Other Projects

### Quick start (`setup.sh`)

```bash
# 1. clone the Agent repo once
gh repo clone joymin5655/Agent ~/agent

# 2a. global only — install Karpathy ~/.claude/ setup
bash ~/agent/setup.sh

# 2b. global + project scaffold — also drop CLAUDE.md template, .claude/rules/,
#     gitleaks.toml, and .gitignore additions into the CURRENT project root
cd /path/to/new/project
bash ~/agent/setup.sh --project
```

`setup.sh` is idempotent — existing files are skipped (use `--force` to overwrite). It never touches `.env*`, `secrets/`, or runtime state.

### Claude-invocable slash command (`/project-init`)

After installing the slash command (see `claude/commands/project-init.md`), any Claude Code session can run:

```
/project-init
```

Claude clones / updates `~/agent`, asks scope (global-only vs global+project), runs `setup.sh`, and surfaces AirLens-specific paths that need adaptation.

### What's project-agnostic vs AirLens-specific

| Asset | Portable | Notes |
|---|---|---|
| `claude/global/` | ✅ project-agnostic | Karpathy 4 principles + RTK reference. Drop into `~/.claude/`. |
| `claude/templates/CLAUDE.md.airlens-root` | ⚠️ AirLens-specific | Use as **pattern reference** for the cross-reference style; edit paths for other projects. |
| `claude/rules/root/**` | ⚠️ AirLens-specific | References `Obsidian-airlens/`, `apps/web/`, AirLens hooks. Fork and adapt. |
| `scripts/infra/agent-session.sh` etc. | ✅ mostly portable | Multi-session worktree coordination is generic. |
| `gitleaks.toml` | ✅ portable | Generic secret patterns + allowlist style. |

Last updated: 2026-05-12

## Layout

| Path | Contents |
|---|---|
| `claude/global/` | **User-scope `~/.claude/` setup** — Karpathy 4-principle CLAUDE.md, RTK proxy reference, and 8-layer inheritance doc. Adopted 2026-05-12. |
| `claude/templates/CLAUDE.md.airlens-root` | AirLens root `CLAUDE.md` after 2026-05-12 A+ diet (125 lines) — reference for project-root CLAUDE.md that cross-references Karpathy globals instead of duplicating them. |
| `claude/README.md` | AirLens `.claude/` tracking policy and onboarding note |
| `claude/agents/root/` | Root `.claude/agents/*` registry and root-scoped agents |
| `claude/agents/web/` | Existing AirLens web Claude agent definitions and routing registries |
| `claude/agents/models/` | Existing AirLens models reference specialists and registry |
| `claude/rules/root/` | Root `.claude/rules/*`, including policy docs such as worktree coordination and PR security |
| `claude/rules/web/`, `claude/rules/models/` | Existing scoped rule mirrors |
| `claude/settings/root/settings.json` | Team-shared root Claude settings only; no local overrides |
| `claude/commands/` | Existing Claude command docs for harness, research, review, and ship workflows |
| `codex/skills/` | 13 AirLens Codex skills plus required skill-local references |
| `github/workflows/` | Inactive mirror of AirLens `.github/workflows/*.yml` |
| `github/hooks/workmux-status/hooks.json` | Workmux status hook context, mirrored for operations reference |
| `scripts/hooks/` | AirLens hook scripts, tests, and routing fixtures |
| `scripts/infra/` | Multi-session worktree/session helper scripts |
| `scripts/maintenance/` | CI maintenance guard scripts referenced by mirrored workflows |
| `docs/operations/` | Agent harness and registry reference docs |
| `docs/concepts/` | Agent runtime, dispatch, collaboration, and harness concept docs |

## Excluded

The mirror intentionally excludes `.claude/locks/`, `.claude/logs/`, `.claude/settings.local.json`, scheduled-task locks, `.env*`, dependency folders, generated build outputs, local launchd/cron output, private key material, token values, and user plugin/system caches.

Workflow files keep `secrets.X` references as references only. No actual secret values should be present in this repository.

## Source Refs

The 2026-05-12 delta update was prepared from `AirLens-platform` `origin/main` (commits `2a12ebe6..c0ef22a7`) covering:

- Root `CLAUDE.md` A+ diet (185 → 125 lines, Karpathy global absorption).
- `.claude/rules/policy/same-name-skill-priority.md` (new): same-name skill priority matrix across hook / Matt Pocock / context-mode / superpowers / addyosmani / gstack sources.
- `.claude/rules/policy/firecrawl-policy.md`: whitelist expansion to ~75 domains.
- `.claude/agents/copy-humanizer.md`: v2 with 6 prompt actions (voice clone, hook, dropout).
- `.claude/rules/multi-agent-worktree.md`, `OVERVIEW.md`, `contributing.md`: 300-line scope clarification and gitignore hygiene.
- `scripts/infra/agent-session.sh`, `session_store.py`, `scripts/hooks/classify-prompt.py`: multi-session visibility and commit/PR automation policy (W0-W3).

Global user setup (`claude/global/`) is sourced from `~/.claude/CLAUDE.md`, `~/.claude/karpathy.md`, and `~/.claude/RTK.md` as of 2026-05-12.

The 2026-05-08 baseline update was prepared from clean AirLens refs:

- `origin/main` for the baseline AirLens agent, hook, infra, and workflow mirror.
- `origin/codex/github-actions-pr-secret-hardening` for PR-token and GitHub Actions security hardening artifacts.
- `d92237f3` only for the historical `workmux-status` hook JSON, because that file is now ignored in the AirLens main tree but remains useful operational context.

Codex skills are mirrored from the installed AirLens skill set under `/Users/joymin/.codex/skills`, excluding `.system/`.

## Verification

Recommended checks before publishing:

```bash
gitleaks detect --no-git --source . --config gitleaks.toml
python3 scripts/maintenance/check-actions-pr-token-safety.py
python3 - <<'PY'
import pathlib, yaml
for path in sorted(pathlib.Path("github/workflows").glob("*.yml")):
    yaml.safe_load(path.read_text())
print("workflow yaml ok")
PY
```
