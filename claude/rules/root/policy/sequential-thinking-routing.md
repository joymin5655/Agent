# Sequential-Thinking Routing Rule

## 목적

`mcp__sequential-thinking__sequentialthinking` (1 tool) 의 트리거 조건 + 비-트리거 (회피) + 토큰 예산 정의. 본 plan = `~/.claude/plans/sequential-thinking-activation.md` (Wave 2 P1).

## 활성 상태

`.claude/settings.local.json` `enabledMcpjsonServers` 에 `sequential-thinking` 등록 — 2026-05-06 활성화.

## 트리거 조건 (invoke 권장)

다음 시나리오에서 `sequentialthinking` tool 호출 권장:

| 시나리오 | 예시 |
|---|---|
| Architecture decision | "monorepo packages 분리 영향도", "결제 dual-channel 설계", "RLS 정책 마이그레이션 전략" |
| Multi-step migration plan | "00322~00331 production migration 순서", "Edge Function v1 → v2 cutover" |
| Multi-step refactor | "supervisor.py specialist routing 재설계", "i18n key 전체 audit" |
| ML 학습 step 설계 | AOD / SDID / Camera AI / DQSS / TFT / GNN 학습 pipeline 다단계 결정 |
| Cross-domain trade-off 분석 | "Glass-box AI 우선 vs latency 우선", "Pro tier 게이팅 vs UX simplicity" |

invoke 패턴: 사용자 명시 발화 (`"Use sequential thinking to ..."` / `"sequentialthinking 으로 ..."`) 또는 위 시나리오 자동 인식 후 1차 호출.

## 비-트리거 (회피)

다음 케이스는 **호출 금지**:

- **trivial 1줄 변경** (오타 fix, 변수 rename, 1-line const 추가) — `plan-first-clarifying.md` trivial tier
- **autonomous research** (`/airlens-research`, `/dqss-check`, `/policy-sdid-run`, `/aod-train` 슬래시) — 자율 모드, sequential 호출 없이 진행
- **caveman opt-in 시** — caveman 압축 정신 (~75% 토큰 cut) 과 sequential 심화 추론 정신 모순. caveman 우선
- **이미 plan 파일 존재 시** — `~/.claude/plans/<slug>.md` 가 이미 작성됐으면 sequential 은 sub-step 만, 기존 plan 재구조화 금지
- **사용자가 명시적으로 빠른 답 요청 시** ("간단히 답해줘", "한 줄로")

## 토큰 예산

- **1 호출 당 max 8 step** (Sequential-Thinking 의 기본 step depth — 8 step 초과 시 plan 파일로 외부화)
- **세션 당 max 3 호출** (4번째 호출 시 자동 회피 + 사용자 재질문)
- 호출 후 `.claude/logs/token-budget-track.jsonl` (SessionStart hook `token-budget-track.py`) 에 기록 — 예산 추적

## caveman 동시 활성 시 정책

- **default**: caveman 우선 (sequential 자동 비활성)
- caveman opt-in 발화 (`/caveman` 또는 "caveman mode") 시 sequential routing rule 일시 무력화
- "stop caveman" / "normal mode" 해제 시 sequential 룰 자동 복원
- 동시 활성이 정말 필요할 때 (architecture + 토큰 압박) → 사용자 재질문 ("심화 추론 vs 토큰 압축 중 우선 결정")

## 결합 자산

- **gstack `/plan-eng-review`** — architecture 검토 시 sequential 자연 결합
- **AirLens `/aod-train` / `/policy-sdid-run` / `/dqss-check`** — multi-step ML 학습/분석
- **`plan-first-clarifying.md` interactive tier** — feature/refactor/architecture 진입 시 sequential 자동 후보
- **`caveman` skill** — 반대 방향, 동시 활성 회피

## 검증 / 측정

- **T+7d (~ 2026-05-13)**: 1회 호출 (read-only 질문 — 예: "AirLens 정본 13체계 다음 확장 후보 우선순위") → `.claude/logs/token-budget-track.jsonl` 에 기록 확인
- **T+14d**: invoke 빈도 측정 (`agent-routing.jsonl` grep) — 0회 시 트리거 조건 강화 / 과다 호출 시 토큰 예산 축소
- **T+30d** (`external-plugin-policy.md §5` spot check 와 동일 일정): 활용도 / caveman 충돌 / 토큰 예산 정합 검토

## History

- 2026-05-06 — 초기 룰 작성. `sequential-thinking-activation.md` plan (Wave 2 P1) 적용. settings.local.json `enabledMcpjsonServers` 7번째 등록. default = invoke-only / max 8 step·3 호출/세션 / caveman 우선.
