---
title: 에이전트 디스패치 시스템
type: concept
created: 2026-04-27
updated: 2026-04-29
sources: [registry-tier1.json, registry.json, workflows.json, supervisor-auto-route.py, configuration-hierarchy.md]
tags: [agent, dispatch, routing, hooks, state-machine, supervisor, documentation]
---

# 에이전트 디스패치 시스템 (현행)

AirLens의 에이전트 업무 분배 체계. 사용자 입력을 자동 분류하여 적합한 부서와 전문가를 매칭하고, 훅으로 워크플로우 순서를 강제한다.

> 역사적 배경은 [[에이전트 시스템 설계]] 참조. 하네스 품질 보증은 [[하네스 엔지니어링]] 참조.
> 2026-04-27 검증 기준: Claude agent 정의와 디스패치 설계는 `.claude/agents`와 `.claude/rules`에 남아 있으나, AirLens-web의 실제 `settings.local.json`에는 전체 20개 디스패치 훅이 아니라 최소 안전 훅 세트만 등록되어 있다. 런타임 분리는 [[Claude/Codex 에이전트 런타임 분리|agent-runtime-separation.md]]를 따른다.

---

## 운영 원칙: 이동하지 않는 문서

에이전트/하네스 관련 파일은 문서처럼 보이더라도 런타임 입력이다. 다음 파일군은 Obsidian으로 이동하지 않는다.

- `.claude/agents/*.md`, `registry*.json`, `workflows.json`
- `.claude/commands/*.md`
- `.claude/rules/*.md`
- `scripts/hooks/**`
- `**/CLAUDE.md`, `AGENTS.md`

Obsidian은 이 파일들의 **설명과 인벤토리 정본**을 관리하고, 실제 동작 정의는 원래 위치에 둔다. 이 원칙은 에이전트 페르소나와 하네스 강제가 문서 정리 중 깨지는 것을 막기 위한 것이다.

---

## 1. 3부서 21에이전트 구조

정본: `AirLens-web/.claude/agents/registry-tier1.json`

| 부서 | 부서장 | 에이전트 수 | 기본 모델 | 구성원 |
|------|--------|-----------|----------|--------|
| **Frontend** | fe-architect | 8 | Sonnet | fe-architect(Opus), ui-ux-director(Opus), component-builder, i18n-specialist(Haiku), a11y-auditor(Haiku), globe-specialist, ux-reviewer, style-reviewer(Haiku) |
| **Engineering** | ml-researcher | 8 | Sonnet | ml-researcher(Opus), data-engineer, aq-data-analyst, db-architect, edge-fn-dev, test-engineer, security-reviewer(Opus), performance-reviewer |
| **Operations** | supervisor | 5 | Haiku | supervisor(Opus), deploy-manager(Haiku), doc-writer(Haiku), cost-analyst(Haiku), wiki-curator |

모델 티어: Opus=설계/복잡 분석, Sonnet=구현/리뷰, Haiku=경량 기록/검증.

에이전트 프라이밍: MoE 잠재공간 활성화 (실제 전문가 타이틀 + 도메인 용어 사용).
상세 프로필: `AirLens-web/.claude/agents/registry.json` (v2.1, 2026-04-20).

---

## 2. 의도 분류 (Intent Classification)

정본: `scripts/hooks/supervisor.py`

사용자 프롬프트를 deterministic matcher로 구조화 분석한다:

| 의도 | 트리거 패턴 | 후속 동작 |
|------|------------|----------|
| **FEATURE** | 구현, 추가, 만들, 수정, 개선, build, refactor | Plan + specialist + quality gate 권고 |
| **MULTI_DEPT** | FEATURE + 2개 이상 부서 에이전트 매칭 | Plan + 병렬 에이전트 디스패치, high-risk 검증 |
| **QUERY** | 뭐야, 설명해, 어떻게, show, find | 전문가 추천 (systemMessage) |
| **SIMPLE_EDIT** | 계속, 마저, lint fix, quick fix | 토큰 다이어트 (systemMessage 생략) |
| **RECALL** | 이전에, 기억나, 지난번 | 토큰 다이어트 |
| **LEARN** | 패턴 저장, 스킬 생성, 학습해 | 토큰 다이어트 |
| **META / REVIEW/AUDIT** | supervisor, 에이전트 구성, 점검, 감사, 하네스 | supervisor 또는 reviewer 분석 |

