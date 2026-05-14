# Humanizer Agent 도입 정책

## 목적

`blader/humanizer` (MIT, v2.5.1, 2026-04-01 commit) 의 Wikipedia "Signs of AI writing" 패턴 카탈로그를 AirLens `.claude/agents/copy-humanizer.md` 1종으로 import. 영어 외부 공개 텍스트 한정 invoke. 본 룰은 도입 범위·5 가드 영역·라이선스·운영 한계를 정한다. sister 룰: `.claude/rules/policy/matt-pocock-skills.md` (동일 패턴).

## 활성 상태

`.claude/agents/copy-humanizer.md` 등록됨 (2026-05-07). plan = `~/.claude/plans/blader-humanizer-enchanted-coral.md` 영역 A.

## 도입 범위

### 도입 (1 agent)

| Agent | 카테고리 | 도입 사유 |
|---|---|---|
| `copy-humanizer` | productivity (영어 카피 + 고급 교정) | notion-prd-sync 화이트리스트 4 PRD + landing/News·Blog 페이지 영어 카피의 AI tell 패턴 검출/수정. **추가 도입 (2026-05-08):** 6대 고급 프롬프트 기술(보이스 클로닝, 첫 줄 훅, 이탈 예측 등)을 통한 능동적 에디터 역할 추가. |

### 제외

humanizer 본 SKILL.md 의 Voice Calibration 모드 / Personality and Soul 보강 모드는 본 라운드 범위 밖. 검출-수정만 제공 — 사용자 voice 학습은 향후 별 plan.

### 작용 가능 영역 (4)

| # | path | 비고 |
|---|---|---|
| 1 | `apps/web/src/components/landing/**` | Hero / CTA / 설명 (영어 부분만) |
| 2 | `apps/web/src/pages/{News,Blog,NewsDetail,PolicyProof}.tsx` | Tier 3 paper/ink 영어 메타·설명 |
| 3 | `Obsidian-airlens/raw/docs/{platform,web,app,ml}/*_PRD.md` | notion-prd-sync 화이트리스트 4종 |
| 4 | `README.md` / `CHANGELOG.md` | 외부 노출 영어 마크다운 |

### 절대 금지 영역 (5 가드, CRITICAL)

1. `apps/web/public/locales/**/*.json` — i18n JSON 자동생성, gitleaks allowlist 보호
2. p10 / p50 / p90 uncertainty + DQSS 배지 텍스트 (Glass-box 단정 회피)
3. 한국어 사용자 노출 텍스트 (영어 패턴 룰셋 — 한국어 적용 시 grammatically 깨짐)
4. 코드 주석 / 변수명 / 로거 메시지 (카피톤 아님)
5. 보안 경고 / destructive 확인 / multi-step 순서 (CLAUDE.md Glass-box 5 가드)

5 가드는 `matt-pocock-skills.md` §"caveman 적용 한계" 와 동일 정신.

## 라이선스

MIT. 원본 SKILL.md 본문은 in-place import 회피 (27KB 너무 큼) — 패턴 카탈로그만 한국어 워크플로우 본문 + 영어 reference URL 로 흡수.

```
Source: https://github.com/blader/humanizer
Commit: TBD (2026-04-01 last commit, v2.5.1)
License: MIT
Adopted: 2026-05-07
Wikipedia ref: https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing
```

원본 SKILL.md 본문 수정 시 본 파일 §History 누적 기록.

## 한국어 / 정본 정합 강제

- agent 본문 (`.claude/agents/copy-humanizer.md`) 은 **한국어** 워크플로우 + 영어 패턴 enum 혼합
- description frontmatter 마지막 1줄: "응답은 한국어"
- 정본 매핑: 본 룰 + `notion-prd-sync.md` (4 PRD 화이트리스트) + `matt-pocock-skills.md` (5 가드)
- 작용 시 사용자 confirm 메시지는 한국어 — 카피 자체는 영어 텍스트 수정

## 네이밍 충돌 회피

`copy-humanizer` (AirLens agent) ↔ `humanizer` (원본 skill name):
- 원본 = `~/.claude/skills/humanizer/SKILL.md` 가능 (글로벌 — 사용자 별도 install 시)
- AirLens 프로젝트 agent = `copy-humanizer` (prefix 로 분리)
- 충돌 없음 — 글로벌 humanizer 미설치 시 AirLens copy-humanizer 만 노출

CLAUDE.md `§Skill routing` 1줄 매핑 추가:
```
- 영어 외부 공개 텍스트 AI tell 검출·수정 → invoke `copy-humanizer` 에이전트 (영어 only, 명시적 invoke)
```

## 운영 한계 (CRITICAL)

다음 영역은 항상 **풀 문장 유지** (CLAUDE.md Glass-box 원칙 우선):

1. **ML/예측 출력의 불확실성** (p10-p90, DQSS 배지) — 단정 금지. humanizer 가 hedging 제거 패턴 (excessive hedging 제거) 적용 시 단정으로 변환 위험. 자동 회피.
2. **보안 경고** (secret 접근, RLS 위반) — humanizer 가 filler 제거 시 경고 강도 약화 위험. 자동 회피.
3. **Destructive 확인** (production migration, force-push, DROP TABLE) — humanizer 의 "concise 우선" 정신이 안전 경고 단축 위험. 자동 회피.
4. **Multi-step 순서** (rebase·deploy 절차) — humanizer 가 rule-of-three 제거 시 step 1-2-3 합치기 위험. 자동 회피.
5. **사용자 재질문** 시 — 한 번 물어본 걸 다시 물으면 humanizer 일시 중단.

기본 비활성, 명시 invoke (`@copy-humanizer <path>` 또는 Task subagent) 만 활성. PR / commit / Stop hook 자동 발화 금지.

## 운영 — 1개월 spot check

- T+7d (2026-05-14): 1회 dry-run invoke (영어 PRD 단락 1개) → 검출 결과 한국어 보고 자연스러운지 spot check
- T+14d (2026-05-21): 작용 가능 영역 4 모두 1회씩 invoke → 카테고리별 검출 분포 측정
- T+30d (2026-06-06): invoke 빈도 측정 (`agent-routing.jsonl` grep `copy-humanizer`)
  - 0회 → 트리거 조건 강화 (description frontmatter 의 invoke 패턴 명시 강화) 또는 deprecation 검토
  - 빈번 (≥ 5회) → Voice Calibration 모드 별 plan trigger
  - 5 가드 영역 침범 감지 ≥ 1건 → agent description frontmatter 의 금지 영역 enum 강화

## 결합 자산

- `.claude/rules/policy/matt-pocock-skills.md` — 5 가드 정신 (sister 룰)
- `.claude/rules/policy/notion-external-share.md` — 외부 공개 4 PRD 화이트리스트 (작용 영역 3)
- `gitleaks.toml [allowlist]` — i18n JSON 자동생성 보호 (작용 금지 영역 1)
- `~/.claude/plans/blader-humanizer-enchanted-coral.md` — 본 plan
- 외부: https://github.com/blader/humanizer + https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing

## History

- 2026-05-07 — 초기 룰 작성. plan = `~/.claude/plans/blader-humanizer-enchanted-coral.md` 영역 A. 사용자 결정 = 영어 only / 명시 invoke 만 / 5 가드 영역 자동 보호. T+30d 결정 누적.
