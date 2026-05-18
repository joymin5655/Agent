---
title: "하네스 시스템 v4 — 자율 에이전트 제어 아키텍처"
type: concept
created: 2026-04-20
updated: 2026-04-20
sources: [supervisor-auto-route.py, supervisor-enforcer.py, registry-tier1.json, agent-auto-dispatch.md]
tags: [harness, agent-system, automation, PGE, supervisor, hooks]
audience: ai
priority: medium
---

# 하네스 시스템 v4 — 자율 에이전트 제어 아키텍처

## 설명

> "AI 에이전트가 실수했을 때, 프롬프트를 고치지 마세요. 마구(harness)를 고치세요."

하네스 = 에이전트가 정해진 경로를 벗어나지 못하게 하는 **물리적 제어 장치**.
Prompt Engineering → Context Engineering → **Harness Engineering** → Agentic Engineering의 3번째 축.

## 아키텍처 개요

```
사용자 프롬프트 입력
     │
     ▼
┌──────────────────────────────────┐
│ [UserPromptSubmit] Supervisor v4  │
│  → 의도 분류 (5종)                │
│  → 부서 매칭 (3부서)              │
│  → 에이전트 직접 매칭 (12패턴)     │
│  → 하네스 모드 설정               │
│  → systemMessage 주입             │
└──────────┬───────────────────────┘
           │
           ▼
┌──────────────────────────────────┐
│ [PreToolUse] Gate Layer           │
│  → check-hardcoding.py (상수)     │
│  → route-change-guard.py (라우트) │
│  → supervisor-enforcer.py (Plan)  │
│     FEATURE + Plan없음 → 🚫 BLOCK │
└──────────┬───────────────────────┘
           │ (통과 시)
           ▼
┌──────────────────────────────────┐
│ Claude 도구 실행                   │
│  → Write / Edit / Bash / Agent   │
└──────────┬───────────────────────┘
           │
           ▼
┌──────────────────────────────────┐
│ [PostToolUse] Feedback Layer      │
│  → post-edit-quality-check.py    │
│  → record-session-activity.py    │
│  → plan-gate.py (Agent 실행 시)   │
│  → record-agent-routing.py       │
└──────────┬───────────────────────┘
           │
           ▼
┌──────────────────────────────────┐
│ [Stop] Evaluation Layer           │
│  → session-quality-gate.py       │
│  → session-daily-summary.py      │
└──────────────────────────────────┘
```

## 하네스 3계층 가이드

### 계층 1: 물리적 차단 (Gate)

| 훅 | 타이밍 | 동작 | 무시 가능? |
|---|---|---|---|
| `supervisor-enforcer.py` | PreToolUse:Write\|Edit | FEATURE시 Plan 없으면 BLOCK | **불가능** |
| `check-hardcoding.py` | PreToolUse:Write\|Edit | 하드코딩 상수 감지 → 경고 | 경고만 |
| `route-change-guard.py` | PreToolUse:Edit | App.tsx Route 변경 → 레이아웃 검증 요구 | 경고만 |

**핵심**: Claude가 아무리 "직접 하는 게 빠르다"고 판단해도, BLOCK된 도구는 실행 불가.

### 계층 2: 즉시 피드백 (Feedback)

| 훅 | 타이밍 | 동작 |
|---|---|---|
| `post-edit-quality-check.py` | PostToolUse:Write\|Edit | 인라인 타입, 하드코딩 색상, i18n 누락 감지 → systemMessage |
| `plan-gate.py` | PostToolUse:Agent | Plan 에이전트 실행 완료 → 플래그 설정 → enforcer 통과 허용 |
| `record-agent-routing.py` | PostToolUse:Agent | 에이전트 호출 기록 (observability) |
| `record-session-activity.py` | PostToolUse:Write\|Edit\|Bash | 활동 로그 실시간 기록 |

**핵심**: 코드 변경 직후 문제를 알려줌. Claude의 다음 응답에서 수정하도록 유도.

### 계층 3: 프로토콜 주입 (Protocol)

