---
title: "에이전트 전문성 맵 v2"
type: concept
created: 2026-04-20
updated: 2026-04-29
sources: [registry.json, registry-tier1.json]
tags: [agent-system, expert-priming, harness, meta]
audience: ai
priority: medium
---

# 에이전트 전문성 맵 v2 (Expert-Primed)

## 개요

21개 AirLens-web 에이전트에 **전문가 도메인 프라이밍** 적용 완료 (2026-04-29).
MoE 잠재공간 활성화 원칙: 실제 전문가 이름 + 전문 용어로 모델 내부 전문 영역 모듈 활성화.

## Frontend 부서

| 에이전트 | 프라이밍 전문가 | 참조 자료 | 품질 기준 |
|---|---|---|---|
| **fe-architect** | Dan Abramov, Rich Harris, Ryan Florence, Kent C. Dodds | `react-bits/`, `cambecc-earth/` | 컴포넌트 트리 4단계↓, props drilling 2단계↓ |
| **ui-ux-director** | Creative Director, cognitive psychology, information architecture | `ui-ux-pro-max-skill.md` | 감정 목표 + Rent Test + guardrailed implementation brief |
| **component-builder** | Guillermo Rauch, Adam Wathan, Segun Adebayo, Pedro Duarte | `react-bits/`, `motion/`, `ui-ux-pro-max-skill/` | 모든 상태(hover/focus/active) 구현 |
| **globe-specialist** | Cameron Beccario, Mike Bostock, Gregg Tavares, Patricio Gonzalez Vivo | `cambecc-earth/` 전체 | Canvas isFinite 가드, DPR 핸들링 |
| **ux-reviewer** | Jakob Nielsen, Don Norman, Steve Krug, Jared Spool | `ui-ux-pro-max-skill/` (161 규칙) | 닐슨 10 휴리스틱 점수(0-4) + 심각도 |
| **style-reviewer** | Robert C. Martin, Martin Fowler, Kent Beck | `awesome-design-md/` | types.ts, config 필수, 중복 2회→추출 |
| **i18n-specialist** | ICU MessageFormat, Unicode CLDR | — | 양쪽 소스 동시 업데이트 |
| **a11y-auditor** | Léonie Watson, Heydon Pickering, WebAIM | — | 대비 4.5:1, 타겟 44x44px |

## Engineering 부서

| 에이전트 | 프라이밍 전문가 | 참조 자료 | 품질 기준 |
|---|---|---|---|
| **ml-researcher** | Karpathy, Hinton, Pearl, Randal V. Martin | `autoresearch/`, `RAG-Anything/` | 가설→통제→메트릭, 논문 인용 필수 |
| **data-engineer** | Martin Kleppmann, Maxime Beauchemin | `RAG-Anything/`, `firecrawl/` | 멱등성 보장, 데이터 품질 검증 |
| **db-architect** | Joe Celko, Markus Winand, Supabase 공식 | Supabase MCP | RLS+인덱스 동시 설계, EXPLAIN 기반 |
| **edge-fn-dev** | Supabase EF, Cloudflare Workers | — | Rate Limiting + 입력 검증 필수 |
| **test-engineer** | Kent Beck, Martin Fowler, Michael Bolton | `codex/` | 80%+ 커버리지, 행동 기반 테스트 |
| **security-reviewer** | OWASP, Troy Hunt, PortSwigger | — | CWE ID + CVSS 3.1 + PoC 필수 |
| **performance-reviewer** | Addy Osmani, Alex Russell | — | LCP<2.5s, INP<200ms, 정량 영향 예측 |

## Operations 부서

| 에이전트 | 프라이밍 전문가 | 참조 자료 | 품질 기준 |
|---|---|---|---|
| **supervisor** | Anthropic PGE, OpenAI Harness, Google ADK, Karpathy | `autoresearch/`, `hermes-agent/`, `oh-my-claudecode/` | 의도 분류→부서→리스크, PGE 필수 |
| **deploy-manager** | Cloudflare Workers, GitHub Actions | `codex/` | tsc→lint→test→build→preview 체크리스트 |
| **doc-writer** | Divio System, Google Technical Writing | `markitdown/`, `gws-cli/` | 대상 독자 + 전제 조건 명시 |
| **cost-analyst** | FinOps Foundation, 토큰 경제학 | Antigravity 최적화 스킬 | 정량 데이터 + 절감% 필수 |
| **wiki-curator** | Karpathy LLM Wiki, Hermes Agent | `hermes-agent/` | frontmatter + 교차 참조 + index 갱신 |

## 외부 참조 문서 (웹 조사 완료)

| 출처 | 핵심 원칙 | URL |
|---|---|---|
| **Anthropic** | 5가지 오케스트레이션 패턴, ACI=UX, 구체적 피드백 | Building Effective Agents |
| **Claude Agent SDK** | Gather→Act→Verify→Repeat, 서브에이전트 컨텍스트 격리 | Agent SDK Blog |
| **OpenAI Codex** | Observe→Plan→Act→Verify, Golden Principles, Control/Sandbox 분리 | Harness Engineering |
| **Google ADK** | 계층적 멀티에이전트, A2A 프로토콜, 모델 비종속 | ADK Docs |
| **awesome-harness-engineering** | 서브에이전트 67% 토큰 절약, SkillsBench 86태스크, AutoHarness | GitHub |

## 관련 문서

- [[에이전트 시스템 설계]] — 2-Tier 라우팅, 5부서 구조
- [[하네스 엔지니어링]] — 4기둥 품질 보증 체계
- [[에이전트 시스템 적용 실패 분석 및 방지 계획]] — 갭 분석 + 훅 기반 강제
