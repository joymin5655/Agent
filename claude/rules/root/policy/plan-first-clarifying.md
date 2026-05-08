# Plan-first + Clarifying-Q Rule

## 목적

영상("AI PM Claude Code Setup") 인사이트 적용 — 자율 작업(research)은 가정 + 문서화, 인터랙티브 작업(feature/refactor/architecture)은 가정 금지 + clarifying-Q.

## 활성화 단계

| 시점 | 단계 | 상태 |
|------|------|------|
| 2026-04-29 | **M1: dry-run** | ✅ 활성 — 분류만 jsonl 로그, AI 동작 변경 X |
| 2026-05-06 (~1주) | **M2: 측정** | 분류 정확도 측정 (사용자 수동 확인 5건 샘플) |
| 2026-05-13 (~2주) | **M3: 활성화** | interactive tier에서 clarifying-Q 강제 활성 |
| 2026-05-20 (~3주) | **M4: 튜닝** | false-positive 분석 → 키워드 룰 조정 |

현재 **M1 dry-run** 단계 — 이 룰은 hook이 분류만 기록, AI 응답 동작은 **변경되지 않음**.

## 3-tier 분류

| Tier | 예시 | M3 활성 후 동작 |
|---|---|---|
| **Trivial** | 오타 수정, 1줄 변경, 변수 rename | 즉시 실행 (plan 생략) |
| **Interactive** | feature 추가, refactor, architecture, PRD 변경 | plan-first + clarifying-Q 필수 (가정 금지) |
| **Autonomous** | research, deep-analysis, log-summary | 자율 실행, 가정 → 문서화 |

## 분류 키워드 (M1 룰셋)

### Trivial 키워드
- `rename`, `오타`, `typo`, `fix typo`
- "변수명을 바꿔/변경", "한 줄", "1-line"
- 변경 범위 명시 ("파일 1개", "X.ts 만")

### Interactive 키워드
- 작업 동사: `추가`, `구현`, `만들어`, `신규`, `refactor`, `리팩토링`, `architecture`, `설계`, `수정`, `변경`
- 도메인: `결제`, `billing`, `RLS`, `Edge Function`, `Globe`, `ML 학습`
- 정본/제품: `PRD`, `요구사항`, `정본`

### Autonomous 키워드
- `research`, `조사`, `분석`, `deep-research`, `비교`, `comparison`, `summarize`, `요약`
- 슬래시 커맨드: `/airlens-research`, `/dqss-check`, `/policy-sdid-run`, `/aod-train` — **강제 autonomous**

### 모호 → Interactive (안전 fallback)

키워드 매칭 0개 → `interactive`로 분류. 안전 우선 (가정 진행 방지).

## Clarifying-Q 4종 패턴 (M3 활성 후)

interactive tier 진입 시 `AskUserQuestion` 자동 생성. 4종 중 **모호한 항목만** 묻기 (1~2개 권장):

1. **Scope**: "어디까지 변경?" (파일/모듈 단위)
2. **우선순위**: "기능 vs 성능 vs 호환성 중 무엇이 우선?"
3. **외부 의존**: "기존 X와 통합? 신규?"
4. **검증**: "어떤 테스트로 완료 확인?"

문맥이 풍부하면 1개만, 매우 모호하면 최대 4개.

## 우회 (인터럽트 금지 케이스)

다음 케이스는 분류기와 무관하게 **autonomous로 강제**:

- `/airlens-research`, `/dqss-check`, `/policy-sdid-run`, `/aod-train` 등 슬래시 커맨드
- `--no-clarify` 플래그 (사용자 명시 의도)
- `airlens-research` skill 내부 호출 (skill 자체가 자율 모드)

## Dry-run 로그 (M1)

위치: `.claude/logs/plan-tier-classifications.jsonl` (gitignored)

각 줄 (1 record):
```json
{"ts": "2026-04-29T10:11:00Z", "tier": "interactive", "matched": ["pattern1"], "prompt_first_120": "...", "prompt_len": 240}
```

M2 측정 시 분석:
- tier 분포 (trivial/interactive/autonomous 비율)
- false-positive 추정 (사용자가 "이건 trivial이었는데 interactive로 분류" 류 사례)

## 관련 자원

- `scripts/hooks/classify-prompt.py` — 분류 훅 (M1 dry-run 모드)
- `.claude/logs/plan-tier-classifications.jsonl` — dry-run 로그
- `.claude/skills/airlens-research/SKILL.md` — 자율 모드 분기 패턴 (이 룰의 영감)
- `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md` §10 — 정본 등록
- `~/.claude/plans/airlens-plan-first-clarifying-q.md` — 본 plan