| 훅 | 타이밍 | 동작 |
|---|---|---|
| `supervisor-auto-route.py` v4 | UserPromptSubmit | 의도/부서/에이전트 분석 → 구체적 행동 지시 |
| `.claude/rules/agent-auto-dispatch.md` | 프로젝트 규칙 (항상) | 에이전트 자동 호출 규칙 |
| `.claude/rules/agent-self-improvement.md` | 프로젝트 규칙 (항상) | 자체 평가 + 학습 루프 |
| `.claude/rules/agent-knowledge-base.md` | 프로젝트 규칙 (항상) | 참조 자료 인덱스 |

**핵심**: Claude 컨텍스트에 "이렇게 해야 한다"가 주입됨. 규칙 파일은 systemMessage보다 강력.

## PGE 품질 루프

```
┌─────────┐     ┌───────────┐     ┌───────────┐
│  Plan   │────▶│ Generate  │────▶│ Evaluate  │
│ (설계)   │     │ (구현)     │     │ (검증)    │
└─────────┘     └───────────┘     └─────┬─────┘
                                        │
                              점수 < 7.0? │ YES
                                        ▼
                                  ┌───────────┐
                                  │  Retry    │ ← 최대 5회
                                  └───────────┘
```

### 평가 기준 (10점)

| 차원 | 배점 | 검증 방법 |
|---|---|---|
| Build | 2 | `npm run build` 통과 |
| Lint | 2 | `npm run lint` 통과 |
| Test | 2 | 테스트 통과 + 커버리지 ≥ 80% |
| Code Quality | 2 | style-reviewer + performance-reviewer |
| AirLens Rules | 2 | 하드코딩 X, types.ts, i18n, config |

### 임계값

- **≥ 7.0 + 차원별 0점 없음** → PASS
- **5.0 – 6.9** → 자동 재시도 (최대 5사이클)
- **< 5.0** → 구조적 분석 + 사용자 에스컬레이션

### 서킷 브레이커

| 실패 | 대응 |
|---|---|
| 1회 | 피드백 기반 재시도 |
| 2회 | 모델 업그레이드 (haiku→sonnet→opus) |
| 3회 | 사용자에게 에스컬레이션 |

## Supervisor v4 의도 분류

| 의도 | 설명 | 하네스 대응 |
|---|---|---|
| FEATURE | 멀티파일 새 기능 | Plan 강제 + PGE 루프 |
| MULTI_DEPT | 크로스 부서 작업 | Full Harness (HIGH) + 병렬 디스패치 |
| QUERY | 정보 요청 | 전문 에이전트 자동 매칭 → 호출 권장 |
| SIMPLE_EDIT | 단일 파일 수정 | 에이전트 매칭 후 직접 실행 허용 |
| RECALL | 메모리/히스토리 검색 | wiki-curator 라우팅 |
| LEARN | 패턴 추출/스킬 생성 | supervisor 자체 처리 |

## 에이전트 자동 디스패치 (12개 패턴)

Supervisor가 프롬프트를 분석하여 **구체적 전문 에이전트**를 자동 매칭:

| 키워드 패턴 | 에이전트 |
|---|---|
| Globe, Three.js, Canvas, 파티클 | globe-specialist |
| ML, AOD, SDID, PINN, XGBoost | ml-researcher |
| DB, RLS, 스키마, 마이그레이션 | db-architect |
| 컴포넌트, UI, 버튼, 모달 | component-builder |
| UX, 사용성, 휴리스틱 | ux-reviewer |
| 보안, XSS, injection, CSRF | security-reviewer |
| 테스트, 커버리지, E2E, TDD | test-engineer |
| 번역, i18n, 다국어 | i18n-specialist |
| 성능, 번들, LCP, CWV | performance-reviewer |
| 위키, Obsidian, index.md | wiki-curator |
| ETL, 파이프라인, 전처리 | data-engineer |
| 비용, 토큰, quota | cost-analyst |

## 우회 메커니즘

