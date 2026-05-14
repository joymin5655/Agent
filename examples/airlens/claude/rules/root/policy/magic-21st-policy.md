# Magic-21st Design Variant Policy

## 목적

Magic-21st MCP 4 tool (`21st_magic_component_builder` / `21st_magic_component_inspiration` / `21st_magic_component_refiner` / `logo_search`) 의 안전한 사용 정책. AirLens design system 토큰 자동 주입 + AI Slop 패턴 필터 + 활성 시점 정의. 본 plan = `~/.claude/plans/magic-21st-design-variant.md` (Wave 2 P2).

## 활성 상태

`.claude/settings.local.json` `enabledMcpjsonServers` 에 `magic-21st` 등록됨 (이미 활성). skill = `.claude/skills/design-variant-mockup/SKILL.md` 가 본 룰 enforce.

## D1 활성 시점 (default = 다음 design 라운드)

**현재 = skill + rule 만 구축, invoke 검증 deferral**.

- **회피 시점 (현재)**: design 안정 단계. UI / 컴포넌트 변경 빈도 낮음
- **활성 시점 (다음 design 라운드)**: 새 페이지 / 새 컴포넌트 / 디자인 refresh 라운드 시작 시
- 활성 trigger 발화: "design 라운드 시작" / "새 페이지 X 디자인" / "/design-variants <component>"

T+30d (2026-06-05) 시점에 사용 빈도 측정 → 0회 시 본 룰 / skill stale 검토.

## AirLens design token 자동 주입 (D3 default = apps/web/src/styles + packages/design-tokens 둘 다)

### token source 위치

| 우선순위 | 위치 | 내용 |
|---|---|---|
| 1 | `packages/design-tokens/` (npm workspace) | AQI grade hex + breakpoints (`@airlens/design-tokens`) |
| 2 | `apps/web/src/styles/` (CSS variables) | Tailwind theme.extend / global CSS |
| 3 | `apps/web/tailwind.config.ts` | Tailwind 설정 |

skill workflow Step 1 에서 위 3 위치 차례대로 읽기 + JSON 합성.

### 핵심 토큰 (variant 생성 시 의무 적용)

| 카테고리 | 값 |
|---|---|
| 주 색상 | `#25e2f4` (teal cyan, brand primary) |
| 배경 | `#0a0f1a` (deep navy, dark background) |
| 폰트 (sans) | Inter (UI) |
| 폰트 (serif) | Crimson Pro (editorial) |
| 폰트 (mono) | JetBrains Mono (code) |
| AQI 등급 색상 | `@airlens/design-tokens` 의 5단계 grade hex |

variant 생성 시 raw 색상 / 외부 폰트 사용 금지. `check-hardcoding.py` PreToolUse hook 과 정합.

## AI Slop ban list (D4 default = 4 패턴)

variant 생성 시 다음 패턴 자동 거부:

1. **3-column 대칭 카드 grid** — 단조로운 균등 배치, 시각적 hierarchy 부재
2. **`text-align: center` 과다 사용** — 3개 이상 연속 컴포넌트에서 center 정렬
3. **Emoji icon 남용** — 1 컴포넌트 당 emoji 3개 이상 (Lucide / Heroicons / 자체 SVG 권장)
4. **Generic gradient** — purple/pink / teal/blue 같은 chatgpt-default gradient (AirLens 는 `#25e2f4` 단색 또는 subtle multi-step)

추가 ban 패턴 — 사용자가 본 §"AI Slop ban list" 갱신.

### doctrine cross-link

본 4 ban 패턴은 `Obsidian-airlens/wiki/concepts/design-psychology-doctrine.md` §"Anti-Slop Check" 의 *rejected break* 4 항목과 정합:

- "덜 평범해 보이려고" 추가한 asymmetry → magic-21st 의 generic break 와 동일
- 모든 카드를 같은 radius/shadow/gradient 로 반복하는 template look → 3-column 대칭 grid 와 동일 정신
- decorative hero 가 실제 AQ/product signal 을 가리는 경우 → emoji icon 남용 / generic gradient 와 정합
- contrast / motion / saturation 이 의미 없이 경쟁 → text-align center 과다와 정합

variant 생성 시 본 4 패턴 거부 + doctrine 의 *allowed break* 4 항목 (audience emotion 선명화 / leverage point 강화 / AirLens metaphor 기억 / grid+flow 가 여전히 읽힘) 충족 의무. layout 측면 cross-link = `Obsidian-airlens/wiki/concepts/layout-composition-doctrine.md` §"Negative Space" + §"Grid Doctrine".

## Glass-box AI 원칙 정합 (CRITICAL)

예측 출력 컴포넌트 (CorrelationCard / GlobeOverlay / TodayPanel 등) variant 생성 시 다음 의무 변형 포함:

- **p10-p90 uncertainty 구간 시각화** (line / band / range bar 등)
- **DQSS 품질 배지** (5단계 grade — A/B/C/D/F)
- 단정 표현 회피 (예: "PM2.5 = 35 µg/m³" → "PM2.5 = 35 ± 8 µg/m³ [DQSS: B]")

위 3 요소 누락 variant → skill 자동 재생성.

## 비용 한도

- **1 컴포넌트 당 max 5 variant** — 결정 피로 회피
- **1 라운드 당 max 10 컴포넌트** — 라운드 단위 비용 통제
- **1 세션 당 max 30 variant 호출** — Magic-21st API quota

## 결합 자산

- **`design-shotgun` skill** (글로벌) — variant 비교 board
- **`design-review` skill** (글로벌) — variant 검수 (AI Slop 추가 검증)
- **`frontend-design` skill** (글로벌) — production-grade HTML/CSS 최종화
- **`apps/web/src/styles/`** + **`packages/design-tokens/`** — token source
- **Magic-21st MCP 4 tool**

## 검증 / 측정

- **D1 = 다음 design 라운드** 까지 deferral
- 활성 시 첫 검증: D2 컴포넌트 1건 variant 생성 → 3-5 variant + AirLens token 준수 확인
- AI Slop 필터 작동 확인 (의도적 ban 패턴 prompt → 자동 거부)
- Glass-box 원칙 정합 (예측 컴포넌트 variant 시 p10-p90 + DQSS 누락 거부)

## History

- 2026-05-06 — 초기 룰 작성. `magic-21st-design-variant.md` plan (Wave 2 P2) 적용. default = 다음 design 라운드 / skill+rule 만 구축 / D2 (첫 컴포넌트) deferral. token source 3 위치 / AI Slop 4 패턴 ban / Glass-box 원칙 의무 정합.
