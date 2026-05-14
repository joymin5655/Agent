# Runtime Separation

The starter kit separates durable policy from local runtime state.

## Tracked

- `core/`
- `adapters/`
- `templates/`
- `docs/`
- `examples/`
- `schemas/`
- `scripts/ci/`
- `.github/workflows/ci.yml`
- `gitleaks.toml`
- `setup.sh`

## Generated Per Project

- `.agent-harness/config.json`
- `.agent-harness/agent-registry.json`
- `.agent-harness/domains.json`
- `.agent-harness/risk-rules.json`
- `.claude/settings.local.template.json`
- `.claude/agents/*.md`
- `.claude/rules/*.md`
- `scripts/hooks/*`
- `scripts/infra/*`
- `.codex/skills/*`
- `CLAUDE.md`
- `gitleaks.toml`

## Local Only

- `.claude/settings.local.json`
- `.claude/logs/`
- `.claude/locks/`
- `.agent-harness/state/`
- `.env*`
- `secrets/`

Local settings are never mirrored because they contain machine-specific hook wiring, permissions, paths, and allowlists. The installer writes `.claude/settings.local.template.json` only; copying it to `.claude/settings.local.json` is the local opt-in step that activates hooks.

Global Claude files under `~/.claude` are also outside the project runtime boundary. The installer writes them only when `--global` is passed.
