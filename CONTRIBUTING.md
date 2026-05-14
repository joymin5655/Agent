# Contributing

This repository is a portable starter kit. Keep project-specific policy out of `core/` unless it has been generalized.

## Generalization Criteria

Promote a policy to `core/` only when:

- it is useful across multiple repositories
- names, paths, domains, and vendors are configurable
- default behavior is advisory or low blast radius
- strict blocking is opt-in
- tests cover the hook or installer behavior

Preserve domain-specific material under `examples/<project>/`.

## Installer Changes

- Keep project-scoped installation as the default.
- Never write `~/.claude` unless the user passes `--global`.
- Keep `.claude/settings.local.json` local-only; installers may write only `.claude/settings.local.template.json`.
- Do not overwrite existing project files unless `--force` is passed.
- When changing install behavior, update `scripts/ci/installer-smoke.sh` with a regression case.
- Keep `airlens-example` as an explicit example profile, not part of `minimal`, `claude`, `multi-agent`, or `full`.

## Schema Changes

- Update the matching file under `schemas/` whenever a public `core/config/*.json` contract changes.
- Keep `core/config/*.json` `$schema` fields pointed at the canonical GitHub raw URL for `main`.
- Run `python3 scripts/ci/validate-configs.py` before publishing config changes.
- Preserve backward-compatible optional fields when practical; breaking config changes require a `schema_version` bump and migration note.

## Hook Requirements

- Hooks must be best effort unless they protect secrets, destructive commands, or claimed production resources.
- Hooks must resolve project roots dynamically.
- Hooks must not contain personal absolute paths.
- Hooks must not log secret values.
- Add or update fixture tests when changing routing or blocking behavior.
- Strict/blocking behavior must remain opt-in except for narrowly scoped safety guards such as secrets, destructive commands, or claimed production resources.

## Security

Run before publishing:

```bash
python3 scripts/ci/validate-configs.py
python3 core/hooks/test_supervisor_routing.py
python3 core/hooks/test_hooks_dynamic_root.py
bash scripts/ci/installer-smoke.sh
gitleaks detect --no-git --source . --config gitleaks.toml
```

Do not commit `.env*`, `secrets/`, `.claude/settings.local.json`, `.claude/logs/`, `.claude/locks/`, or `.agent-harness/state/`.
