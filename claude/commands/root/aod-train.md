---
description: AOD→PM2.5 XGBoost 학습 + 평가 (region별, R²/RMSE/MAE 보고)
args: [region] [epochs]
---

AOD 모델을 region별로 학습하고 메트릭을 보고한다. AirLens-models §Glass-box ML Harness 4대 출력 규율 준수.

## Pre-flight (필수 통과)

1. **`airlens-ml-preflight` 스킬 호출** — 데이터 가용성 / GPU·MPS / 디스크 / 의존성 / secrets 점검
2. 정적 검증:
   ```bash
   cd AirLens-models && ruff check models/aod_correction/
   ```
3. 모듈 단위 테스트:
   ```bash
   pytest -k aod -v
   ```

## 학습

```bash
cd AirLens-models && python train.py --model aod --region $1 --epochs ${2:-100}
```

학습 종료 후 자동 출력:
- 아티팩트: `Data/4-ml-pipeline/artifacts/aod_${1}_$(date +%Y%m%d).pkl`
- 메트릭 (목표): R² ≥ 0.6, RMSE ≤ 10 µg/m³, MAE 별도 보고

## Post-train

1. ONNX export (선택, 브라우저 추론 필요 시):
   ```bash
   python -m models.aod_correction.export_onnx --model-path Data/4-ml-pipeline/artifacts/aod_${1}_$(date +%Y%m%d).pkl
   ```
2. 예측 산출:
   ```bash
   python main.py --mode predict --output ../../Data/5-frontend-cache/predictions/
   ```
3. 결과 보고 (R² / RMSE / MAE / 학습시간 / 하이퍼파라미터)를 PR 본문 또는 `AirLens-models/logs/work_log.md` 에 기록 — Reproducibility 의무

## Glass-box 의무

- 단일 점추정 X — 항상 p10/p50/p90 양자회귀
- 학습 시 random seed 고정 (`configs/seeds.yaml`)
- 하이퍼파라미터는 `configs/model_params.yaml` (코드 인라인 금지)

## 관련 정본

- `Obsidian-airlens/raw/docs/ml/MODELS_PRD.md` §AOD
- `Obsidian-airlens/raw/docs/ml/MODELS_ARCHITECTURE.md` §AOD pipeline
- `AirLens-models/models/aod_correction/CLAUDE.md`
