# AirLens Agent Harness (Supervisor v6, 2026-04-29)

> **상태**: 운영 정본. Supervisor v6 기준의 control-plane, routing eval, bounded handoff, worktree orchestration 정책을 통합 관리한다.
> **분리 근거**: 정본 9개 PRD/Architecture는 product-focused로 가볍게 유지하고, **개발 process tooling·에이전트 시스템은 이 문서에서 통합 정리**.
> **자매**: `airlens-platform-architecture-2026-04-28.md` §15 (Harness Engineering 4기둥 — 정본은 framework만, 운영 상세는 여기), `airlens-platform-prd-2026-04-28.md` §1 AI Safety 정책 (정본은 원칙만, 구현은 여기).

## Context

AirLens는 (a) 다단계 ML 모델 학습/배포, (b) 사용자 contribution + 결제 + 외부 API 통합, (c) web/app/models 세 서브프로젝트 동시 개발 — 복잡도가 높다. Claude Code agent 시스템·hook·reviewer registry로 코드 품질·안전·일관성을 자동 강제하지 않으면 빠른 변화 속도에서 무너지기 쉽다.

이 문서는:
1. **현 상태 인벤토리** — root/web 활성 harness와 optional models specialist registry
2. **Multi-agent code review pipeline** 정식화 (`security-architecture/2026-03-28-multi-agent-code-review-design.md` 흡수)
3. **Harness Engineering 4기둥** 운영 가이드
4. **Self-Improvement Loop** 확대 (web → app/models)
5. **Agent runtime separation** 패턴 (`wiki/concepts/agent-runtime-separation.md` 흡수)
6. **Reviewer Agent Registry** 통합 (web/app/models)
7. **Hook 단계적 활성화** 로드맵

이 문서는 product PRD/Architecture와 lifecycle·readers가 다르다. PRD/Arch는 분기·릴리스 단위로 갱신, Harness는 hook/agent 정의 변경 시 즉시 갱신 — 즉 변경 빈도가 더 잦다. 그래서 별도 정본.

---

## 1. Scope

### 다룸 (In)
- Reviewer agent 정의·registry 통합
- PreToolUse / PostToolUse / Stop / UserPromptSubmit hook 정책
- Harness 4기둥 운영 절차
- Multi-agent code review PR pipeline
- Self-Improvement loop (PGE 10점 평가) 확대
- Agent runtime isolation (worktree·subagent dispatching)
- 작업 전·후 검증 게이트

### 다루지 않음 (Out)
- 제품 정의 (PRD에서)
- 시스템 아키텍처 데이터 흐름 (Architecture에서)
- 실제 코드 구현 (이 plan은 정의·운영 가이드)
- ML 학습 파이프라인 (Models Architecture에서)

---

## 2. 현 상태 인벤토리

### 2.0 Supervisor v6 — 활성 control-plane

| 자원 | 위치 | 역할 |
|---|---|---|
| Supervisor runtime | `scripts/hooks/supervisor.py` | `UserPromptSubmit` 라우팅 분석, `PreToolUse` 고위험/MULTI_DEPT 검증, `PostToolUse Agent` dispatch flag compatibility |
| Root hook settings | `.claude/settings.local.json` | 활성 hook command 22개. v6 정합성 기준 |
| Routing eval | `scripts/hooks/supervisor-routing-fixtures.json`, `scripts/hooks/test_supervisor_routing.py` | 20개 fixture로 intent/risk/workflow/matched/reference/checks 회귀 검증 |
| Harness audit | `scripts/harness-audit.js` | root hook count, Supervisor v6 event 등록, hook command resolution, registry/workflow 정합성 감사 |
| Structured logs | `.claude/logs/supervisor-routing.jsonl`, `.claude/logs/agent-routing.jsonl` | intent/risk/workflow 분포, agent dispatch, artifact descriptor 기록 |

### 2.0.1 PRD Compliance Mode — routing hint + evidence check

Supervisor v6는 PRD/정본 준수를 즉시 차단 정책으로 올리지 않고, 먼저 분석 결과와 힌트에 검증 가능한 evidence 요구를 남긴다.