권고+검증 정책: SIMPLE/QUERY/REVIEW는 차단하지 않는다. Write/Edit 차단은 `risk=HIGH` 또는 `intent=MULTI_DEPT`에서 Plan/specialist dispatch가 빠진 경우로 제한한다.

---

## 3. 2-Tier 라우팅 흐름

```
사용자 프롬프트
  ↓
[classify_intent()] → FEATURE / QUERY / SIMPLE_EDIT / RECALL / LEARN
  ↓
[match_department()] → registry-tier1.json 키워드 스코어링 → 부서 선택
  ↓
[match_agents()] → 12개 전문가 regex 패턴 → 매칭 에이전트 목록
  ↓
[MULTI_DEPT 판정] → 2+ 부서 에이전트 매칭 시 승격
  ↓
[select_workflow()] → workflows.json에서 워크플로우 선택
  ↓
systemMessage 출력 + /tmp 플래그 설정
```

### Tier-1: 부서 키워드 매칭

`match_department()`: 프롬프트를 각 부서의 `triggerKeywords`와 비교, 가장 많이 매칭되는 부서 선택.

- Frontend: 컴포넌트, UI, UX, 디자인, CSS, Globe, Three.js, i18n, 접근성 등
- Engineering: ML, 모델, Supabase, DB, Edge Function, 테스트, 보안, 성능 등
- Operations: 배포, CI/CD, 문서, 위키, 비용, 커밋, PR, 릴리스 등

### Tier-2: 전문가 패턴 매칭

`match_agents()`: 12개 에이전트별 regex 패턴으로 직접 매칭.

예: `globe-specialist` ← Globe, Three.js, Canvas, 3D, 파티클, d3-geo
예: `ml-researcher` ← ML, AOD, SDID, PINN, DQSS, GNN, XGBoost

---

## 4. 워크플로우 4종

정본: `AirLens-web/.claude/agents/workflows.json`

| 워크플로우 | 트리거 | 단계 |
|-----------|--------|------|
| **feature-dev** | FEATURE | Plan(Sonnet) → 전문가 구현(부서 모델) → code-reviewer(Sonnet) |
| **multi-dept** | MULTI_DEPT | Plan → 전문가들 **병렬**(부서 모델) → code-reviewer + test-engineer **병렬** |
| **bug-fix** | FEATURE + 버그 키워드 | 전문가 진단+수정 → test-engineer 검증 |
| **query** | QUERY | 전문가 분석(Sonnet, 200단어) |

`{matched_specialist}` / `{matched_agents}` / `{dept_model}` 템플릿 변수가 런타임에 치환.

---

## 5. 상태 머신 (State Machine)

`/tmp` 파일 플래그로 Write/Edit 허용 조건을 제어:

```
[UserPromptSubmit]
  supervisor-auto-route.py
    ├─ FEATURE → /tmp/airlens-intent-feature 생성
    │            /tmp/airlens-harness-mode = "MEDIUM"
    │            /tmp/airlens-required-agents = ["matched_agent_1", ...]
    │
    └─ SIMPLE_EDIT → 플래그 전부 삭제

[PreToolUse: Write/Edit]
  supervisor-enforcer.py
    └─ intent-feature 존재 + plan-approved 미존재 → 차단
       "Plan Mode를 먼저 실행하세요"

[PostToolUse: Agent/ExitPlanMode]
  plan-gate.py
    └─ Plan 완료 감지 → /tmp/airlens-plan-approved 생성

[PreToolUse: Write/Edit]
  agent-dispatch-enforcer.py
    └─ required-agents 존재 + dispatched-agents 미존재 → 차단
       "전문 에이전트를 디스패치하세요"

[PostToolUse: Agent]
  record-agent-routing.py
    └─ 에이전트 호출 기록 + /tmp/airlens-dispatched-agents 생성

[PreToolUse: Write/Edit]
  모든 가드 통과 → Write/Edit 허용
```

---

## 6. 전체 훅 체인 설계 (20개 스크립트)

정본 설계: `scripts/hooks/**`

현재 활성 등록: `AirLens-web/.claude/settings.local.json`

주의: 아래 목록은 AirLens 전용 하네스의 전체 설계 인벤토리다. 2026-04-27 현재 AirLens-web에서 실제 활성화한 것은 안전한 최소 세트이며, supervisor/agent-dispatch 강제 계열은 false block 위험 때문에 보류했다.

