# External Plugin Policy

External plugins are allowed when they do not bypass project safety rules.

## Rules

- R4 production resource mutexes take priority over plugin workflows.
- Sandbox execution tools must not run production deploy, production migration, secret-reading, or billing-live commands.
- Cloud review tools require a secret scan and a path allowlist before upload.
- Write-capable memory or learning plugins must avoid `.env*`, `secrets/`, `.claude/rules/**`, and canonical docs unless the user explicitly approves.
