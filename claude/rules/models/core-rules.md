# Core Rules (AirLens-models)

ML 워크스페이스 정본 룰. 학습/추론/평가 작업 시 자동 로드.

> Wave 1에서 `AirLens-models/CLAUDE.md` §Glass-box ML Harness가 추가되었고, 본 파일이 상세 정본이다.
> 정본 PRD/Architecture: `Obsidian-airlens/raw/docs/ml/{MODELS_PRD,MODELS_ARCHITECTURE}.md`.

---

## 1. ML 시스템 5원칙 (ENFORCED)

학습/추론 작업 시작 전, 코드 리뷰 시 검증한다.

1. **Reproducibility** — `random_seed` 고정 + 하이퍼파라미터를 `configs/*.yaml`에 외부화. 코드 인라인 상수로 학습 금지.
2. **Glass-box Output** — 모든 모델 출력에 불확실성 동반 (p10/p50/p90 분위 회귀 또는 DQSS 점수). 단일 점추정 API 금지.
3. **Data Integrity** — 학습 입력은 DQSS ≥ 4.0 만 허용 (`/dqss-check` 슬래시 커맨드 결과 기준). Stale 데이터(7일+)는 경고.
4. **Resource Awareness** — 학습 시작 전 `airlens-ml-preflight` 스킬로 GPU/MPS·디스크·secrets 사전 검증.
5. **Versioning** — 모델 아티팩트 명명: `{model}_{region}_{YYYYMMDD}.pkl` 또는 `{model}_{date}_{git_sha[:7]}.pkl`.

---

## 2. No Hardcoding (ML 컨텍스트)

| 항목 | 정본 위치 |
|------|-----------|
| 하이퍼파라미터 | `configs/model_params.yaml` |
| 데이터 경로 | `os.environ` 또는 YAML 설정 (인라인 절대경로 금지) |
| 학습 시드 | `configs/seeds.yaml` 또는 `model_params.yaml` 의 `seed:` 키 |
| 데이터 파이프라인 설정 | `configs/data_pipeline.yaml` |

위반: 모델 파일에 `lr=0.001`, `epochs=100`, `seed=42` 등의 하드코딩.

---

## 3. 에러 컨텍스트 의무

빈 핸들러 `try: except: pass` **금지**. 예외 발생 시 컨텍스트와 함께 로그.

```python
# ✗ 금지
try:
    result = train_model(data)
except Exception:
    pass

# ✓ 권장
try:
    result = train_model(data)
except Exception as e:
    logger.exception(
        "Training failed",
        extra={
            "model": model_name,
            "data_shape": data.shape,
            "hyperparams": cfg.dict(),
            "gpu_memory": torch.cuda.memory_summary() if torch.cuda.is_available() else None,
        },
    )
    raise
```

---

## 4. 보안

- API 키/시크릿 로깅 절대 금지 (사용자 메모리 `feedback_secrets_inspection.md` 준수)
- Path traversal 방지: 출력 경로는 `_validate_output_path()` 사용
- `ENV=production` 환경변수 설정 시 `API_KEY` 인증 강제
- ML 보안 정책 정본: `.claude/rules/ml-security.md` (이미 존재) 참조

---

## 5. Pre-flight 의무

ML 학습/추론 명령 시작 직전 `airlens-ml-preflight` 스킬 호출 의무 (5종 검증: 데이터/GPU·MPS/디스크/의존성/secrets). secrets 누락은 hard-fail.

호출 시점:
- `train.py` 직전
- `python -m models.X` 학습 직전
- `/aod-train`, `/dqss-check`, `/policy-sdid-run` 슬래시 커맨드 직전 (이미 명시됨)

---

## 6. 학습 결과 보고 (Glass-box ML Harness)

학습 PR/커밋 메시지 또는 `AirLens-models/logs/work_log.md` 에 다음 항목 의무 기록:

- **R²** (목표: ≥ 0.6 — AOD/PM2.5 모델 기준)
- **RMSE** (목표: ≤ 10 µg/m³)
- **MAE** (참고)
- **학습 시간** + **사용 디바이스** (mps/cuda/cpu)
- **하이퍼파라미터** (또는 `configs/*.yaml` git sha)

---

## 7. Anti-Hallucination Anchor (외부 드래프트 차단)

외부 AI 도구/드래프트가 자주 환각하는 명령은 **본 워크스페이스에 존재하지 않음**. 적용 금지:

| 환각 명령 | 실제 대체 |
|----------|-----------|
| `python main.py --test-run` | `pytest -k <module> -v` |
| `python scripts/validate-data.py` | `/dqss-check` 슬래시 커맨드 또는 `pytest tests/test_data_quality.py` |

`main.py` 의 실제 `--mode` 값: `api` / `pipeline` / `predict` / `dqss` / `evaluate` / `report` / `agent`. 모델별 학습은 `train.py --model <name>` 사용 (`AirLens-models/CLAUDE.md` 참조).

학습 sanity-check 표준: `pytest -k <module>` + (필요 시) `python main.py --mode predict --output /tmp/sanity/`.

---

## 관련 정본

- `AirLens-models/CLAUDE.md` (95 lines, Wave 1 보강) — 9 모델 인벤토리 + 빠른 명령
- `AirLens-models/.claude/rules/agent-routing.md` — 에이전트 라우팅 + PGE 평가
- `AirLens-models/.claude/rules/ml-security.md` — 보안 정책 (path traversal, ENV 검증)
- `Obsidian-airlens/raw/docs/ml/MODELS_PRD.md` / `MODELS_ARCHITECTURE.md` — 정본
