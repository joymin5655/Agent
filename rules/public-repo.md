# Public Repository Rules

## Security

- NEVER hardcode API keys, tokens, or secrets in source code.
- Only `VITE_*` / `NEXT_PUBLIC_*` / framework-equivalent prefixed env vars
  are bundled into client code — never put secrets behind those prefixes.
- Server-only secrets (service-role keys, webhook secrets) must NEVER
  reach client code. They live in serverless function env or CI secrets.
- All external API calls that need secrets go through server-side code
  (server-collect, client-display pattern).
- Check `git diff --cached` for secrets before every commit (handled by
  `core/git-hooks/pre-commit` if installed).

## Machine-identity PII (MUST NOT)

Personal machine identifiers are PII and must never enter committed content
or commit metadata. This repo once leaked a device hostname and a home path
into old commits (2026-04/05, low sensitivity, accepted as historical); this
rule plus the machine gate below prevent any recurrence.

- No absolute home paths in committed content. Write placeholder spellings
  instead: `$HOME/Agent`, `~/Agent`, or `/Users/<name>` (the `<` is what
  keeps a placeholder legal — a real username after the slash is blocked).
  Machine enforcement covers macOS-style home paths (case-sensitively, so
  lowercase REST-route text like an `api.github.com/users/…` example stays
  legal); Linux `/home/<name>` paths are covered by this rule as written
  but not by the gate — keep them placeholder-spelled too.
- No device hostnames — Apple mDNS names shaped like `<device>.local`
  (machine model names embedded in a `.local` host) identify a personal
  computer. Use `example-host` in docs and fixtures.
- No personal volume or drive paths (external-disk mount points). Use
  `/opt/...` or `$HOME/...` in fixtures.
- Git author identity: use your GitHub **noreply** email
  (`<id>+<user>@users.noreply.github.com`) or a deliberate public address.
  Never commit with an author field that embeds a machine hostname
  (misconfigured `git config` defaults to `user@host`); check with
  `git config user.email` before your first commit.

Enforcement: the machine-identity token group in
`core/tests/sanitize-audit.sh` — working-tree scan, `--range` scan of every
PR commit's added lines, **and** the range's commit metadata
(author/committer name+email, subject, body), all wired into CI's sanitize
job. RED-mutation coverage lives in `core/tests/sanitize-audit-test.sh`.

## Git Safety (MUST NOT)

- `git push --force` to `main` / `develop`.
- `cat`, `source`, or env-var inspection on files under `secrets/` or
  `.env*` (excluding `.env.example`). Length/existence checks are fine.
- Direct edits to `.env*` (except `.env.example` with placeholder values).
- Adding/upgrading dependencies without explicit user approval and a
  7-day minimum-release-age check (supply-chain hygiene).
- Bypass flags: `--no-verify`, `--no-gpg-sign`, etc.
- Push / force-push / `branch -D` against another agent's branch prefix
  (`claude/*`, `codex/*`, `gemini/*`) — see multi-agent-worktree.md R6.

## Branching

- Feature branches for all changes (`feat/`, `fix/`, `chore/`).
- PR to `main` — branch protection requires CI to pass.
- No force-push to `main`.

## Environment Variables

- Client-safe (bundled into JS): only declared via `VITE_*` (or
  framework-equivalent) and contain no secret material.
- Server-only (CI secrets): all other tokens. Documented in
  `.env.example` with placeholder values, never with real values.
- Scoped tokens preferred over combined ones (one token per surface,
  minimum permission).
- New env vars must be added to `.env.example` with a placeholder.

## Local Secret Scan

Activate the framework's git hooks:

```bash
brew install gitleaks   # or your platform's package manager
bash setup.sh --hooks-only
```

This sets `core.hooksPath=core/git-hooks` so every `git commit` runs:

1. **gitleaks** — 100+ secret patterns (AWS/GCP/Stripe/Slack/OpenAI/etc.)
2. **check-staged.py** — hardcoding patterns (color arrays, gradients,
   component metadata).

CI Layer 2 (your project's secret-scan workflow) catches anything bypassed.

## False-positive handling

If a real `.env.example` placeholder or auto-generated file trips
gitleaks:

1. Add a regex or path entry under `[allowlist]` in `gitleaks.toml`.
2. Document the rationale in the PR description.
3. Reviewer verifies it isn't a real secret in disguise.