| 입력 신호 | `canonical_docs` |
|---|---|
| Web / frontend / UI / Globe / Insights | `raw/docs/web/WEB_PRD.md`, `raw/docs/web/WEB_ARCHITECTURE.md` |
| App / mobile / Expo / capture / life-log | `raw/docs/app/APP_PRD.md`, `raw/docs/app/APP_ARCHITECTURE.md` |
| Models / ML / AOD / SDID / DQSS / GTWR / Camera AI | `raw/docs/ml/MODELS_PRD.md`, `raw/docs/ml/MODELS_ARCHITECTURE.md` |
| DB / Supabase / RLS / migration / schema | `raw/docs/db/DATABASE_SCHEMA.md`, `raw/docs/platform/PLATFORM_ARCHITECTURE.md` |
| Platform / cross-project / multi-dept | `raw/docs/platform/PLATFORM_PRD.md`, `raw/docs/platform/PLATFORM_ARCHITECTURE.md` |
| Supervisor / harness / hooks / agent routing | `raw/docs/operations/AGENT_HARNESS.md` |

동작:
- `UserPromptSubmit` 분석 결과에 `canonical_docs: string[]`를 기록한다.
- `systemMessage`에는 읽어야 할 정본 path와 `canonical PRD/Architecture evidence` check를 표시한다.
- `required_checks`에 evidence 요구를 넣어 routing regression과 session summary가 추적할 수 있게 한다.
- `PreToolUse` 차단 범위는 기존과 동일하다. `risk=HIGH` 또는 `intent=MULTI_DEPT`의 Plan/specialist evidence만 차단 가능하며, PRD evidence 미기재만으로는 차단하지 않는다.

승격 조건: fixture/eval에서 false positive가 낮고 실제 작업 로그에서 PRD 미확인이 반복될 때, high-risk PRD-changing work에 한해 M2에서 warning → block 전환을 검토한다. 자동 prompt injection, 무한 재시도, Stop hook 차단은 도입하지 않는다.

### 2.1 Web 측 — 활성

| 자원 | 위치 | 역할 |
|---|---|---|
| Agent registry | `AirLens-web/.claude/agents/registry-tier1.json` | 분야별 reviewer agent 매핑 |
| Auto-dispatch rule | `AirLens-web/.claude/rules/agent-auto-dispatch.md` | 키워드 → 전문 agent 라우팅 |
| Self-improvement rule | `AirLens-web/.claude/rules/agent-self-improvement.md` | Karpathy autoresearch PGE 10점 평가 |
| No-hardcoding rule | `AirLens-web/.claude/rules/no-hardcoding.md` | 상수·메타데이터 config 강제 |
| Knowledge base rule | `AirLens-web/.claude/rules/agent-knowledge-base.md` | Skills/ 레퍼런스 매핑 |
| ECS architecture rule | `AirLens-web/.claude/rules/ecs-architecture.md` | Cross-store 호출 금지, 큐 패턴, 데이터-로직 분리 |
| Public repo rule | `AirLens-web/.claude/rules/public-repo.md` | 보안·브랜칭·커밋 규칙 |
| Contributing rule | `AirLens-web/.claude/rules/contributing.md` | 코드 스타일 |
| System design principles | `AirLens-web/.claude/rules/system-design-principles.md` | 6원칙 검증 |
| Data fetching rule | `AirLens-web/.claude/rules/data-fetching.md` | Server-Collect 강제 |
| Canvas rendering rule | `AirLens-web/.claude/rules/canvas-rendering.md` | Globe 렌더링 가드 |

### 2.2 Web 측 — Hook (활성)

