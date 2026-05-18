---
title: "에이전트 시스템 설계"
type: concept
created: 2026-04-08
updated: 2026-04-27
sources: [raw/articles/agent-system-design.md]
tags: [agent, multi-agent, routing, PGE, orchestration]
audience: ai
priority: medium
---

# 에이전트 시스템 설계

## 설명

AirLens의 AI 에이전트 오피스. 현재 **3개 부서, 20개 전문 에이전트**로 구성되며, 2-Tier 계층적 라우팅과 PGE(Planner-Generator-Evaluator) 루프로 품질을 보증한다.

> **현행 디스패치 시스템 상세는 [[에이전트 디스패치 시스템|wiki/concepts/agent-dispatch-system.md]] 참조.** 이 페이지는 역사적 배경과 PGE 루프 설명을 유지한다. 설정 계층 전체 맵은 [[설정 계층 구조|wiki/concepts/configuration-hierarchy.md]] 참조.

## 2-Tier 라우팅

```
사용자 요청 → [Tier 0] 리스크 판정 (low/medium/high)
  → [Tier 1] 부서 라우팅 (triggerKeywords 매칭)
    → [Tier 2] 전문가 디스패치 (부서장이 에이전트 선택)
      → [PGE] 품질 보증 (7.0/10.0 기준)
```

## 부서 구성

| 부서 | 역할 | 에이전트 | 기본 모델 |
|------|------|---------|----------|
| ML 연구소 | 6대 ML 엔진 고도화 | 5명 | Sonnet (Opus: SDID) |
| UI/UX | React, Three.js, 접근성 | 5명 | Sonnet (Haiku: a11y) |
| 인프라 | Supabase, EF, 배포, ETL | 4명 | Sonnet (Haiku: deploy) |
| 보안/QA | 보안 감사, PGE 평가, E2E | 6명 | Sonnet (Opus: security) |
| 비즈니스 | 문서, 비용, 정책 연구 | 5명 | Sonnet (Haiku: docs) |

## PGE 루프

- **Generator**: 코드 생성 → **Context Reset** (방화벽) → **Evaluator**: 블라인드 리뷰
- 평가: Build(2) + Lint(2) + Test(2) + Code Quality(2) + AirLens Rules(2) = 10점
- 7.0 미만 또는 차원별 0점 → 자동 재생성 (최대 5사이클)

상세: [[하네스 엔지니어링]] 참조

## 관련 개념

- [[하네스 엔지니어링]] — 4기둥 품질 보증 체계
- [[리뷰 시스템]] — 3-Layer 코드 리뷰 아키텍처


---

## 최신 캐시 (docs/ 병합, 2026-04-04)

# Agent Harness System Cache

## 루트 레벨 문서 (2026-04-04 추가)
- `agent.md` — 에이전트 시스템 온보딩 가이드 (5부서, 25에이전트, 2-Tier 라우팅, 커맨드, 의존성 맵)
- `harness.md` — 하네스 엔지니어링 가이드 (4기둥 AirLens 매핑, PGE 루프, 서킷 브레이커)

## 2-Tier 계층적 라우팅
- Tier 0: 리스크 판정 (low/medium/high) → Fast Path 또는 풀 루프
- Tier 1: registry-tier1.json 키워드 매칭 → 5부서 중 선택
- Tier 2: 부서장(manager.md) → 전문가 에이전트 디스패치

## 5개 부서 구성
| 부서 | 에이전트 수 | 기본 모델 | toolchain |
|------|-----------|----------|-----------|
| ml-research | 5 | Sonnet | HF, Context7, /data-refresh |
| ui-ux | 5 | Sonnet | Playwright, Stitch, /design-review |
| infrastructure | 4 | Sonnet | Supabase, Cloudflare, /ship |
| security-qa | 6 | Sonnet | Playwright, /qa, /cso |
| business | 5 | Sonnet | Notion, /save-progress |

## PGE Loop
- 품질 점수: Build(2) + Lint(2) + Test(2) + CodeQuality(2) + AirLensRules(2) = 10점
- 통과: 7.0 이상 + 차원별 0점 없음 (Hard Minimum)
- 최대 사이클: 5회 (리스크별 max_retries 차등)
- Adversarial: Evaluator는 블라인드 리뷰 (Generator 추론 미전달)

## 피드백 루프
- PGE <5.0 또는 Hook 차단 3회+ → /learn-from-failure 자동 트리거
- 학습 저장: memory/feedback_ci_checklist.md, pre-tool-use.sh, .claude/rules/*.md

## Skills 참조 레포 매핑 (v5.1, 2026-04-18)

`Antigravity/Skills/` 15개 클론 레포를 3부서에 매핑. `registry.json` v5.2의 `reference_repos` 필드와 동기화.

| 레포 | Engineering | Frontend | Operations | 사용 방식 |
|------|:-----------:|:--------:|:----------:|----------|
| `cambecc-earth` | O | | | code-port (`src/lib/earth/`) |
| `autoresearch` | O | | | ML 자율 실험 루프 패턴 |
| `firecrawl` | O | | | MCP 웹 스크래핑 (논문/정책문서 수집) |
| `markitdown` | O | | | Python 문서→마크다운 변환 |
| `RAG-Anything` | O | | | 멀티모달 RAG 지식그래프 검색 |
| `hermes-agent` | O | | O | 세션 학습 루프 + 컨텍스트 압축 |
| `react-bits` | | O | | UI 애니메이션 패턴 참조 |
| `awesome-design-md` | | O | | 59개 사이트 디자인 레퍼런스 |
| `ai-website-cloner-template` | | O | | worktree 병렬 빌더 패턴 |
| `prompt-engineering-skills` | | | O | 모델별 프롬프트 최적화 전략 |
| `oh-my-claudecode` | | | O | 훅/세션 관리 패턴 |
| `gws-cli` | | | O | Google Workspace 자동화 |
| `antigravity-awesome-skills` | | | O | 2,464개 스킬 카탈로그 레퍼런스 |
| `codex` | | | O | CI/CD 코드 리뷰 + 2차 검증 |
| `fabric` | O | | O | 252개 AI 프롬프트 패턴 (분석/생성/추출) |

## 관련 파일
- `.claude/commands/agent-harness.md` — PGE 오케스트레이터 실행 명세
- `.claude/agents/registry-tier1.json` — 5부서 메타데이터
- `.claude/agents/registry.json` — 25에이전트 전체 정의 + Skills 레포 매핑 (v5.2)
- `.claude/agents/shared/cross-dept-hub.md` — 부서 간 의존성, 핸드오프
- `docs/REVIEW_SYSTEM.md` — 3-Layer 리뷰 시스템 상세
- `docs/agentic-office-v2.md` — 웹 기반 에이전트 오피스 설계
