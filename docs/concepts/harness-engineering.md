---
title: "하네스 엔지니어링"
type: concept
created: 2026-04-08
updated: 2026-04-15
sources: [raw/articles/harness-engineering.md]
tags: [harness, AI-safety, feedback-loop, circuit-breaker, quality]
audience: ai
priority: medium
---

# 하네스 엔지니어링

## 설명

> "AI 에이전트가 실수했을 때, 프롬프트를 고치지 마세요. 마구(harness)를 고치세요."

AI가 실수할 수 없는 환경을 구조적으로 만드는 기술. Prompt Engineering → Context Engineering → **Harness Engineering** → Agentic Engineering의 4축 중 3번째.

## 4가지 기둥

### 기둥 1: 기계가 읽는 컨텍스트 파일
- CLAUDE.md 계층 구조 (루트 1 + 서브프로젝트 15 + 규칙 8 + 에이전트 25+)
- docs/ 캐시 레이어 (docs-first-cache 3단계 캐스케이드)

### 기둥 2: 결정론적 CI/CD 게이트
- pre-commit: API 키 차단
- pre-tool-use: SERVICE_ROLE_KEY 노출, rm -rf, secrets/ 수정 차단
- post-tool-use: 자동 검증 + 커밋 로그 축적
- PGE 품질 게이트: 7.0/10.0 기준

### 기둥 3: 명시적 도구 경계
- 부서별 도구 격리 (비활성 부서의 도구 미로딩)
- Hook 차단 (물리적 차단 ≠ 프롬프트 부탁)

### 기둥 4: 지속적 피드백 루프
- CI/린트 실패 → `memory/feedback_ci_checklist.md`
- Hook 차단 3회 → `/learn-from-failure` 자동 트리거
- PGE 5.0 미만 → 구조적 분석
- 서킷 브레이커: 1회 재시도 → 5초 대기 → 모델 다운그레이드 → ESCALATE

## 기둥 5: 자기 개선 학습 루프 (Closed Learning Loop)

hermes-agent + autoresearch 패턴에서 도입 (2026-04-15).

### 현재 구현된 학습 경로
1. **오류 패턴 축적**: CI 실패 → `memory/feedback_ci_checklist.md`에 패턴 추가
2. **3회 반복 트리거**: 같은 패턴 3회 → `/learn-from-failure` 실행 → Hook/규칙 강화
3. **세션 기록**: Stop 훅 → `Obsidian-airlens/raw/sessions/`에 세션 요약

### 추가된 학습 경로 (클론 레포 패턴 적용)
4. **에이전트 레벨 계층**: registry.json에 level 1-4 도입 → supervisor가 복잡도에 맞는 에이전트 선택 (oh-my-claudecode 패턴)
5. **자율 리서치 루프**: research-loop 에이전트 — 단일 파일 수정, 고정 시간 예산, 메트릭 중심 반복 (autoresearch 패턴)
6. **스킬 자동 생성 후보**: 세션에서 3회 이상 반복된 수동 작업 → 스킬 후보로 제안 (hermes-agent 패턴)

### 학습 루프 흐름
```
작업 수행 → 오류/패턴 감지 → memory/ 기록 → 3회 반복 → 규칙/훅 강화
                                                    ↓
                                              스킬 후보 제안
                                                    ↓
                                         사용자 승인 → 스킬 생성
```

## 에이전트 레벨 계층 (Level Hierarchy)

oh-my-claudecode 패턴에서 도입. registry.json의 각 에이전트에 `level` 필드 추가.

| Level | 역할 | 모델 | 예시 |
|-------|------|------|------|
| 1 | 기본 도구 — 포맷팅, 린트, 단순 조회 | haiku | deploy-manager, i18n-specialist |
| 2 | 실행자 — 코드 작성, 분석 | sonnet | component-builder, model-trainer |
| 3 | 전문가 — 아키텍처, 도메인 심층 | sonnet/opus | db-architect, security-reviewer |
| 4 | 오케스트레이터 — 다중 에이전트 조율 | opus | research-loop |

## 관련 개념

- [[에이전트 시스템 설계]] — 2-Tier 라우팅과 PGE 루프
- [[리뷰 시스템]] — 3-Layer 코드 리뷰
- [[AirLens 9대 엔진 모듈별 연구·원리 분석]] — research-loop 에이전트의 대상 엔진
