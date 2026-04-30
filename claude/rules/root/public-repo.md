# Public Repository Rules

## Security

- NEVER hardcode API keys, tokens, or secrets in source code
- Only `VITE_` prefixed env vars are bundled into client — never put secrets there
- `SERVICE_ROLE_KEY` is server-only (Edge Functions) — never expose to client
- All external API calls go through Edge Functions (Server-Collect, Client-Display)
- Check `git diff --cached` for secrets before every commit

## Git Safety Guardrails (MUST NOT)

- **MUST NOT** `git push --force` to `main`/`develop`. PR 우회 금지.
- **MUST NOT** `cat`, `source`, 또는 환경변수로 `secrets/*` 노출. 길이/존재 인벤토리만 허용.
- **MUST NOT** `.env*` 직접 편집 — `.env.example`만 placeholder로 갱신.
- **MUST NOT** 의존성을 명시 승인 없이 추가/업그레이드. Supply Chain 7일 룰 준수 (`AGENTS.md`).
- **MUST NOT** `--no-verify`, `--no-gpg-sign` 등 hook/검증 우회 플래그 사용.

## Branching

- Use feature branches for all changes (`feat/`, `fix/`, `chore/`)
- PR to main — branch protection requires Lint & Build checks to pass
- No force push to main

## Commits

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`
- Keep commits focused — one logical change per commit

## Environment Variables

- Client-safe (VITE_ prefix): `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_POSTHOG_KEY`, `VITE_GA_MEASUREMENT_ID`
- Server-only (GitHub Secrets): `SUPABASE_SERVICE_ROLE_KEY`, `WAQI_TOKEN`, `OPENAQ_API_KEY`, `CLOUDFLARE_API_TOKEN`
- New env vars go in `.env.example` with placeholder values
