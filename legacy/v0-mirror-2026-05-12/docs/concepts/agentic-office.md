---
title: 에이전트 기반 오피스 v2
type: concept
created: 2026-04-16
updated: 2026-04-16
sources: [docs/]
tags: [migrated-from-docs]
audience: ai
priority: medium
---

# 나만의 에이전틱 오피스 구축 가이드 (v2.0)

> AirLens 플랫폼 기존 인프라를 활용한 AI 에이전트 팀 구성 및 웹 관리 시스템

---

## 1. 에이전트 팀 구성을 위한 핵심 도구

에이전트 팀은 단순한 챗봇이 아니라, 리더와 팀원이 역할을 분담하여 병렬로 작업을 수행하는 구조입니다.

### Claude Agent SDK (Python/TypeScript)

Claude Messages API + `tool_use`를 활용해 **자율적 판단-실행 루프**를 구축하는 SDK입니다. 에이전트에게 고유한 시스템 프롬프트, 도구 세트, 권한 범위를 부여하여 개별 전문가(예: 대기질 분석가, 정책 평가자, 데이터 품질 검사관)를 직접 코딩할 수 있습니다.

**핵심 동작 원리:**
```
사용자 요청 → Claude API (tool_use) → 도구 실행 → 결과 반환 → Claude가 다음 판단 → 반복
```

### Model Context Protocol (MCP)

노션, Supabase, Cloudflare 등 외부 서비스를 에이전트와 연결하는 표준 프로토콜입니다. AirLens에는 이미 Supabase MCP와 Cloudflare MCP가 구성되어 있어, 에이전트가 DB 조회, Edge Function 배포, 페이지 관리를 직접 수행할 수 있습니다.

**AirLens 기 구성 MCP:**
| MCP 서버 | 역할 |
|----------|------|
| Supabase | DB 쿼리, 마이그레이션, Edge Function 관리 |
| Cloudflare | Pages 배포, DNS, Workers 관리 |
| Notion | 프로젝트 문서 읽기/업데이트 |

### 에이전트 팀 아키텍처

팀 리드(Lead)가 전체 계획을 세우고 작업을 분배하면, 팀메이트(Teammates)가 공유된 **작업 목록(Task List)**을 통해 각자의 작업을 수행합니다. 에이전트 간 소통은 **Handoff** (작업 위임) 또는 **Shared Context** (공유 컨텍스트)를 통해 이루어집니다.

```
┌─────────────────────────────────────┐
│         오케스트레이터 (Lead)          │
│    계획 수립 → 작업 분배 → 결과 종합    │
└──────┬──────────┬──────────┬────────┘
       │          │          │
  ┌────▼────┐ ┌──▼────┐ ┌──▼──────┐
  │ 분석가   │ │ 예측가 │ │ 리포터   │
  │ (PM2.5) │ │ (AOD)  │ │ (보고서) │
  └─────────┘ └────────┘ └─────────┘
       │          │          │
       └──────────┼──────────┘
                  ▼
          agent_jobs 테이블
          (Supabase Realtime)
```

---

## 2. 기존 인프라 재활용 원칙

AirLens에 이미 구축된 자산을 최대한 활용하여 중복 개발을 피합니다.

### 재사용 가능한 기존 자산

| 기존 자산 | 에이전트 활용 방안 |
|-----------|------------------|
| **Supabase Realtime** (WebSocket) | 에이전트 상태를 `agent_jobs` 테이블에 기록, Realtime으로 웹에 스트리밍 |
| **19개 Edge Functions** | 에이전트 "도구(tool)"로 직접 래핑 (predict, check-usage, policy 등) |
| **FastAPI :8000** (6개 ML 모델) | 에이전트가 호출할 분석 도구 — AOD→PM2.5, SDID, Camera AI, DQSS 등 |
| **check-usage 쿼터 시스템** | 에이전트 호출에도 동일 쿼터 적용 → 비용 제어 |
| **RLS 정책** | 에이전트 결과도 사용자별 격리 자동 적용 |
| **Claude Code Hooks** (agent-flow/) | SessionStart~Stop 전 이벤트를 hook.js로 포워딩 |
| **notificationStore.ts** | 에이전트 완료 알림을 기존 알림 시스템에 통합 |
| **ingest-ml-results 패턴** | 에이전트 결과 DB 직접 쓰기 패턴 재사용 |

### 신규 구축 vs 기존 활용 대조