| Hook | 타이밍 | 역할 | 위치 |
|---|---|---|---|
| `supervisor.py` | UserPromptSubmit | 입력 분석 → intent/risk/workflow + agent 매칭 + flags/logging | root `.claude/settings.local.json` |
| `supervisor.py` | PreToolUse | `risk=HIGH` 또는 `intent=MULTI_DEPT` Write/Edit만 Plan/specialist evidence 검증 | root `.claude/settings.local.json` |
| `supervisor.py` | PostToolUse Agent | dispatched-agent compatibility flag 갱신 | root `.claude/settings.local.json` |
| `plan-gate.py` | PostToolUse (Agent/ExitPlanMode) | Plan 완료 확인 | 동일 |
| `post-edit-quality-check.py` | PostToolUse (Write/Edit) | 편집 후 품질 검사 | 동일 |
| `check-cross-store.sh` | PostToolUse (Write/Edit) | Cross-store 직접 호출 감지 | 동일 |
| `record-agent-routing.py` | PostToolUse (Agent) | Agent 호출 기록 + 디스패치 플래그 | 동일 |
| `session-daily-summary.py` | Stop | daily summary + Supervisor v6 분포 + 다음 세션 후보 생성 | 동일 |
| `session-quality-gate.py` | Stop | 변경 파일 품질 요약 + high-risk evidence 경고 | 동일 |

### 2.3 Root/Web hook 상태 메모

| Hook | 타이밍 | 역할 | 활성 조건 |
|---|---|---|---|
| `_DEPRECATED_supervisor-auto-route.py` | UserPromptSubmit | v6 이전 wrapper fallback 자료 | 활성 훅 아님 |
| `_DEPRECATED_supervisor-enforcer.py` | PreToolUse (Write/Edit) | FEATURE 의도 시 Plan 강제 자료 | 활성 훅 아님 |
| `_DEPRECATED_agent-dispatch-enforcer.py` | PreToolUse (Write/Edit) | 전문 agent 미디스패치 차단 자료 | 활성 훅 아님 |
| `check-hardcoding.py` | PreToolUse (Write/Edit) | 하드코딩 차단 | 활성 |
| `route-change-guard.py` | PreToolUse (Edit) | 라우트 변경 감지 | 활성 |
| `record-session-activity.py` | PostToolUse (Write/Edit/Bash) | 활동 기록 | 활성 |

### 2.4 App 측

| 항목 | 상태 |
|---|---|
| `AirLens-app/.claude/` | 부재 (폴더 없음) |
| Agent registry | 없음 |
| Hook | 없음 |
| Reviewer agents | 없음 |
| `mobile-specialist` agent (web에서 placeholder 명시) | 미정의 |

### 2.5 Models 측

| 항목 | 상태 |
|---|---|
| `AirLens-models/CLAUDE.md` | 작업 가이드 있음 |
| Agent registry | `AirLens-models/.claude/agents/registry-tier1.json` |
| Hook | 없음 |
| Specialist agents | 6개 reference-only 후보 (`aod-specialist`, `sdid-specialist`, `camera-ai-specialist`, `dqss-specialist`, `ml-test-engineer`, `ml-security-reviewer`) |
| Self-improvement loop | 모델 특화 룰 존재, 자동 훅은 없음 |
| Quality gate | `model_quality_gates`, `eval_reports` 테이블 + specialist review 기준 |

### 2.6 루트 (platform-wide)

| 항목 | 위치 |
|---|---|
| `.claude/rules/public-repo.md` | 보안·브랜칭 (web과 동일 적용) |
| `.claude/rules/contributing.md` | 코드 스타일 (공통) |
| Graphify | `graphify-out/GRAPH_REPORT.md` (코드 의존성 그래프) |

---

## 3. Multi-Agent Code Review Pipeline

`Obsidian-airlens/wiki/architecture/security-architecture/2026-03-28-multi-agent-code-review-design.md` 흡수.

### 3.1 흐름

```
PR 생성 (GitHub)
  ↓ GitHub Actions trigger
[Stage 1] 빠른 lint + type check
  ↓ pass
[Stage 2] 분야별 reviewer agent 자동 호출 (병렬)
  - 변경 파일 패턴 → registry-tier1.json 매칭
  - 5+ 파일 변경 시: style-reviewer 의무
  - 보안 관련 (auth, payment, RLS): security-reviewer 의무
  - DB migration: db-architect 의무
  - 라우트 변경: fe-architect 의무
  ↓ 각 agent → review comment
[Stage 3] 결과 종합
  - CRITICAL 1+ 건: PR 차단
  - WARNING 5+ 건: human review 요청
  - 통과: auto-merge 가능 (개인 dev 환경)
```

