---
description: DQSS 5-컴포넌트 데이터 품질 검증 + Bayesian 신뢰구간 + 리포트 생성
args: [data_path]
---

DQSS (Data Quality Score) 검증을 실행하고 5점수(completeness/consistency/timeliness/accuracy/uniqueness)를 보고한다.

## 워크플로

1. 입력 데이터 경로 확인 (기본: `Data/3-raw-sources/air_quality/`)
2. 규칙 기반 DQSS 실행:
   ```bash
   cd AirLens-models && python -m dqss.rule_based_dqss --input ${1:-../../Data/3-raw-sources/air_quality}
   ```
3. Bayesian 신뢰성 동시 산출:
   ```bash
   python -m dqss.bayesian_reliability --input ${1:-../../Data/3-raw-sources/air_quality}
   ```
4. 출력 점수: completeness / consistency / timeliness / accuracy / uniqueness (각 0~1)
5. p10/p50/p90 분위 + Bayesian Beta 95% CI 함께 리포트
6. 결과를 `Data/7-reports/dqss-$(date +%Y%m%d-%H%M%S).json` 에 저장

## 게이팅 (정본 기준)

- 종합 DQSS < 4.0 시 학습 진행 차단 권고 (`AirLens-models/.claude/rules/core-rules.md` §3 Data Integrity 참조)
- DQSS 4.0~6.0: 경고만 (사용자 판단)
- DQSS ≥ 6.0: 정상 학습 가능

## 관련 정본

- `Obsidian-airlens/raw/docs/ml/MODELS_ARCHITECTURE.md` §DQSS
- `AirLens-models/models/dqss/CLAUDE.md`
- `AirLens-models/CLAUDE.md` §Glass-box ML Harness (Wave 1 추가)