| 기능 | 원래 계획 (신규) | 개선 (기존 활용) |
|------|-----------------|-----------------|
| 실시간 스트리밍 | Trigger.dev 도입 | Supabase Realtime (이미 구축) |
| 작업 모니터링 | Agent Flow 노드 그래프 | agent_jobs 테이블 + React 대시보드 |
| 관측성 대시보드 | Arize Phoenix / LangSmith | agent_jobs 집계 + Chart.js (이미 사용 중) |
| 외부 도구 연결 | 새 MCP 구축 | 기존 Supabase/Cloudflare/Notion MCP |
| 인증/권한 | 새 시스템 | Supabase Auth + RLS (이미 구축) |

---

## 3. 웹 페이지 구현 — 기존 AirLens 웹앱에 통합

AirLens는 이미 React 19 + Vite 7 + Supabase 웹앱이 운영 중이므로, **기존 웹앱에 에이전트 대시보드 페이지를 추가**하는 것이 가장 자연스럽습니다.

### 아키텍처

```
AirLens-web/src/pages/
└── AgentDashboard.tsx   # 새 라우트 /agent (인증 필수)
    ├── AgentChat.tsx     # 채팅 UI (에이전트와 대화)
    ├── AgentJobs.tsx     # 작업 현황판 (Supabase Realtime 구독)
    └── AgentMetrics.tsx  # 토큰/비용/성공률 대시보드
```

### 데이터 흐름

```
사용자 → React UI → agent-proxy Edge Function → Claude API (tool_use)
                          │                           │
                     JWT 인증                    Tool 실행
                     쿼터 확인              (기존 Edge Functions / FastAPI)
                          │                           │
                          └───── agent_jobs 테이블 UPDATE ──────┘
                                        │
                                Supabase Realtime
                                        │
                                React UI 실시간 반영
```

### DB 스키마 추가

```sql
-- 에이전트 작업 추적
CREATE TABLE agent_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users NOT NULL,
  agent_type text NOT NULL,        -- 'analyst', 'forecaster', 'reporter'
  status text DEFAULT 'pending',   -- pending → running → completed → failed
  input jsonb NOT NULL,
  output jsonb,
  tokens_used integer DEFAULT 0,
  cost_usd numeric(10,6) DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  completed_at timestamptz
);

ALTER TABLE agent_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users see own jobs" ON agent_jobs
  FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users create own jobs" ON agent_jobs
  FOR INSERT WITH CHECK (auth.uid() = user_id);
```

### 원격 접근 방법

로컬 에이전트 팀 세션을 외부에서 관리해야 할 때:
- **claude.ai/code** 웹 앱으로 브라우저에서 접속
- **SSH 터널** + VS Code Remote로 로컬 환경 유지
- **VS Code Live Share**로 실시간 협업

---

## 4. 보안 설계

### API 키 관리

```
[브라우저] ──JWT──→ [agent-proxy Edge Function] ──ANTHROPIC_API_KEY──→ [Claude API]
                         ↑
                   SERVICE_ROLE_KEY
                   (서버 사이드 전용)
```

- **절대 금지**: `VITE_ANTHROPIC_API_KEY`로 브라우저 번들에 API 키 포함
- **필수**: Supabase Edge Function (`agent-proxy`)을 통해 서버 사이드에서만 Claude API 호출
- **키 저장**: `secrets/web.env.local`에 `ANTHROPIC_API_KEY` 추가 + `supabase secrets set`

### 에이전트 권한 경계

| 에이전트 역할 | 읽기 권한 | 쓰기 권한 |
|-------------|----------|----------|
| 분석가 (Analyst) | predictions, waqi_snapshots, aod_observations | agent_jobs (본인) |
| 예측가 (Forecaster) | 전체 데이터 테이블 | predictions, dqss_scores |
| 리포터 (Reporter) | agent_jobs, predictions | 없음 (읽기 전용) |

Edge Function 레벨에서 `agent_role` 파라미터로 권한 검증

### 비용 폭주 방지

- 기존 `check-usage` RPC 확장 → `agent_calls` 카운터 추가
- 일일 토큰 한도: Free=1K, Explorer=10K, Researcher=100K
- 비용 초과 시 자동 중단 + 기존 notificationStore로 알림
- `agent_jobs.cost_usd` 집계로 실시간 비용 모니터링

---

## 5. 지능형 팀 관리 및 자동화

### CLAUDE.md 기반 팀 지침

