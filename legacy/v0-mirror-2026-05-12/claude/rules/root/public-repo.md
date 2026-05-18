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
- **MUST NOT** 다른 에이전트 브랜치 prefix(`claude/*`, `codex/*`, `gemini/*`)에 push / force-push / `branch -D`. 강제 회수 필요 시 사용자 확인 후 진행 (`multi-agent-worktree.md` R6).

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

## Local Secret Scan (Layer 1)

3중 시크릿 방어 — 로컬 pre-commit / CI / GitHub native scanning.

### 신규 클론 시 1회 실행 (필수)

```bash
# 1) gitleaks 설치
brew install gitleaks                              # macOS
# Linux: https://github.com/gitleaks/gitleaks/releases (release 다운로드)

# 2) git hooks 활성화
npm run setup-hooks
# core.hooksPath=scripts/git-hooks 설정 + 실행 권한 부여
```

성공 출력:
```
✓ git hooks activated: core.hooksPath=scripts/git-hooks
✓ gitleaks installed: x.x.x
✓ python3 available (hardcoding scan enabled)
```

### Pre-commit 동작

`git commit` 시 자동 실행:
1. **gitleaks** — 100+ 시크릿 패턴(AWS/GCP/Stripe/Slack/OpenAI/Anthropic/Supabase/GitHub PAT 등) 스캔 (`gitleaks.toml` allowlist 적용)
2. **check-staged.py** — 하드코딩된 색상 배열, gradient, 컴포넌트 인라인 메타데이터 등 차단

위반 시 commit 차단. CI 우회 시 Layer 2(`.github/workflows/secret-scan.yml`)에서 fail.

### False-positive 처리

`.env.example` 의 placeholder, 자동 생성 i18n 파일 등은 이미 `gitleaks.toml [allowlist]` 에서 제외. 새 false-positive 발견 시:

1. 정규식 패턴 또는 경로를 `gitleaks.toml [allowlist]` 의 `regexes` / `paths` 에 추가
2. PR 설명에 추가 사유 명시 (어떤 룰의 어떤 매치를 왜 무시하는가)
3. 리뷰어가 정당성 검증 (실제 시크릿이 placeholder 로 위장되지 않는지)

### 수동 전체 스캔

```bash
# 워킹 디렉터리 전체
gitleaks detect --config=gitleaks.toml --no-banner -v

# 전체 git 히스토리 (느림)
gitleaks detect --config=gitleaks.toml --log-opts="--all" --no-banner -v
```
