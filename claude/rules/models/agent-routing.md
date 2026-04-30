# Agent Routing & Self-Improvement (AirLens-models)

AirLens-web의 `agent-routing.md` 패턴 차용. ML 도메인 특화 보정.

> ML 특화 3부서 (`registry-tier1.json` 정의): `ml-research`, `ml-quality`, `ml-security`.

---

## 1. 도메인별 에이전트 매핑

| 키워드 | subagent_type | scope |
|--------|---------------|-------|
| AOD, MAIAC, satellite, GTWR, p10/p50/p90 | `aod-specialist` | AirLens-models |
| SDID, policy, causal, ATT, synthetic control | `sdid-specialist` | AirLens-models |
| Camera AI, DINOv2, CORN, ONNX export, sky segmentation | `camera-ai-specialist` | AirLens-models |
| DQSS, reliability, anomaly, Beta 분포, 5-component | `dqss-specialist` | AirLens-models |
| TFT, forecasting, temporal fusion | `ml-researcher` (글로벌, fallback) | global |
| GNN, spatial interpolation, k-NN graph | `ml-researcher` (글로벌, fallback) | global |
| 데이터 파이프라인, feature engineering | `data-engineer` (AirLens-web scope) | AirLens-web |
| 보안, ML security, path traversal | `ml-security-reviewer` | AirLens-models |
| 테스트, pytest, 데이터셋 회귀 | `ml-test-engineer` | AirLens-models |

> **중첩 처리** (specialist 책임 경계):
> - `aod-specialist` vs GNN — AOD 모델 자체의 공간 보정은 aod-specialist (XGBoost + GTWR), 일반 공간 보간(k-NN graph)은 글로벌 `ml-researcher` fallback.
> - `dqss-specialist` vs `ml-test-engineer` — 데이터 품질은 dqss, 코드 회귀 테스트는 ml-test-engineer.

## 2. 자동 검증 (PostToolUse 훅 권고)

- 학습 코드 변경 (`models/{aod_correction,policy_impact,camera_ai,dqss}/`) → `ml-test-engineer` 자동 호출
- 보안 영역 (API endpoint, 파일 I/O, env 처리) → `ml-security-reviewer` 자동 호출
- DQSS 점수 4.0 미만 데이터로 학습 시도 → 사용자 경고 (core-rules §3 Data Integrity)

> 본 자동 검증은 권고 사항. 실제 PostToolUse 훅 활성화는 별도 settings 작업 (Wave 4 범위 외).

---

## 3. PGE 자체 평가 (ML 특화 10점)

ML 학습/추론 작업 완료 후 자체 평가:

```
## 자체 평가
- Reproducibility (시드 + YAML): [0-2]
- Glass-box (p10/p50/p90 또는 DQSS): [0-2]
- Data Integrity (DQSS ≥ 4.0 입력): [0-2]
- 코드 품질 (ruff + mypy): [0-2]
- 문서 (work_log.md + 메트릭 보고): [0-2]
- Total: [X]/10
```

**7.0 미만 시 자동 개선**: 부족 차원 식별 → 해당 specialist 호출 → 재평가.

---

## 4. 학습 기록

작업 중 발견한 패턴/실수는 `AirLens-models/logs/work_log.md` 에 기록:

```markdown
## YYYY-MM-DD HH:MM — model_name
- Hyperparams: lr=0.001, epochs=100, seed=42 (configs/X.yaml git sha: abc1234)
- Metrics: R²=0.64, RMSE=8.2, MAE=5.1
- 학습 시간: 12m 30s (mps)
- 발견: [무엇을]
- 원인: [왜]
- 해결: [어떻게]
- 교훈: [다음 적용 패턴]
```

---

## 5. 서킷 브레이커 (ML 컨텍스트)

| 실패 횟수 | 대응 |
|-----------|------|
| 1회 (학습 발산) | 하이퍼파라미터 조정 후 재시도 (lr, batch size) |
| 2회 | 데이터 검증 (`/dqss-check`) + 다른 region/period 시도 |
| 3회 | 사용자 에스컬레이션 — 모델 아키텍처 또는 데이터 근본 문제 가능 |

---

## 관련 정본

- `AirLens-models/.claude/rules/core-rules.md` — 5원칙 (Reproducibility/Glass-box/Data Integrity/Resource Awareness/Versioning)
- `AirLens-models/.claude/agents/registry-tier1.json` — ML 특화 3부서 매핑
- 글로벌 `architect`, `code-reviewer`, `security-reviewer` — 범용 에이전트 fallback