### 3.2 Agent별 책임

| Agent | 변경 파일 패턴 | CRITICAL 기준 |
|---|---|---|
| `style-reviewer` | 5+ 파일 또는 모든 PR 종합 | hardcoding, no-any, unused imports |
| `security-reviewer` | `auth/*`, `payment/*`, RLS migration, Edge Fn | service_role 노출, RLS 우회 |
| `db-architect` | `supabase/migrations/*` | DROP/RENAME/breaking change 미마이그레이션 |
| `globe-specialist` | `lib/earth/*`, `pages/Globe.tsx` | Canvas 비파이닝값, DPR 누락 |
| `fe-architect` | `App.tsx`, `pages/*`, `routes/*` | route 충돌, AppLayout 위반 |
| `component-builder` | `components/*` | accessibility 누락, type 인라인 |
| `test-engineer` | `*.test.ts`, `*.spec.ts` | coverage 임계값 미달 |
| `performance-reviewer` | `lib/earth/*`, bundle 영향 큰 변경 | bundle size 임계 초과 |
| `i18n-specialist` | `i18n/*`, 번역 키 변경 | 6개 언어 누락 |
| `wiki-curator` | `Obsidian-airlens/*` | wiki rule 위반 |
| `ml-researcher` | `AirLens-models/*` | quality gate 미달 |
| `mobile-specialist` ✦ NEW | `AirLens-app/*` | (정의 필요, M2) |

### 3.3 도입 단계

| 단계 | 적용 |
|---|---|
| M1 (현재) | root Supervisor v6가 prompt routing/control-plane을 담당. FEATURE는 권고, HIGH/MULTI_DEPT만 bounded 검증 |
| M2 | GitHub Actions에 stage 1+2 자동화 (web 측) |
| M3 | app 측 mobile-specialist 정의 + models reference specialists 운영 확대 |
| M4 | strict harness — CRITICAL 시 auto-merge 차단 |

---

## 4. Harness Engineering 4기둥 운영

### 4.1 Feedback Loop

| 신호 | 반영 |
|---|---|
| 모델 정확도 (`eval_reports`) | 다음 학습 hyperparameter 조정 |
| 사용자 행동 (PostHog) | UX A/B, paywall trigger 조정 |
| 결제 성공/실패 (`webhook_events`) | RC/Polar 통합 안정성 |
| Agent 호출 빈도 (`agent_metrics`) | rule/registry 조정 (자주 누락되는 agent 자동 호출 강화) |
| 세션 품질 (PGE 10점) | rule 강화 또는 완화 |

### 4.2 Circuit Breaker

폴백 체인 명시:

| 영역 | 폴백 순서 |
|---|---|
| 외부 API 데이터 | live → DB cache → Storage cache → static JSON (`public/data/`) |
| ML 추론 | FastAPI → 브라우저 ONNX → cached 결과 |
| 결제 webhook | retry exponential backoff → dead letter queue → 사용자 알림 |
| Sky-seg 모델 OTA | 신버전 download 실패 → 이전 버전 사용 |
| Embedding 생성 | OpenAI API 실패 → embedding_jobs.status='failed' → cron retry |

각 폴백은 `rate_limit_counters` (00039) + 자체 retry 로직으로 보호.

### 4.3 Quality Gate

| 영역 | Gate | 차단 조건 |
|---|---|---|
| ML 모델 release | `model_quality_gates` 테이블 SLA | RMSE/IoU/MAPE threshold 미달 |
| 마이그레이션 | `npm run db:test` | 24+/24+ PASS 미만 |
| Web build | `npm run build` + `npm run lint` | 실패 |
| Type check | `tsc --noEmit` | 실패 |
| App build | `expo doctor` + `eas build --local` | 실패 |
| PR | Multi-agent CR (§3) | CRITICAL 1+ 건 |
| 세션 종료 | `session-quality-gate.py` Stop hook | 위반/evidence 경고만 출력. Stop hook 차단·자동 재시도 없음 |

### 4.4 Self-Improvement Loop (Karpathy autoresearch)

