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

## Hook Requirements

- Hooks must be best effort unless they protect secrets, destructive commands, or claimed production resources.
- Hooks must resolve project roots dynamically.
- Hooks must not contain personal absolute paths.
- Hooks must not log secret values.
- Add or update fixture tests when changing routing or blocking behavior.

## Security

Run before publishing:

```bash
python3 core/hooks/test_supervisor_routing.py
python3 core/hooks/test_hooks_dynamic_root.py
gitleaks detect --no-git --source . --config gitleaks.toml
```

Do not commit `.env*`, `secrets/`, `.claude/settings.local.json`, `.claude/logs/`, `.claude/locks/`, or `.agent-harness/state/`.
