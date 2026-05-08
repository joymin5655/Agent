# Rules — Overview (read-on-demand index)

목적: `.claude/rules/*` 15 file 의 1줄 요약. 자동 로드 컨텍스트 슬림화 (12k → ~1k).
상세 룰은 필요 시 `Read` 로 직접 access.

**정합성**: 룰 파일 내용 변경 시 본 OVERVIEW 1줄 요약도 동기 갱신 (drift 방지).
plan: `~/.claude/plans/auto-load-context-slim.md`.

## Core Rules (`.claude/rules/`)

- [contributing.md](contributing.md) — 코드 스타일 (TS strict / no `any`, Python PEP 8 + ruff), 함수 50줄·파일 300줄, AAA 단위 테스트, 커밋 전 build/lint/test, i18n 6 언어 키 동기, PR 1 기능 단위.
- [public-repo.md](public-repo.md) — 시크릿 절대 하드코딩 금지, `VITE_` 접두만 클라이언트 노출, `SERVICE_ROLE_KEY` 서버 전용, gitleaks 3중 방어 (pre-commit + CI + GitHub native), `git push --force` to main 금지, `--no-verify` 우회 금지.
- [external-plugin-policy.md](external-plugin-policy.md) — 4 외부 plug-in (GSD / Context Mode / Claude Mem / `/ultra-review`) 의 화이트리스트·sandbox guard·protected path watch 정책. C1-C5 충돌 신호. 후속 plan 트리거 (R4 mutex / cwd-guard / claude-mem-watch / context-mode-guard 모두 wire-up 완료 2026-05-06).
- [multi-agent-worktree.md](multi-agent-worktree.md) — claude/codex/gemini 동시 세션 룰 (R1 worktree 강제 · R2 lock · R3 heartbeat · R4 자원 mutex · R4.1 파일 mutex · R5 PR serialize · R6 타 브랜치 침범 금지 · R7 세션 시작 · R7.1 hook stack · R10 untracked 보호 · R11 dashboard · R12 broadcast · R13 blocked · R14 5 deferral 안전 워크플로우).

## Policy (`.claude/rules/policy/`)

- [matt-pocock-skills.md](policy/matt-pocock-skills.md) — Matt Pocock 6 skill 도입 정책 (`grill-with-docs` / `grill-me` / `tdd` / `diagnose` / `improve-codebase-architecture` / `caveman`). 네이밍 충돌 회피 (hook 우선·skill 보조). MIT license. 한국어 응답 + 정본 매핑 강제.
- [plan-first-clarifying.md](policy/plan-first-clarifying.md) — 3-tier 분류 (trivial / interactive / autonomous). M1 dry-run 활성. M3 활성 후 interactive 진입 시 clarifying-Q 4종 (Scope / Priority / Deps / Verify). `/airlens-research` 등 슬래시 = 강제 autonomous.
- [sequential-thinking-routing.md](policy/sequential-thinking-routing.md) — `mcp__sequential-thinking__sequentialthinking` 트리거 조건 (architecture decision / multi-step migration / refactor / ML pipeline / cross-domain trade-off). 회피 = trivial / autonomous research / caveman 활성. max 8 step·세션당 3 호출.
- [firecrawl-policy.md](policy/firecrawl-policy.md) — Firecrawl MCP 12 tool 화이트리스트 (위성·대기 5 + docs 9 + 학술 2). rate limit (도메인당 50 page/일·plan당 200·세션당 1). 라이선스 frontmatter 의무. wiki 경로 `Obsidian-airlens/wiki/imports/<domain>/<slug>-YYYY-MM-DD.md`.
- [hugging-face-research.md](policy/hugging-face-research.md) — HF MCP 9 tool ML 도메인 7개 (AOD / SDID / Camera AI / PARAAD / DQSS / TFT / GNN) 라우팅. arXiv ID 인용 의무. top-5 by citation in last 3 years. paper + repo + space 통합. `airlens-research` skill Step 3 분기.
- [magic-21st-policy.md](policy/magic-21st-policy.md) — Magic-21st 4 tool design variant 정책. AirLens 토큰 자동 주입 (`#25e2f4` / `#0a0f1a` / Inter / Crimson Pro). AI Slop 4 패턴 ban (3-col grid / center 과다 / emoji 남용 / generic gradient). Glass-box 의무 (p10-p90 + DQSS). 컴포넌트당 max 5 variant.
- [notion-external-share.md](policy/notion-external-share.md) — 정본 13체계 외부 공유 정책. 외부 가능 4 PRD (Platform / Web / App / Models). Architecture·DB·Operations 는 internal-only. one-way sync (AirLens → Notion). 수동 invoke. secret/PII/[INTERNAL] diff scan 차단.
- [github-actions-pr-security.md](policy/github-actions-pr-security.md) — PR workflow token boundary 정책. PR code 실행 job = read-only + `persist-credentials:false`; write/secrets job = trusted base checkout만 허용. `pull_request_target` build/test 금지. CI 자동검증 `check-actions-pr-token-safety.py`.
- [supervisor-delegation.md](policy/supervisor-delegation.md) — `/supervise` skill 정책. plan 파일 → supervisor 위임 → 자동 진행. default = 옵션 A full auto. 6 안전장치 (stop 발화 / 5 가드 영역 / R4.1 mutex / gitleaks / test / type) 즉시 중단. _DEPRECATED auto-route / enforcer 패턴 회피. supervisor.py 본문 수정 X.
- [supervisor-tune.md](policy/supervisor-tune.md) — `/supervisor-tune` skill 정책. agent-routing.jsonl + plan-tier-classifications.jsonl 분석 → 분류 룰 갱신 안 *제시*. default = 옵션 C 보고만. 자동 룰 변경 X. 데이터 ≥ 50 record 필요. 5 가드 영역 회피.
- [security-guards.md](policy/security-guards.md) — 5 가드 영역 정본 SOT (production migration / secret 변경 / Edge Fn deploy / 결제 / ML uncertainty). 자동화 영원히 회피. 5 층 보안 stack (gitleaks Layer 1+2 / hook PreToolUse 8 stack / skill Step 1 / policy SOT). 우회 path 차단 매핑. security-violations.jsonl 학습 sink (Wave 4).

## Read-on-demand 패턴

```
Q: 룰에 있던 것 같은데?
A: grep -l "<keyword>" .claude/rules/ .claude/rules/policy/   # 1초 내 위치 확인
   Read 해당 file
```

14 file 중 평균 1-2 file 만 access — 자동 로드 12k → 실 사용 ~2k.