모든 에이전트가 공유하는 운영 지침서. AirLens의 기존 CLAUDE.md 계층 구조를 활용:
- 루트 `CLAUDE.md` → 전체 아키텍처, 보안 규칙
- `AirLens-web/CLAUDE.md` → 프론트엔드 규칙
- `AirLens-models/CLAUDE.md` → ML 파이프라인 규칙
- `.claude/rules/` → 파일 패턴별 조건부 규칙

### Hooks 자동화

기존 `.claude/settings.json`에 이미 구성된 hooks 인프라 활용:

```json
{
  "hooks": {
    "PostToolUse": ["node agent-flow/hook.js"],
    "SubagentStart": ["node agent-flow/hook.js"],
    "SubagentStop": ["node agent-flow/hook.js"],
    "Stop": ["node agent-flow/hook.js"]
  }
}
```

확장 가능한 자동화:
- 에이전트 작업 완료 시 → Notion 자동 동기화 (기존 Notion MCP)
- 이상치 감지 시 → 기존 notificationStore로 실시간 알림
- 주기적 분석 → Supabase pg_cron 또는 Edge Function cron

### 에러 처리 & 폴백 전략

| 상황 | 대응 |
|------|------|
| Claude API 타임아웃 | 3회 exponential backoff 재시도 |
| Tool 실행 실패 | 부분 결과 반환 + 실패 도구 명시 |
| 토큰 한도 초과 | 즉시 중단 + 사용자 알림 |
| Edge Function 15s 제한 | 장시간 작업은 FastAPI로 위임 |

---

## 6. 구독 티어별 에이전트 접근 제어

기존 AirLens의 Free/Explorer/Researcher 플랜 체계를 에이전트에도 적용:

| 기능 | Free | Explorer | Researcher |
|------|------|----------|------------|
| 기본 대기질 질문 | ✅ | ✅ | ✅ |
| PM2.5 예측 에이전트 | ❌ | ✅ | ✅ |
| 정책 분석 에이전트 | ❌ | ❌ | ✅ |
| 멀티 에이전트 팀 | ❌ | ❌ | ✅ |
| 일일 에이전트 호출 | 5회 | 50회 | 500회 |
| 자동 보고서 생성 | ❌ | ✅ (주 1회) | ✅ (일 1회) |

---

## 7. 실행 로드맵

### Phase 0: 기반 구축 (1일)
- [ ] `agent_jobs` + `agent_metrics` Supabase migration 생성
- [ ] `agent-proxy` Edge Function 생성 (Claude API 프록시 + JWT 인증 + 쿼터 확인)
- [ ] `secrets/web.env.local`에 `ANTHROPIC_API_KEY` 추가 + `supabase secrets set`

### Phase 1: 단일 에이전트 MVP (2-3일)
- [ ] `agent-proxy`에 tool 정의 (기존 Edge Function/FastAPI 래핑)
- [ ] React: `/agent` 페이지 + `AgentChat.tsx` (채팅 UI)
- [ ] Supabase Realtime으로 `agent_jobs` 상태 스트리밍
- [ ] 기존 `check-usage` 확장 → `agent_calls` 쿼터 추가

### Phase 2: 전문가 팀 구성 (3-5일)
- [ ] 에이전트 역할 분리: 분석가, 예측가, 리포터
- [ ] 오케스트레이터 패턴: 리드 에이전트가 서브태스크 분배 (Handoff)
- [ ] `AgentJobs.tsx` 작업 현황판 + `AgentMetrics.tsx` 비용 대시보드
- [ ] 플랜별 접근 제어 적용

### Phase 3: 자율 운영 체계 (5-7일)
- [ ] pg_cron 또는 Edge Function cron으로 주기적 대기질 분석
- [ ] 결과 자동 Notion 동기화 (기존 Notion MCP 활용)
- [ ] 이상치 감지 → 자동 알림 (기존 notificationStore)
- [ ] 관측성: 토큰 사용량, 에러율, 평균 응답시간 차트

---

## 8. 테스트 전략

| 레벨 | 대상 | 도구 |
|------|------|------|
| Unit | Tool 정의 함수 (입출력 검증) | Vitest |
| Integration | agent-proxy → Claude API → Tool 실행 흐름 | Vitest + MSW (API mock) |
| E2E | /agent 페이지 전체 워크플로우 | Playwright |
| Cost | 토큰 사용량 + 비용 정확성 | 커스텀 assertion |

---

*작성일: 2026-03-30 | 버전: v2.0 | 기반: AirLens Platform 기존 인프라*
