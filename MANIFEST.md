# Manifest

Last updated: 2026-05-14

## Portable

- `core/config/*.json`: default supervisor/domain/risk registry.
- `schemas/*.schema.json`: public schemas for generated `.agent-harness/*.json` files.
- `core/rules/*.md`: generalized multi-agent, security, supervisor, memory, plugin, and hook policies.
- `core/hooks/supervisor.py`: config-driven advisory/strict supervisor runtime.
- `core/hooks/pre-tool-guard.sh`: generic Bash safety guard.
- `core/hooks/r4-mutex-check.sh`: production resource mutex guard.
- `core/hooks/r4-file-mutex-check.sh`: file-level multi-session coordination guard.
- `core/hooks/context-mode-guard.sh`: sandbox bypass guard for dangerous external execution tools.
- `core/hooks/tdd-guard.py`: configurable dry-run/block TDD guard.
- `core/hooks/admin-merge-track.py`: admin-merge evidence sink.
- `core/infra/agent-session.sh`, `codex-session.sh`, `gemini-session.sh`, `safe-stash.sh`, `worktree-link-deps.sh`.
- `adapters/claude/agents/*.md`, `adapters/claude/commands/project-init.md`, `adapters/claude/templates/settings.json.template`.
- `adapters/codex/skills/{code-explorer,code-reviewer,database-reviewer,planner}`.
- `templates/claude/settings.local.template.json`, `templates/project/CLAUDE.md.template`.
- `gitleaks.toml`, `setup.sh`.
- `.github/workflows/ci.yml`, `scripts/ci/validate-configs.py`, `scripts/ci/installer-smoke.sh`.

## Generalized From AirLens

- Multi-agent worktree coordination.
- Supply-chain release-age policy.
- Public repository and secret safety.
- PR security and human merge serialization.
- Production resource mutex.
- Supervisor delegation and evidence requirements.
- Plan-first clarification.
- Memory/context discipline.
- Same-name skill priority.
- External plugin guardrails.
- Hook safety guard ordering.

## AirLens Example Only

All AirLens domain assets live under `examples/airlens/`, including:

- Air quality, DQSS, AOD, SDID, Globe, and AirLens ML policies.
- AirLens Claude agents and commands.
- AirLens Codex skills.
- AirLens GitHub workflow mirror.
- AirLens historical docs and security architecture notes.

These files are not installed unless the `airlens-example` profile is used.

## v0.1 Default Install Boundary

Included by default:

- project-local `.agent-harness/*.json`
- project-local `.claude/rules/*.md`
- project-local `gitleaks.toml` and `.gitignore` safety entries
- basic project hook runtimes unless `--no-hooks` is passed

Excluded by default:

- `~/.claude` global files; install only with `--global`
- `.claude/settings.local.json`; copy the template locally to opt in
- AirLens assets; install only with `--profile airlens-example`
- generated runtime state, logs, locks, secrets, dependencies, and build outputs

## Local-Only Exclusions

The starter kit must not include:

- secret values, credentials, private keys, or `.env*`
- `secrets/`
- `.claude/logs/`
- `.claude/locks/`
- `.claude/settings.local.json`
- `.agent-harness/state/`
- dependency folders and build outputs
- personal absolute paths

## Verification

```bash
python3 scripts/ci/validate-configs.py
python3 core/hooks/test_supervisor_routing.py
python3 core/hooks/test_hooks_dynamic_root.py
bash scripts/ci/installer-smoke.sh
gitleaks detect --no-git --source . --config gitleaks.toml
```