작업 → 평가 → 피드백 → 개선 클로즈드 루프.

```
FEATURE 작업 시작
  ↓ Plan mode 진입 (의도 명확화)
  ↓ 코드 작성
  ↓ self 평가 (PGE 10점 — Build/Lint/Test/Quality/Rules 각 0-2)
7.0 미만:
  ↓ 부족한 차원 식별
  ↓ 해당 분야 reviewer agent 호출 (style/security/test 등)
  ↓ 수정
  ↓ 재평가
7.0 이상:
  ↓ commit
  ↓ 발견 패턴 → Obsidian-airlens/wiki/log/learnings-{date}.md 기록
```

확대 계획:
- M1 (현재): web 측 active
- M2: app 측 도입 (`AirLens-app/.claude/rules/agent-self-improvement.md` 신규)
- M3: models 측 도입 (학습 후 자동 평가)
- M4: 세션 종료 시 daily summary hook 활성

---

## 5. Self-Improvement Loop 확대 (Web → App/Models)

### 5.1 App 측 적용 plan

| 단계 | 작업 |
|---|---|
| 1 | `AirLens-app/.claude/` 폴더 생성 |
| 2 | `.claude/rules/agent-self-improvement.md` 작성 (web rule 미러링 + RN 특화) |
| 3 | `.claude/rules/agent-auto-dispatch.md` 작성 (mobile-specialist 라우팅) |
| 4 | `mobile-specialist` agent 정의 (RN+Expo 패턴 검증, sky-seg 통합 검증) |
| 5 | PostToolUse hook 설치 (web과 동일 패턴) |
| 6 | App 부트스트랩 후 첫 FEATURE PGE 평가 시범 |

App-specific PGE 차원:
- Build: `tsc --noEmit` + `expo doctor` 통과
- Lint: ESLint
- Test: jest + react-native-testing-library
- Quality: 하드코딩 없음, types.ts 사용, design tokens 정합
- Rules: phone-local 원칙 준수, sky-seg 결과 photo_assets에 저장 등

### 5.2 Models 측 적용 plan

| 단계 | 작업 |
|---|---|
| 1 | `AirLens-models/.claude/` 폴더 생성 |
| 2 | `.claude/rules/agent-self-improvement.md` (학습 quality gate 자동화) |
| 3 | `.claude/rules/data-fetching.md` (Server-Collect 그대로 적용) |
| 4 | `ml-researcher` agent 정식 정의 (quality_gate 검증, eval_reports 확인) |
| 5 | 학습 후 자동 PGE 평가 (Train SLA 통과 / 데이터 품질 / 모델 사이즈 / 추론 시간) |
| 6 | 실패 시 자동 재학습 또는 escalation |

### 5.3 통합 PGE 매트릭스

| 차원 | Web | App | Models |
|---|---|---|---|
| Build | tsc + vite build | tsc + expo doctor | uv pip install + import sanity |
| Lint | ESLint | ESLint | ruff |
| Test | vitest + Playwright | jest + Detox/Maestro | pytest + cross-validation |
| Quality | 하드코딩·types | 하드코딩·types·sync_queue | quality_gate + eval_reports |
| Rules | ECS·Server-Collect·i18n | phone-local·sky-seg·consent | training scope·익명화·DQSS 가중 |

각 차원 0~2점, 총 10점. 7.0 미만 시 자동 개선.

---

## 6. Agent Runtime Separation

`Obsidian-airlens/wiki/concepts/agent-runtime-separation.md` 흡수.

### 6.1 원칙

Agent 로직(prompt + reasoning)과 runtime(execution context, tools, isolation)을 분리. subagent dispatching 시 worktree로 isolation 권장.

### 6.2 패턴

| 패턴 | 사용처 |
|---|---|
| **Worktree isolation** | 큰 변경 (마이그레이션, 부트스트랩) — Agent에 `isolation: "worktree"` 옵션. 변경 없으면 자동 cleanup |
| **Subagent dispatch** | 분야별 reviewer 병렬 호출 — 메인 context 보호, 결과만 main으로 |
| **Read-only exploration** | Plan mode + Explore agent — 코드 변경 없이 탐색 |
| **Plan mode + ExitPlanMode** | 큰 작업 — 합의 후 실행 |

