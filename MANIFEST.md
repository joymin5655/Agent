# Agent Repository Manifest

Last updated: 2026-05-12

## Included Asset Groups

- **Global user Claude setup** (`~/.claude/`): `claude/global/CLAUDE.md`, `claude/global/karpathy.md`, `claude/global/RTK.md`, with `claude/global/README.md` documenting the 8-layer inheritance and Karpathy adoption pattern.
- **Project root CLAUDE.md template** (`claude/templates/CLAUDE.md.airlens-root`): the AirLens root `CLAUDE.md` after 2026-05-12 A+ diet (125 lines), kept as a reference for cross-referencing Karpathy globals from a project root.
- **Bootstrap script** (`setup.sh`): idempotent installer. `bash ~/agent/setup.sh` installs `~/.claude/` Karpathy globals; `--project` flag additionally scaffolds `CLAUDE.md`, `.claude/rules/`, `gitleaks.toml`, and `.gitignore` into the current project. Never overwrites existing files without `--force`.
- **Claude slash command** (`claude/commands/project-init.md`): `/project-init` template that wraps `setup.sh` with `AskUserQuestion` scope confirmation and post-install verification. Copy to `~/.claude/commands/` to enable.
- Root Claude assets from AirLens `.claude/`: `claude/README.md`, `claude/agents/root/*`, `claude/rules/root/**`, and `claude/settings/root/settings.json`.
- Existing scoped Claude mirrors: `claude/agents/web/*`, `claude/agents/models/*`, `claude/rules/web/*`, `claude/rules/models/*`, and `claude/commands/**`.
- AirLens Codex skills: 13 directories under `codex/skills/`, including `airlens-design-director/references/layout-composition-doctrine.md`.
- GitHub workflow mirror: all AirLens `.github/workflows/*.yml` files under `github/workflows/`; security-sensitive workflows use `codex/github-actions-pr-secret-hardening`.
- Workflow context: `github/PULL_REQUEST_TEMPLATE.md`, `github/hooks/workmux-status/hooks.json`, and `gitleaks.toml`.
- Hook runtime mirror: `scripts/hooks/**`, including routing fixtures and hook tests.
- Multi-agent infra: `scripts/infra/agent-session.sh`, `codex-session.sh`, `gemini-session.sh`, `worktree-link-deps.sh`, `session_store.py`, `session-indexer.py`, `safe-stash.sh`, and `TIER-2-COORD-CONTRACT.md`.
- CI maintenance guard: `scripts/maintenance/check-actions-pr-token-safety.py`.
- Agent documentation: `docs/operations/**`, `docs/concepts/**`, and `docs/security-architecture/**`.

## Exclusion Policy

- No secret values, credential inventories, private keys, `.env*`, or `secrets/` directories.
- No `.claude/locks/`, `.claude/logs/`, session JSONL, scheduled-task locks, cron output, or runtime state.
- No dependency folders, build outputs, app source mirrors, generated public data, or external reference corpora.
- No local launchd plists or machine-specific global config backup/restore scripts.
- No Codex `.system/` skills, plugin caches, marketplace caches, or user-local runtime cache.
- No project-specific `Obsidian-airlens/`, `Data/`, `secrets/`, `.worktrees/`, or app source. Rules under `claude/rules/root/**` and the AirLens root template **reference** AirLens-specific paths (`Obsidian-airlens/...`, `apps/web/...`); other projects should fork and adapt those paths.

## Verification Checklist

```bash
gitleaks detect --no-git --source . --config gitleaks.toml
python3 scripts/maintenance/check-actions-pr-token-safety.py
python3 scripts/hooks/test_supervisor_routing.py
python3 scripts/hooks/test_hooks_dynamic_root.py
python3 - <<'PY'
import pathlib, yaml
for path in sorted(pathlib.Path("github/workflows").glob("*.yml")):
    yaml.safe_load(path.read_text())
print("workflow yaml ok")
PY
```
