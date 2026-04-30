---
description: AirLens deep-research를 정형 skill로 실행. 토픽 1줄 입력 → wiki/{synthesis|comparisons|...}/<topic>-YYYY-MM-DD.md 생성 + index/log 갱신.
args: [topic] [flags]
---

`airlens-research` skill을 호출해 다음 토픽을 deep-research 한다: $ARGUMENTS

## 사용 예

```
/airlens-research "PM2.5 센서-위성 fusion 최신 연구 2025-2026"
/airlens-research "Camera AI 라이센싱 모델 경쟁사 비교" --type=comparison
/airlens-research "DQSS Bayesian 신뢰도 베이스라인" --interactive
```

## 기본값

- `--type=auto` — entity/concept/source/comparison/synthesis 자동 분류
- `--scope=auto` — platform/web/app/ml/db/competitive/policy/ux 자동 매칭
- `--interactive=false` — 자율 실행 (영상 원칙: research는 autopilot)

## 산출물

`Obsidian-airlens/wiki/{category}/<topic>-YYYY-MM-DD.md` (또는 entity/concept은 날짜 suffix 없이)

- frontmatter 필수 필드 7개
- 본문 7섹션 (Context / Scope / Assumptions / Findings / Cross-references / Open Questions / Next Actions)
- Sources ≥ 5, Cross-refs `[[...]]` ≥ 3
- `index.md` + `log.md` 자동 갱신

## Pre-flight

skill 시작 시 자동으로:
1. `Obsidian-airlens/index.md` 선조회 (Rule 0)
2. 중복 페이지 검사 (Rule 5)
3. AirLens 도메인 컨텍스트 주입 (정본 9+1 매칭)

## 품질 게이트

산출 페이지가 다음 모두 만족해야 "완료":
- frontmatter 7필드 채움
- 7섹션 모두 비어있지 않음
- Sources ≥ 5 + URL 클릭 가능
- Cross-refs ≥ 3
- index/log 갱신 포함

## 관련 정본

- `.claude/skills/airlens-research/SKILL.md` — skill 본문
- `Obsidian-airlens/CLAUDE.md` — LLM Wiki schema
- `Obsidian-airlens/wiki/synthesis/_template.md` — 표준 템플릿
- `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md` §Research workflow
