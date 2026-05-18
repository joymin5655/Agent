---
name: airlens-ml
description: AirLens ML research and model-development guidance. Use for AOD to PM2.5 modeling, SDID causal analysis, PINN forecasts, DQSS scoring, GNN interpolation, CameraAI, experiment design, model metrics, or ML pipeline changes.
---

# AirLens ML

Use this skill for AirLens model research, experiment planning, training changes, evaluation, and model-output contracts.

## Core Standards

- Start from a clear hypothesis, a controlled baseline, and one primary metric.
- Change one variable at a time unless the task explicitly calls for ablation or architecture exploration.
- Compare against existing metrics and artifacts before claiming improvement.
- Report RMSE, R2, MAE, and uncertainty where relevant; include confidence intervals or statistical tests when results drive decisions.
- Explain performance versus complexity tradeoffs before adopting a more complex method.
- Cite papers, DOIs, or arXiv IDs when proposing new modeling techniques.

## AirLens Engines

| Engine | Model | Inputs | Output | Location |
| --- | --- | --- | --- | --- |
| AOD to PM2.5 | XGBoost-GTWR | MAIAC AOD, ERA5 met, terrain | Surface PM2.5 at 1km | `models/aod/` |
| SDID | Synthetic DID | policy panel data | causal policy impact | `models/sdid/` |
| PINN | physics-informed NN | met, emissions, PM2.5 history | 12h PM2.5 forecast | `models/pinn/` |
| DQSS | quality scorer | station metadata, observation stats | data quality score | `models/dqss/` |
| GNN | graph neural net | station network, spatial features | spatial interpolation | `models/gnn/` |
| CameraAI | DINOv2 plus visibility physics | sky photo | PM2.5 estimate | `models/camera/` |

## Pipeline Shape

`raw/` data -> `pipeline/` ETL -> `data/features/` -> training -> `artifacts/` -> `api/` and `main.py` -> frontend JSON.

Keep prediction outputs glass-box friendly: include model version, dataset version, provenance, p10/p50/p90 or equivalent uncertainty bounds, and quality metadata when available.

## Common Commands

Run commands from `AirLens-models/` unless the repo indicates otherwise.

```bash
python train.py --model aod --cv spatio_temporal
python main.py --mode predict --output ../../data/frontend/predictions/
pytest tests/ -v -m "not integration"
```

## Research Workflow

1. Inspect current code, data contracts, and metrics for the target engine.
2. State the hypothesis and expected failure mode.
3. Define baseline, dataset split, controlled variable, and acceptance threshold.
4. Run the smallest useful experiment and log parameters, seed, data version, and outputs.
5. Decide based on held-out metrics, not a single fold or training score.
6. Update tests, docs, or frontend contracts if behavior or output shape changes.

## Model-Specific Guidance

- AOD to PM2.5: prefer spatiotemporal validation; avoid leakage across time or nearby stations.
- SDID: check pre-treatment fit, donor pool assumptions, placebo tests, and policy timing.
- PINN: keep physics residuals interpretable; compare against simple temporal baselines.
- DQSS: ensure score changes are explainable and stable under missing or noisy observations.
- GNN: validate graph construction and hold out spatial regions, not only random points.
- CameraAI: require GPU for serious training; use CPU only for smoke tests or non-vision paths.

## Guardrails

- Do not modify `artifacts/` without preserving the previous artifact or confirming the artifact is disposable.
- Do not claim model improvement without a baseline and held-out evaluation.
- Do not tune hyperparameters without recording the search space and selection criterion.
- Do not use live external services in tests unless the task explicitly requires integration verification.
- Do not remove uncertainty outputs from prediction contracts.
