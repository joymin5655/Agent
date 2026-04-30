# Contributing Rules

## Code Style

- TypeScript: strict mode, no `any`, explicit return types on exports
- Python: PEP 8, type hints, ruff for linting
- All user-facing text uses i18n keys (`useTranslation()`) — no hardcoded strings
- Constants in config files, not inline
- Functions under 50 lines, files under 300 lines

## Before Committing

1. `npm run build` passes (AirLens-web)
2. `npm run lint` passes
3. No `console.log` in production code
4. i18n keys added for all 6 languages (en/ko/ja/zh/es/fr)
5. New types in dedicated type files (not inline)
6. 신규/수정 코드는 AAA 패턴(Arrange-Act-Assert) 단위 테스트 동반
7. 전체 스위트가 무거우면 **수정 파일 관련 테스트만** 먼저 실행 (예: `npm run test:run -- path/to/file.test.ts`, `pytest -k <module>`)

## PR Guidelines

- Fill out the PR template completely
- Include screenshots for UI changes
- Link related issues
- Keep PRs focused — one feature or fix per PR
