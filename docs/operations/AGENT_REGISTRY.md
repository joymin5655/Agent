# AirLens Agent Registry (Single Source of Truth)

> 정본 (Single Source of Truth) — 4개 산출물의 입력.
> Generator: `scripts/sync_agent_registry.py` (이 파일을 읽어 4개 JSON/MD를 자동 생성)
> 마지막 갱신: 2026-04-29 (ui-ux-director 추가)
> 손대지 말 것: `~/.claude/agents/*.md` (글로벌 영역, 본 SOT는 인덱싱만 함)

---

## 1. 산출물 (이 SOT 가 생성하는 4개 파일)

| 산출 경로 | 형식 | 용도 |
|---|---|---|
| `.claude/agents/master-registry.json` | JSON | 7-필드 schema, 59 agents, mirror 후보 |
| `.claude/agents/master-registry.md` | Markdown | 사람용 요약 + 갱신 절차 (이 파일은 SOT 가 아니라 산출물) |
| `AirLens-web/.claude/agents/registry.json` | JSON | web 21 agents, model/department/level/referenceRepos 메타 보존 |
| `AirLens-web/.claude/agents/registry-tier1.json` | JSON | 3 부서 키워드 라우팅 매핑 (훅 `supervisor.py` 가 사용) |

**호환성 계약 (CRITICAL)**: `registry-tier1.json` 의 최상위 구조는 `{version, description, departments: {dept_id: {name, manager, agents[], defaultModel, triggerKeywords[]}}}`. `scripts/hooks/supervisor.py`가 이 정확한 키 이름을 가정하므로 변경 금지.

---

## 2. 부서 키워드 라우팅 (registry-tier1.json 의 source)

3 부서. 각 부서는 키워드 매칭으로 사용자 입력을 라우팅한다.

### frontend
- **manager**: `fe-architect`
- **defaultModel**: sonnet
- **triggerKeywords**: 컴포넌트, 페이지, UI, UX, 디자인, 스타일, 브랜드, 랜딩, 히어로, 온보딩, 전환, CSS, Tailwind, 반응형, 레이아웃, 애니메이션, 모션, 접근성, a11y, WCAG, 번역, i18n, 다국어, Globe, 지구본, Three.js, 3D, Canvas, HUD, 버튼, 모달, 사이드바, 네비게이션, 테마, 다크모드, component, page, design, brand, landing, hero, onboarding, layout, responsive, animation

### engineering
- **manager**: `ml-researcher`
- **defaultModel**: sonnet
- **triggerKeywords**: ML, 모델, 학습, 훈련, 예측, PINN, SDID, AOD, DQSS, GNN, XGBoost, PyTorch, ONNX, FastAPI, 파이프라인, ETL, Supabase, DB, 데이터베이스, RLS, 마이그레이션, 스키마, 쿼리, Edge Function, API, 엔드포인트, 인증, 웹훅, 테스트, Vitest, Playwright, pytest, 커버리지, E2E, 보안, 취약점, 시크릿, XSS, injection, 성능, 번들, 최적화, 캐싱, Core Web Vitals, model, training, prediction, database, migration, test, security

### operations
- **manager**: `supervisor`
- **defaultModel**: haiku
- **triggerKeywords**: 배포, deploy, CI/CD, GitHub Actions, Cloudflare, 문서, README, CLAUDE.md, CHANGELOG, 위키, wiki, 비용, 토큰, 사용량, quota, 예산, 커밋, PR, 릴리스, ship, merge, 기록, 저장, 메모리, 세션, 진행상황

> 부서별 `agents[]` 리스트는 §3 표의 `department` 컬럼에서 자동 도출.

---

## 3. Agent 표 (메인 SOT)

필드 의미는 `master-registry.json` 의 `field_schema` 와 일치. `model/level/department/refs` 는 web scope agent 에만 적용 (registry.json 에 보존됨).

