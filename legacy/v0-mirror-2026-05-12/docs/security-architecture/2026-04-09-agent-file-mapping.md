# Agent Runtime File Mapping And Security Boundary

Last updated: 2026-05-08

Target audience: AirLens maintainers reviewing which agent/runtime files are safe to mirror into `Agent.git`.

## Safe To Mirror

| AirLens source | Agent.git path | Security note |
|---|---|---|
| `.claude/agents/**` | `claude/agents/root/**` | Agent definitions and registries only |
| `.claude/rules/**` | `claude/rules/root/**` | Team policy, no runtime state |
| `.claude/settings.json` | `claude/settings/root/settings.json` | Shared settings only |
| `.github/workflows/*.yml` | `github/workflows/*.yml` | Inactive workflow mirror |
| `.github/hooks/workmux-status/hooks.json` | `github/hooks/workmux-status/hooks.json` | Operational context, no credentials |
| `scripts/hooks/**` | `scripts/hooks/**` | Hook source and tests |
| `scripts/infra/agent-session.sh` and related helpers | `scripts/infra/**` | Session coordination scripts |
| `scripts/maintenance/check-actions-pr-token-safety.py` | `scripts/maintenance/check-actions-pr-token-safety.py` | CI guard referenced by `secret-scan.yml` |
| `/Users/joymin/.codex/skills/<airlens skill>/**` | `codex/skills/**` | AirLens project skills only |

## Must Not Mirror

- `.claude/settings.local.json`
- `.claude/locks/**`
- `.claude/logs/**`
- `.claude/state.local/**`
- `.env*`
- `secrets/**`
- Private keys, tokens, cookies, API keys, and raw credential registries
- Cron output, local launchd plists, and machine-specific global config backups
- Codex `.system/**`, plugin caches, marketplace caches, and user runtime cache
- Application source or generated datasets unless the file is itself an agent/runtime asset

## Workflow Token Boundary

The workflow mirror includes `scripts/maintenance/check-actions-pr-token-safety.py`. It fails CI when a `pull_request` workflow mixes PR-controlled checkout/code execution with write permissions or sensitive secrets.

Mirrored workflow files may contain `secrets.NAME` references. Those references are safe to mirror because they do not contain secret values.

## Review Checklist

Before publishing an Agent.git mirror update:

1. Run `gitleaks detect --no-git --source . --config gitleaks.toml`.
2. Run `python3 scripts/maintenance/check-actions-pr-token-safety.py`.
3. Confirm there are no `.env`, `settings.local.json`, `locks`, `logs`, `*.jsonl`, private key, or token-value files outside `.git/`.
4. Review `git diff --stat` for accidental application source or generated-data imports.