### 6.3 권장 사용

- DB 마이그레이션 적용 → worktree
- 9개 정본 작성 같은 다중 파일 작성 → 메인 (이미 진행 완료)
- 모델 학습 trigger → 별도 GPU 환경 (subagent X)
- 보안 reviewer → 메인에서 (read-only)

---

## 7. Reviewer Agent Registry 통합

### 7.1 현재 분산

- `AirLens-web/.claude/agents/registry-tier1.json` — web 측 12+개 agent
- App/Models 측 미정

### 7.2 통합 방향

루트 또는 각 서브프로젝트에 통합 registry. 권장: **각 서브프로젝트별 registry + 루트에 master index**.

```
AirLens-platform/
├── .claude/agents/master-registry.json  ✦ 신규 (모든 agent 인덱스)
├── AirLens-web/.claude/agents/registry-tier1.json  (현행)
├── AirLens-app/.claude/agents/registry.json        ✦ 신규 (M2)
├── AirLens-models/.claude/agents/registry.json     ✦ 신규 (M3)
```

분야별 agent 매핑 (통합):

| 분야 | Agent | 위치 |
|---|---|---|
| Globe / Three.js | globe-specialist | web |
| 컴포넌트 / UI | component-builder | web |
| DB / RLS / 마이그레이션 | db-architect | web |
| 보안 / OWASP | security-reviewer | web (공유) |
| 테스트 | test-engineer | web (공유) |
| 성능 | performance-reviewer | web (공유) |
| 코드 리뷰 종합 | style-reviewer | web (공유) |
| 프론트엔드 아키텍처 | fe-architect | web |
| 배포 / CI | deploy-manager | web (공유) |
| i18n | i18n-specialist | web (공유) |
| 위키 / 문서 | wiki-curator | 루트 (공유) |
| Python / ML | ml-researcher | models |
| **Mobile / RN** ✦ | **mobile-specialist** | **app (신규 M2)** |

공유 agent (security/test/perf/style/deploy/i18n/wiki)는 web 측 정의를 web/app/models 모두 사용. 도메인별 agent (globe/db/fe-arch/ml/mobile)는 해당 서브프로젝트에서.

---

## 8. Hook 단계적 활성화 로드맵

### 8.1 현재 (M1)

active: supervisor.py, classify-prompt.py dry-run, plan-gate, post-edit-quality-check, check-cross-store, record-agent-routing.

### 8.2 M2 (보강 — 정책 확정 후)

| 활성화 후보 | 영향 |
|---|---|
| `record-session-activity.py` (PostToolUse) | 활동 기록, 개인정보 정책 확정 후 |
| `session-daily-summary.py` (Stop) | 일일 요약, 다음 세션에서 학습 참조 |

### 8.3 M3 (strict harness)

| 활성화 후보 | 영향 |
|---|---|
| `supervisor-enforcer.py` (PreToolUse) | FEATURE 의도 시 Plan 강제 |
| `agent-dispatch-enforcer.py` | 전문 agent 미호출 시 Write/Edit 차단 |
| `check-hardcoding.py` | 하드코딩 차단 |
| `route-change-guard.py` | 라우트 변경 감지 |

### 8.4 M4 (PR 자동화)

GitHub Actions에 multi-agent CR pipeline 정식 도입.

---

## 9. 마일스톤

### M1: 현 상태 정리 (즉시)
- 이 plan 합의
- web 측 active hook 안정화 (5개)
- 통합 master registry (`AirLens-platform/.claude/agents/master-registry.json`) 작성
- agent registry 표(§7.2) wiki 등재

### M2: App 부트스트랩 후 (≈ 2026-Q2)
- `AirLens-app/.claude/` 폴더 + rule + registry 신규
- `mobile-specialist` agent 정의
- App self-improvement loop 적용
- Web M2 hook 활성 (record-session-activity, daily-summary)