| id | tier | scope | domain | dept | model | lvl | purpose | tools | path | refs |
|---|---|---|---|---|---|---|---|---|---|---|
| `db-architect` | 1 | AirLens-web | db | engineering | sonnet | 3 | Supabase PostgreSQL 스키마 설계 + RLS 정책 + 마이그레이션 + 쿼리 최적화 | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/db-architect.md` | - |
| `fe-architect` | 1 | AirLens-web | frontend | frontend | opus | 3 | React 19 + Three.js + Tailwind 아키텍처 설계, AppShell/라우팅/상태관리 패턴 결정 | Read, Glob, Grep, Bash | `AirLens-web/.claude/agents/fe-architect.md` | repos:react-bits,cambecc-earth |
| `ml-researcher` | 1 | AirLens-web | ml | engineering | opus | 3 | AirLens 6대 ML 엔진(AOD, SDID, PINN, DQSS, GNN, CameraAI) 고도화 + 실험 설계 (engineering manager) | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/ml-researcher.md` | repos:autoresearch |
| `supervisor` | 1 | AirLens-web | operations | operations | opus | 4 | 2-Tier 라우팅 + 부서 디스패치 + PGE 품질 게이트 조율 | Read, Glob, Grep, Bash, Agent | `AirLens-web/.claude/agents/supervisor.md` | repos:oh-my-claudecode,hermes-agent |
| `wiki-curator` | 1 | AirLens-web | operations | operations | sonnet | 2 | Obsidian LLM Wiki 큐레이터, 소스 통합, 위키 페이지 관리, index/log 갱신 | Read, Write, Edit, Glob, Grep | `AirLens-web/.claude/agents/wiki-curator.md` | - |
| `aq-data-analyst` | 2 | AirLens-web | ml | engineering | sonnet | 2 | PM2.5/PM10 분석, IDW/크리깅 보간, AQI 변환, 월경성 오염 분석 | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/aq-data-analyst.md` | wiki:2 |
| `component-builder` | 2 | AirLens-web | frontend | frontend | sonnet | 2 | Tailwind 4 + Aurora 디자인 시스템으로 반응형/접근성 컴포넌트 구현 | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/component-builder.md` | repos:react-bits |
| `cost-analyst` | 2 | AirLens-web | operations | operations | haiku | 1 | 토큰 사용량 + API 비용 + 번들 사이즈 감사 + 리소스 최적화 제안 | Read, Glob, Grep, Bash | `AirLens-web/.claude/agents/cost-analyst.md` | - |
| `data-engineer` | 2 | AirLens-web | ml | engineering | sonnet | 2 | AOD/Open-Meteo/AirKorea/ERA5 ETL 파이프라인 + 피처 엔지니어링 | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/data-engineer.md` | - |
| `deploy-manager` | 2 | AirLens-web | operations | operations | haiku | 1 | Cloudflare Pages + GitHub Actions CI/CD + 배포 체크리스트 | Read, Glob, Grep, Bash | `AirLens-web/.claude/agents/deploy-manager.md` | - |
| `doc-writer` | 2 | AirLens-web | operations | operations | haiku | 1 | CLAUDE.md / API 문서 / CHANGELOG / README 관리 | Read, Write, Edit, Glob, Grep | `AirLens-web/.claude/agents/doc-writer.md` | - |
| `edge-fn-dev` | 2 | AirLens-web | backend | engineering | sonnet | 2 | Supabase Edge Function (Deno) 개발, REST API + JWT + CORS + Polar 웹훅 | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/edge-fn-dev.md` | - |
| `globe-specialist` | 2 | AirLens-web | frontend | frontend | sonnet | 2 | Three.js + d3-geo + Canvas 2D Globe 엔진, HUD 오버레이, 레이어 시스템 관리 | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/globe-specialist.md` | repos:cambecc-earth |
| `i18n-specialist` | 2 | AirLens-web | frontend | frontend | haiku | 1 | i18next 번역 키 관리, 하드코딩 텍스트 탐지, 6개 언어 일관성 보장 | Read, Glob, Grep | `AirLens-web/.claude/agents/i18n-specialist.md` | - |
| `ui-ux-director` | 2 | AirLens-web | design | frontend | opus | 3 | AirLens 가드레일 안에서 감정 목표 + 정보 위계 + 시각적 은유 + 구현 브리프 설계 | Read, Glob, Grep | `AirLens-web/.claude/agents/ui-ux-director.md` | wiki:1 |
| `a11y-auditor` | 3 | AirLens-web | frontend | frontend | haiku | 1 | WCAG 2.2 AA 키보드/스크린리더/색상대비/ARIA/타겟 크기 감사 | Read, Glob, Grep | `AirLens-web/.claude/agents/a11y-auditor.md` | - |
| `performance-reviewer` | 3 | AirLens-web | frontend | engineering | sonnet | 2 | N+1 쿼리 / 불필요한 리렌더 / 번들 사이즈 / Core Web Vitals 검토 | Read, Glob, Grep | `AirLens-web/.claude/agents/performance-reviewer.md` | existing |
| `security-reviewer` | 3 | AirLens-web | backend | engineering | opus | 3 | SAST + DAST, SQL injection, XSS, 시크릿 노출, RLS 우회, HMAC 검증 | Read, Glob, Grep, Bash | `AirLens-web/.claude/agents/security-reviewer.md` | existing |
| `style-reviewer` | 3 | AirLens-web | frontend | frontend | haiku | 1 | 명명 규칙 / 함수 길이 / 중복 / AirLens 코딩 규칙(types.ts, APP_CONFIG, i18n) 검증 | Read, Glob, Grep | `AirLens-web/.claude/agents/style-reviewer.md` | existing |
| `test-engineer` | 3 | AirLens-web | general | engineering | sonnet | 2 | Vitest 단위/통합, Playwright E2E, pytest ML, 80%+ 커버리지 보증 | Read, Write, Edit, Glob, Grep, Bash | `AirLens-web/.claude/agents/test-engineer.md` | repos:codex |
| `ux-reviewer` | 3 | AirLens-web | design | frontend | sonnet | 2 | 닐슨 10 휴리스틱 + WCAG 2.2 + CRO + Glass-Box 투명성 기반 UX 진단 | Read, Glob, Grep | `AirLens-web/.claude/agents/ux-reviewer.md` | existing |
| `mobile-specialist` | 1 | AirLens-app | frontend | - | - | - | [M2 신규 — 미정의] React Native + Expo + sky-seg ONNX + sync queue + encrypted backup | Read, Write, Edit, Glob, Grep, Bash | `AirLens-app/.claude/agents/mobile-specialist.md` | pending_M2 |
| `architect` | 1 | global | general | - | - | - | 시스템 설계 + 확장성 + 기술 의사결정 architect (PROACTIVELY) | Read, Grep, Glob | `~/.claude/agents/architect.md` | - |
| `code-architect` | 1 | global | general | - | - | - | 기존 코드베이스 패턴 분석 후 구현 청사진 (files / interfaces / data flow / build order) 제공 | Read, Grep, Glob, Bash | `~/.claude/agents/code-architect.md` | - |
| `harness-optimizer` | 1 | global | operations | - | - | - | 로컬 agent harness 신뢰성/비용/처리량 최적화 분석 | Read, Grep, Glob, Bash, Edit | `~/.claude/agents/harness-optimizer.md` | - |
| `multi-agent-orchestrator` | 1 | global | operations | - | - | - | 병렬 작업 분배 + 결과 합성 — 다수 specialist 동시 실행 시 사용 | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/multi-agent-orchestrator.md` | - |
| `plan` | 1 | global | general | - | - | - | 설계/아키텍처 전문가. 구현 계획 + 파일 변경 범위 + 리스크 평가 | Read, Glob, Grep | `~/.claude/agents/plan.md` | - |
| `planner` | 1 | global | general | - | - | - | 복잡한 기능/리팩터링 계획 specialist (PROACTIVELY) | Read, Grep, Glob | `~/.claude/agents/planner.md` | - |
| `research-scientist` | 1 | global | ml | - | - | - | 논문 분석 + ML 실험 설계 + 지식 합성 자율 연구원 | Read, Write, Edit, Bash, Grep, Glob, WebFetch, WebSearch | `~/.claude/agents/research-scientist.md` | - |
| `build-error-resolver` | 2 | global | general | - | - | - | 빌드/TypeScript 에러를 최소 diff로 해결, 아키텍처 변경 없이 그린 빌드 우선 | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/build-error-resolver.md` | - |
| `code-explorer` | 2 | global | general | - | - | - | 실행 경로 추적 + 아키텍처 레이어 매핑 + 의존성 문서화 | Read, Grep, Glob, Bash | `~/.claude/agents/code-explorer.md` | - |
| `code-simplifier` | 2 | global | general | - | - | - | 동작 보존하며 명료성/일관성/유지보수성을 위해 코드 단순화 | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/code-simplifier.md` | - |
| `design-crawler` | 2 | global | design | - | - | - | Playwright로 CSS 토큰/애니메이션/컴포넌트 자동 추출 + 반응형 스크린샷 → assets/clone/ | Read, Write, Edit, Bash, Grep, Glob, WebFetch | `~/.claude/agents/design-crawler.md` | - |
| `design-system-architect` | 2 | global | design | - | - | - | DESIGN.md 작성, 디자인 토큰 정의, UI 컴포넌트 추천, 비주얼 QA | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/design-system-architect.md` | - |
| `doc-updater` | 2 | global | operations | - | - | - | 코드맵 + 문서 자동 업데이트 (/update-codemaps, /update-docs) | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/doc-updater.md` | - |
| `docs` | 2 | global | operations | - | - | - | README + CHANGELOG + API 문서 + 아키텍처 문서 업데이트 | Read, Glob, Grep, Write | `~/.claude/agents/docs.md` | - |
| `docs-lookup` | 2 | global | general | - | - | - | Context7 MCP로 라이브러리/API/SDK 최신 문서 조회 + 코드 예시 반환 | Read, Grep, mcp__context7__resolve-library-id, mcp__context7__query-docs | `~/.claude/agents/docs-lookup.md` | - |
| `document-engineer` | 2 | global | operations | - | - | - | PDF/DOCX/XLSX/PPTX 생성/변환/추출 — 리포트 자동화에 사용 | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/document-engineer.md` | - |
| `e2e-runner` | 2 | global | general | - | - | - | E2E 테스트 (Vercel Agent Browser/Playwright) 생성 + 유지 + 실행 | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/e2e-runner.md` | - |
| `explore` | 2 | global | general | - | - | - | 코드베이스 탐색 + 파일 검색 + 의존성 추적 | Read, Glob, Grep | `~/.claude/agents/explore.md` | - |
| `loop-operator` | 2 | global | operations | - | - | - | 자율 agent loop 운영 + 진행 모니터링 + 정체 시 안전 개입 | Read, Grep, Glob, Bash, Edit | `~/.claude/agents/loop-operator.md` | - |
| `performance-optimizer` | 2 | global | general | - | - | - | 병목 식별 + 슬로우 코드 최적화 + 번들 사이즈 + 메모리 누수 + 렌더 최적화 | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/performance-optimizer.md` | - |
| `refactor-cleaner` | 2 | global | general | - | - | - | knip/depcheck/ts-prune로 dead code/중복/미사용 식별 후 안전 제거 | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/refactor-cleaner.md` | - |
| `tdd-guide` | 2 | global | general | - | - | - | 테스트 우선 작성 강제, 80%+ 커버리지 보장 | Read, Write, Edit, Bash, Grep | `~/.claude/agents/tdd-guide.md` | - |
| `test` | 2 | global | general | - | - | - | 단위/통합 테스트 작성 + 실행 + 커버리지 확인 | Read, Glob, Grep, Write, Bash | `~/.claude/agents/test.md` | - |
| `web-scraper` | 2 | global | general | - | - | - | 웹사이트/API 크롤링 + 스크래핑 + 구조화 데이터 추출 | Read, Write, Edit, Bash, Grep, Glob, WebFetch, WebSearch | `~/.claude/agents/web-scraper.md` | - |
| `code-reviewer` | 3 | global | general | - | - | - | 품질/보안/유지보수성 코드 리뷰 (PROACTIVELY, 모든 코드 변경 후 사용) | Read, Grep, Glob, Bash | `~/.claude/agents/code-reviewer.md` | - |
| `comment-analyzer` | 3 | global | general | - | - | - | 코드 주석 정확성/완전성/유지보수성/comment rot 위험 분석 | Read, Grep, Glob, Bash | `~/.claude/agents/comment-analyzer.md` | - |
| `conversation-analyzer` | 3 | global | operations | - | - | - | 대화 transcript 분석 → hook으로 예방할 행동 식별 (/hookify 트리거) | Read, Grep | `~/.claude/agents/conversation-analyzer.md` | - |
| `database-reviewer` | 3 | global | db | - | - | - | PostgreSQL 쿼리 최적화 + 스키마 + 보안 + 성능 (Supabase 모범 사례 포함) | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/database-reviewer.md` | - |
| `global-security-reviewer` | 3 | global | backend | - | - | - | 보안 취약점 검출 + 수정 (시크릿/SSRF/injection/unsafe crypto/OWASP Top 10) | Read, Write, Edit, Bash, Grep, Glob | `~/.claude/agents/security-reviewer.md` | - |
| `pr-test-analyzer` | 3 | global | general | - | - | - | PR 테스트 커버리지 품질/완전성 리뷰, 행위 커버리지 + 실 버그 예방 강조 | Read, Grep, Glob, Bash | `~/.claude/agents/pr-test-analyzer.md` | - |
| `python-reviewer` | 3 | global | ml | - | - | - | PEP 8 + 타입 힌트 + Pythonic 관용구 + 보안 + 성능 리뷰 | Read, Grep, Glob, Bash | `~/.claude/agents/python-reviewer.md` | - |
| `review` | 3 | global | general | - | - | - | 변경 코드의 보안/성능/품질 종합 리뷰 | Read, Glob, Grep, Bash | `~/.claude/agents/review.md` | - |
| `seo-specialist` | 3 | global | frontend | - | - | - | 기술 SEO 감사 + on-page 최적화 + 구조화 데이터 + Core Web Vitals + 키워드 매핑 | Read, Grep, Glob, Bash, WebSearch, WebFetch | `~/.claude/agents/seo-specialist.md` | - |
| `silent-failure-hunter` | 3 | global | general | - | - | - | silent failure / swallowed error / bad fallback / 누락된 에러 전파 검출 | Read, Grep, Glob, Bash | `~/.claude/agents/silent-failure-hunter.md` | - |
| `type-design-analyzer` | 3 | global | general | - | - | - | 타입 디자인의 캡슐화 + invariant 표현 + 유용성 + 강제력 분석 | Read, Grep, Glob, Bash | `~/.claude/agents/type-design-analyzer.md` | - |
| `typescript-reviewer` | 3 | global | frontend | - | - | - | TypeScript/JavaScript 타입 안정성 + async + Node/web 보안 + 관용 패턴 | Read, Grep, Glob, Bash | `~/.claude/agents/typescript-reviewer.md` | - |
| `ui-layout-reviewer` | 3 | global | design | - | - | - | 그리드 구조 + 시각적 계층 + 반응형 + 인터랙션 상태 분석 (프로젝트 비종속) | Read, Grep, Glob | `~/.claude/agents/ui-layout-reviewer.md` | - |

---

## 4. 통계 (자동 산출 기준)

- **총 agents**: 59
- **Tier**: tier1=13, tier2=27, tier3=19
- **Scope**: AirLens-web=21, global=37, AirLens-app=1, AirLens-models=0
- **Web 부서**: frontend=8, engineering=8, operations=5

---

## 5. Tier 정책

| Tier | 정의 | Worktree isolation |
|---|---|---|
| **Tier1** | 부트스트랩/위험도 높음 — DB 마이그레이션, app 네이티브 빌드, ML 학습, 시스템 설계 | 권장 (DB + app + models 부트스트랩 강제) |
| **Tier2** | 일반 구현 specialist — 코드 작성 권한 | 선택 |
| **Tier3** | 보조/검토 reviewer — read-mostly | 불필요 |

---

## 6. 갱신 절차

1. 본 SOT (`AGENT_REGISTRY.md`) §3 표 수정.
2. `python3 scripts/sync_agent_registry.py` 실행 → 4 산출물 재생성.
3. `python3 scripts/sync_agent_registry.py --check` 로 결과 확인.
4. 커밋: `chore(agents): sync registry — <변경 요지>`.

**금지**:
- 산출 4 파일을 수기로 직접 수정 (다음 sync 시 덮어씀).
- `registry-tier1.json` 의 키 이름 변경 (훅 호환성 깨짐).

---

## 변경 이력

- 2026-04-28: 4 파일 통합 단일 SOT 도입. 통합 전후 동일 (58 agents, web 20, tier 13/26/19). aq-data-analyst 가 tier1.json engineering 부서에 등재됨 (master-registry.md §7 미해결 항목 해소).
- 2026-04-29: `ui-ux-director` 추가. UI 생성 전 디자인 방향/심리/기억 인코딩 브리프를 담당하고, `ux-reviewer`는 감사 전용으로 유지.
- 2026-04-29: active routing hook 명칭을 `supervisor.py` 통합 진입점으로 정리. Codex skill은 별도 runtime이며 이 registry는 Claude `Agent(subagent_type=...)` 후보와 reference-only 항목을 구분하는 입력으로 사용한다.