긴급 수정이 필요할 때 Gate를 우회:
- 프롬프트에 **"빠르게"**, **"quick fix"**, **"hotfix"** 포함 시 enforcer 비활성화
- 설정/인프라 파일 (.claude/, CLAUDE.md, package.json 등)은 항상 허용

## 자기 개선 루프 (autoresearch 패턴)

```
작업 완료 → 자체 PGE 평가 (10점)
  → 7.0 미만: 부족한 차원의 전문 에이전트 호출하여 수정
  → 발견/교훈을 Obsidian wiki/log/learnings-{날짜}.md에 기록
  → 다음 세션에서 피드백 기반 개선
```

## Expert Priming (v2)

모든 19개 에이전트에 **전문가 도메인 프라이밍** 적용:
- 실제 전문가 이름 + 프레임워크로 MoE 잠재공간 활성화
- 참조 자료 경로 지정 (Skills/ 디렉토리)
- 박사급 품질 기준 + 반-패턴 목록

상세: [[에이전트 전문성 맵 v2]]

## 파일 시스템 구조

```
scripts/hooks/
├── supervisor-auto-route.py    # UserPromptSubmit — 의도/부서/에이전트 분석
├── supervisor-enforcer.py      # PreToolUse — FEATURE시 Plan 강제
├── plan-gate.py                # PostToolUse — Plan 완료 플래그
├── check-hardcoding.py         # PreToolUse — 하드코딩 감지
├── route-change-guard.py       # PreToolUse — 라우트 변경 가드
├── post-edit-quality-check.py  # PostToolUse — 코드 품질 검사
├── record-session-activity.py  # PostToolUse — 활동 기록
├── record-agent-routing.py     # PostToolUse — 에이전트 호출 추적
├── session-quality-gate.py     # Stop — 세션 종료 품질 요약
├── session-daily-summary.py    # Stop — 일일 요약
└── session-init.py             # SessionStart — 플래그 클린업

.claude/rules/
├── agent-auto-dispatch.md      # 에이전트 자동 호출 규칙
├── agent-knowledge-base.md     # 참조 자료 인덱스
├── agent-self-improvement.md   # 자기 평가 + 학습 루프
├── canvas-rendering.md         # Canvas 2D 규칙
├── data-fetching.md            # 서버 수집 원칙
└── no-hardcoding.md            # 3대 원칙

.claude/agents/ (19개)
├── registry.json (v2.0)        # Expert-Primed 레지스트리
├── registry-tier1.json         # 부서 라우팅 키워드
└── *.md                        # 각 에이전트 (전문가 프라이밍 적용)
```

## 외부 참조 (2026-04-20 조사 완료)

| 출처 | 핵심 패턴 | AirLens 적용 |
|---|---|---|
| Anthropic Building Effective Agents | 5가지 오케스트레이션 패턴, ACI=UX | Supervisor v4 라우팅 |
| Claude Agent SDK | Gather→Act→Verify→Repeat, 서브에이전트 격리 | PGE 루프 |
| OpenAI Harness Engineering | Golden Principles, Observe→Plan→Act→Verify | enforcer + PGE |
| OpenAI Codex Agent Loop | Control Plane / Sandbox 분리 | PreToolUse/PostToolUse 분리 |
| Google ADK | 계층적 멀티에이전트, A2A 프로토콜 | 2-Tier 라우팅 |
| awesome-harness-engineering | 서브에이전트 67% 토큰 절약, SkillsBench | 컨텍스트 격리 원칙 |
| Karpathy autoresearch | 자율 실험 루프 (program.md) | 자기 개선 루프 |
| Hermes Agent | 자기개선 메모리, 세션 검색, 스킬 학습 | wiki-curator, 세션 인덱서 |

## 관련 문서

- [[에이전트 시스템 설계]] — 2-Tier 라우팅, 5부서 구조
- [[하네스 엔지니어링]] — 초기 4기둥 설계 (v1-v3)
- [[에이전트 시스템 적용 실패 분석 및 방지 계획]] — 갭 분석 + 방지 설계
- [[에이전트 전문성 맵 v2]] — 19개 에이전트 전문가 프라이밍 상세