### M3: Models 통합 (≈ 2026-Q3)
- `AirLens-models/.claude/` 폴더 + rule + registry
- `ml-researcher` agent 정식 정의 + 학습 후 자동 PGE
- Quality gate 자동화 (eval_reports 검증)

### M4: PR Pipeline (≈ 2026-Q4)
- GitHub Actions stage 1+2 자동화
- Strict harness hook 활성 검토 (개인 또는 팀 합의)
- Multi-agent CR PR pipeline 정식 운영

---

## 10. Critical Files

기존 (read-only 참조):

| 경로 | 용도 |
|---|---|
| `AirLens-web/.claude/rules/agent-auto-dispatch.md` | web 측 라우팅 (현행) |
| `AirLens-web/.claude/rules/agent-self-improvement.md` | web 측 self-improvement (현행) |
| `AirLens-web/.claude/agents/registry-tier1.json` | web agent registry (현행) |
| `AirLens-web/.claude/settings.local.json` | web 측 hook 등록 |
| `Obsidian-airlens/wiki/architecture/security-architecture/2026-03-28-multi-agent-code-review-design.md` | Multi-agent CR 설계 (흡수) |
| `Obsidian-airlens/wiki/concepts/agent-runtime-separation.md` | Runtime separation 패턴 (흡수) |
| `Obsidian-airlens/wiki/concepts/harness-engineering.md` | 4기둥 framework (흡수) |
| `airlens-platform-architecture-2026-04-28.md` §15 | 정본의 framework (이 plan과 짝) |

신규 (이 plan에서 후속 작성):

| 경로 | 시점 |
|---|---|
| `AirLens-platform/.claude/agents/master-registry.json` | M1 |
| `AirLens-app/.claude/rules/agent-auto-dispatch.md` | M2 (app 부트스트랩 후) |
| `AirLens-app/.claude/rules/agent-self-improvement.md` | M2 |
| `AirLens-app/.claude/agents/registry.json` | M2 |
| `AirLens-models/.claude/rules/agent-self-improvement.md` | M3 |
| `AirLens-models/.claude/agents/registry.json` | M3 |
| `.github/workflows/agent-code-review.yml` | M4 |

### Research Workflow (2026-04-29 추가)

AirLens 도메인 deep-research를 LLM Wiki 패턴으로 정형화한 skill — `/airlens-research <topic>` 진입점. 자율 실행 + assumption 문서화 + cross-ref + index/log 갱신을 강제.

| 경로 | 역할 |
|---|---|
| `.claude/skills/airlens-research/SKILL.md` | skill 본문 (7단계 워크플로) |
| `.claude/commands/airlens-research.md` | 슬래시 커맨드 진입점 |
| `Obsidian-airlens/wiki/synthesis/_template.md` | 표준 frontmatter + 7섹션 템플릿 |

자율 vs 인터랙티브 모드: 기본 자율 (research는 autopilot), `--interactive` 플래그 시 단계 2 후 1회 clarifying Q. 산출물은 wiki/{entities|concepts|sources|comparisons|synthesis}/ 적절 카테고리.

### Plan-first + Clarifying-Q Classification (2026-04-29 추가, M1 dry-run)

영상("AI PM Claude Code Setup") 인사이트 — 자율 vs 인터랙티브 vs trivial 3-tier 분류로 "AI가 가정해서 진행" 오류 방지. **현재 M1 dry-run** — hook이 분류만 jsonl 로그, AI 동작 변경 0.

| 경로 | 역할 |
|---|---|
| `.claude/rules/plan-first-clarifying.md` | 룰 본문 (3-tier + 키워드 + clarifying-Q 4종) |
| `scripts/hooks/classify-prompt.py` | UserPromptSubmit 분류 hook (dry-run) |
| `.claude/logs/plan-tier-classifications.jsonl` | dry-run 로그 (gitignored) |

활성화 로드맵: M1 (2026-04-29) dry-run → M2 (~2026-05-06) 측정 → M3 (~2026-05-13) interactive tier에서 clarifying-Q 강제 → M4 false-positive 튜닝. **slash command (`/airlens-research` 등) 는 강제 autonomous** — interrupt 금지.

---

## 11. Verification

