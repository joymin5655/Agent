# Public Repository And Secret Safety

## Must Not

- Do not hardcode API keys, tokens, credentials, or private keys.
- Do not print `.env*`, `secrets/`, private key files, or token values.
- Do not commit `.claude/logs/`, `.claude/locks/`, `.claude/settings.local.json`, runtime state, or local caches.
- Do not bypass hooks with `--no-verify` unless the user explicitly approves and the reason is documented.
- Do not force-push protected branches.

## Before Commit

Run a secret scan when available:

```bash
gitleaks detect --no-git --source . --config gitleaks.toml
```

Review staged changes for accidental credentials:

```bash
git diff --cached
```
