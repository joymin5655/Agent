# Memory Discipline — 기록 확인 우선

## 목적

메모리 인덱스 (MEMORY.md 1줄 요약) 만 보고 추측 금지. 관련 키워드 매치 시 본문 file (`memory/<topic>.md`) 의무 read. 사용자가 이미 결정/기록한 사항을 "효력 없음" / "가짜" / "추측" 으로 단정하는 패턴 영구 회피.

발의 사례 = 2026-05-12 사용자 발화 "auto compact가 왜 안되는거야? ... 기록 확인안해? 이것도 규칙으로 추가해". `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` env var 가 실제 작동하는데, 메모리 인덱스만 보고 "가짜 변수일 가능성" 으로 잘못 진단. 본문에는 명확히 "변경 후 재시작 필요. 현 session 영향 0" 적혀있었음.

## 규칙

### R1. 키워드 매치 → 본문 read 의무

사용자 질문에 다음 키워드 매치 시 관련 memory file 본문 read **before** 응답:

| 카테고리 | 키워드 |
|---|---|
| 설정 / config | "왜 안돼", "작동 안 함", "안 되네", "왜 fail", "에러", "왜 trigger 안돼" |
| 결정 사항 | "이전에 결정", "기록", "지난번에", "예전에 했잖아", "메모리에 있는" |
| 토큰 / 비용 | "auto compact", "token budget", "context 사용", "메모리 사용" |
| 정책 / 룰 | "규칙", "정책", "5 가드", "R4 mutex", "정본" |
| skill / agent | "plug-in", "skill 충돌", "agent 라우팅", "동명 skill" |

→ `Read /Users/joymin/.claude/projects/-Volumes-WD-BLACK-SN770M-2TB-AirLens-platform/memory/<topic>.md` 의무.

### R2. 인덱스 1줄 ≠ SOT

`MEMORY.md` 의 1줄 요약은 *어떤 file 에 정보가 있는지* 만 알려주는 인덱스. 본문 = SOT.

- 인덱스: 토픽 식별만
- 본문: **Why / How to apply / 관련 자원** 3 섹션 = 진짜 의사결정 근거
- 추측보다 본문 우선 — **본문에 없는 정보만** 새로 추정 가능

### R3. 추측 신호 = 본문 read 의무

다음 표현이 응답에 들어가려 할 때 **반드시** 본문 read:

- "...일 가능성"
- "...추측"
- "...아닐 수도"
- "Anthropic 공식 변수가 아님" / "가짜"
- "정확히 모르지만"

→ 본문에 답이 적혀 있을 확률 매우 높음. read 후 사실 기반 응답.

### R4. 사용자 결정 영역은 가짜 단정 금지

`feedback_*` / `project_*` memory 는 사용자가 이미 결정/검증한 사항. AI 가 "효력 없음" / "잘못된 설정" 으로 단정 금지. 의심 시:

- 본문 read 후 *조건* 확인 (예: "재시작 필요" / "T+7d 측정 후" / "별 plan 트리거")
- 조건 미충족 시 = 미발화 *상태* 인 것이지 *효력 없음* 이 아님
- 사용자에게 "재시작이 필요한 상황" 등 정확한 진단 보고

### R5. 인덱스 stale 가능성

memory 인덱스 자체는 1줄 요약 정합 갱신이 느릴 수 있음 (사용자 결정 변경 시). 인덱스와 본문 충돌 시 **본문 우선**. 충돌 발견 시 인덱스 정합 갱신 사용자에게 보고.

## 회피 anti-pattern

다음 anti-pattern 은 본 룰이 enforce 하는 *금지* 행동:

- ❌ **인덱스 1줄 본 후 즉시 추측 응답** — 사례 = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 가 가짜일 가능성" (2026-05-12)
- ❌ **본문 read 단계 생략** — "메모리 본 적 있어요" 만 cite, 본문 검증 X
- ❌ **사용자 결정 무효화** — 사용자가 이미 결정한 설정을 "잘못된 추측" 으로 단정
- ❌ **MEMORY.md 의 lossy 요약을 SOT 취급** — "WARNING: MEMORY.md is 201 lines and 33.6KB. Only part of it was loaded" 신호 무시

## 실 작동 패턴

```
사용자: "왜 X 안 돼?"
   ↓
AI: 1) MEMORY.md grep 키워드 → memory/X.md 식별
    2) Read memory/X.md 본문 → Why + How to apply + 관련 자원 모두 흡수
    3) 본문의 *조건* 검증 (재시작? T+N? trigger 조건?)
    4) 조건 미충족 = 미발화 상태 보고
    5) 본문에 답 없음 = 그 때만 추측 (명시: "본문 미기록 영역 — 추측")
```

## 결합 자산

- `MEMORY.md` — 인덱스 (1줄 요약)
- `memory/<topic>.md` — 본문 SOT
- `.claude/rules/OVERVIEW.md` — 본 룰 1줄 요약 등록
- `~/.claude/CLAUDE.md` §auto memory — 글로벌 메모리 시스템 정의
- `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md` §메모리 시스템 — AirLens 정본

## History

- 2026-05-12 — 초기 룰 작성. 발의 trigger = 사용자 발화 "auto compact가 왜 안되는거야? 기록 확인안해? 이것도 규칙으로 추가해". 인덱스 1줄 본 후 "변수가 가짜일 가능성" 추측 → 본문에 "재시작 필요" 명시 → 잘못된 진단. R1-R5 5 규칙 + 4 anti-pattern + 실 작동 패턴.