| Check | 방법 |
|---|---|
| Active hook 정상 동작 | UserPromptSubmit/PostToolUse 이벤트 트리거 시 hook 로그 확인 |
| Agent 호출 기록 | `record-agent-routing.py` 결과 분석 (호출 빈도, 분야별 분포) |
| PGE 평가 일관성 | 5건 PR 샘플 자체 평가 → 외부 reviewer 점수와 비교 |
| Multi-agent CR 정확도 | M4 활성 후 false positive/negative 비율 측정 |
| Strict hook 영향 | M3 활성 시 차단된 케이스 분석 (정상 차단 vs 부당 차단) |

---

## 12. Open Decisions

1. **mobile-specialist agent 정의 구체화** — RN 패턴 + Expo + sky-seg ONNX 검증 항목 무엇? (M2 작성 시 결정) → resolved in F2 D-H2 (M2 작성 시 RN + Expo + sky-seg ONNX 검증 항목 정의)
2. **strict hook 활성화 timing** — 즉시 vs M3? 개인 dev 흐름 마찰 vs 안전 trade-off → resolved in F2 D-H3 (M3에 strict hook 활성 — 부트스트랩 후)
3. **Multi-agent CR auto-merge** — 통과 시 자동 merge vs 항상 human approval → resolved in F2 D-H4 (항상 human approval — 자동 merge는 v2 검토)
4. **session-daily-summary 개인정보 정책** — 어떤 활동을 기록할지 (명령 history 포함 여부) → resolved in F2 D-H5 (명령 history 제외 default + opt-in)
5. **Master registry 위치** — 루트 `AirLens-platform/.claude/` vs Obsidian `raw/docs/operations/agent-registry.md` 미러 → resolved in F2 D-H6 (루트 `.claude/` + Obsidian mirror 둘 다)
6. **Worktree isolation default 적용 범위** — DB migration·app 부트스트랩 외 어디까지 강제? → resolved in F2 D-H6 (DB+app+models 부트스트랩만 worktree 강제)

---

## 13. Out of Scope

- 정본 9개 PRD/Architecture 변경 (별도 plan, 이미 진행 중)
- 자동 tmux/dev-server 시작과 claude-squad식 TUI 상시 운영
- GitHub Actions workflow 코드 작성 (M4에서)
- Agent prompt 튜닝 (각 agent definition 파일 수정은 별도)
- 사용자 환경 (`~/.claude/`)의 글로벌 hook 설정 (이 plan은 프로젝트 레벨)

---

## 14. 정본 9개와의 관계

이 문서와 정본 9개의 책임 분리:

| 영역 | 정본 9개 (PRD/Arch) | Agent Harness (이 문서) |
|---|---|---|
| AI Safety 원칙 | Platform PRD §1 (원칙만) | §4 운영 절차 |
| Harness 4기둥 | Platform Arch §15 (framework만) | §4 상세 운영 |
| Multi-agent CR | Platform Arch §15.5 ("v2 검토" 포인터) | §3 정식 pipeline |
| Self-Improvement | Platform Arch §15.3, App Arch §17 ("v2 검토") | §5 web→app/models 확대 |
| Agent registry | (정본에 없음) | §7 통합 정의 |
| Hook 정책 | (정본에 없음) | §8 단계적 활성화 |
| Quality Gate (제품 측) | Platform Arch §15.3, Models PRD §3.5 | §4.3 운영 측 게이트 |
| Code Health (Graphify) | Platform Arch §14 (한 단락) | 작업 가이드 + §6 worktree |

정본은 "무엇을 약속하나", 이 문서는 "어떻게 자동 강제하나"를 담당한다.

---

## 15. 운영 다음 단계

1. 1주일 실제 `supervisor-routing.jsonl`을 보고 fixture false-positive/false-negative를 추가한다.
2. `session-daily-summary.py`의 다음 세션 후보가 유용한지 확인하되 자동 prompt injection은 도입하지 않는다.
3. 병렬 작업이 필요할 때 `orchestrate-worktrees.js` dry-run → `orchestration-status.js --format handoff` → Obsidian handoff 순서로 운영한다.
