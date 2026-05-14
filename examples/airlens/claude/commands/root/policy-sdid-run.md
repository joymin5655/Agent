---
description: 정책 영향 SDID 분석 (ATT + 95% CI + permutation p-value + 반사실적 시각화)
args: [country_code] [policy_year]
---

정책 시행 전후의 PM2.5 변화를 SDID(Synthetic Difference-in-Differences)로 추정하고 반사실적 라인 차트를 생성한다.

## 절차

1. 데이터 사전 검증 (`airlens-ml-preflight` 스킬 권고)
2. SDID 분석 실행:
   ```bash
   cd AirLens-models && python -m policy_impact.sdid --country $1 --year $2
   ```
3. 출력:
   - ATT (Average Treatment Effect on Treated) — 정책 효과 추정량
   - 95% CI (신뢰구간)
   - Permutation p-value (placebo test)
   - 반사실적(counterfactual) 시계열
4. 시각화 JSON: `Data/6-policy-analysis/$1/sdid-$2.json`
5. 프론트엔드 정책 페이지가 자동 fetch (Server-Collect 패턴 — `AirLens-web/.claude/rules/core-rules.md` §2)

## Glass-box 요구

- 단일 점추정 금지 — ATT는 신뢰구간 동반 의무 (core-rules §1 Glass-box Output)
- 결과 리포트 필수 항목:
  - 처리국 / 통제군 (synthetic control 가중치 포함)
  - 정책 시행일 + 분석 기간
  - 데이터 출처 (OpenAQ/AirKorea/EEA 등 명시)
  - 통제군 선정 사유 (parallel trends 검증 결과)

## 관련 정본

- `Obsidian-airlens/raw/docs/ml/MODELS_PRD.md` §SDID
- `Obsidian-airlens/raw/docs/ml/MODELS_ARCHITECTURE.md` §정책 영향
- `AirLens-models/models/policy_impact/CLAUDE.md`