### SessionStart (1개)

| 훅 | 역할 |
|----|------|
| `session-init.py` | 세션 초기화 |

### UserPromptSubmit (3개)

| 훅 | 역할 |
|----|------|
| `supervisor-auto-route.py` | 의도 분류 + 부서/에이전트 매칭 + 플래그 설정 |
| `record-github-repos.py` | GitHub 레포 자동 기록 |
| `record-chat-log.py` | 채팅 로그 자동 기록 → `wiki/log/chat-log-{date}.md` |

### PreToolUse — Write/Edit (5개)

| 훅 | 역할 |
|----|------|
| `check-hardcoding.py` | 인라인 상수 차단 (색상, 메타데이터, gradient) |
| `route-change-guard.py` | App.tsx 라우트 레이아웃 일관성 검증 |
| `supervisor-enforcer.py` | FEATURE 의도 시 Plan 미완료면 차단 |
| `agent-dispatch-enforcer.py` | 전문 에이전트 미디스패치 시 차단 |
| `tdd-guard.sh` | 테스트 파일 존재 확인 |

### PreToolUse — Bash (1개)

| 훅 | 역할 |
|----|------|
| `pre-tool-guard.sh` | Bash 명령어 보안 가드 |

### PostToolUse — Write/Edit (4개)

| 훅 | 역할 |
|----|------|
| `post-edit-quality-check.py` | 편집 후 품질 검사 |
| `check-cross-store.sh` | Store 간 직접 호출 감지 (ECS 규칙) |
| `record-session-activity.py` | 활동 기록 |
| `wiki-auto-index.py` | 위키 자동 인덱싱 |

### PostToolUse — Bash (1개)

| 훅 | 역할 |
|----|------|
| `circuit-breaker.py` | 에러 패턴 반복 감지 |

### PostToolUse — Agent (2개)

| 훅 | 역할 |
|----|------|
| `plan-gate.py` | Plan 완료 확인 → plan-approved 플래그 |
| `record-agent-routing.py` | 디스패치 기록 → `wiki/log/agent-routing-{date}.md` + dispatched 플래그 |

### Stop (3개)

| 훅 | 역할 |
|----|------|
| `session-quality-gate.py` | 세션 품질 검증 |
| `session-daily-summary.py` | 당일 활동 요약 기록 |
| `session-close.sh` | 세션 정리 (플래그 삭제 등) |

---

## 7. 관측성 (Observability)

- **에이전트 라우팅 로그**: `record-agent-routing.py` → `wiki/log/agent-routing-{date}.md`
  - 형식: `{HH:MM} — {subagent_type} | {description} | model={model}`
- **채팅 로그**: `record-chat-log.py` → `wiki/log/chat-log-{date}.md`
- **활동 기록**: `record-session-activity.py` → 세션별 활동 추적
- **GitHub 레포 기록**: `record-github-repos.py` → 참조 레포 자동 등록

---

## 8. 마스터 레지스트리와 글로벌 폴백

마스터 레지스트리는 2026-04-29 기준 59개 큐레이션 에이전트를 포함한다. 그중 `AirLens-web` scope는 21개이며, 신규 `ui-ux-director`는 디자인 방향 설계 전용이다.

`~/.claude/agents/` (ECC v1.10.0 기반)

프로젝트 에이전트가 없는 분야의 폴백:
- 언어별 리뷰어: typescript-reviewer, python-reviewer, rust-reviewer 등
- 빌드 해결: build-error-resolver, cpp-build-resolver 등
- 범용: architect, planner, code-reviewer, security-reviewer 등

**Resolution 규칙**: 프로젝트 에이전트 ID = 글로벌 에이전트 ID인 경우 프로젝트 우선.

---

## 관련 개념

- [[에이전트 시스템 설계]] — 역사적 배경 (5부서 → 3부서 진화)
- [[하네스 엔지니어링]] — PGE 루프, 서킷 브레이커
- [[설정 계층 구조]] — CLAUDE.md, Rules, Hooks 전체 맵
- [[Claude Code 에코시스템]] — 플러그인, MCP 서버 전체 인벤토리
- [[ECS 철학의 웹 아키텍처 적용|wiki/concepts/ecs-philosophy-web.md]] — Store 간 호출 금지 (check-cross-store.sh)
