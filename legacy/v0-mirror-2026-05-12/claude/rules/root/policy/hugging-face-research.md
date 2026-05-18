# Hugging Face Research Policy

## 목적

Hugging Face MCP 9 tool 의 안전한 사용 정책 + AirLens ML 도메인 (AOD / SDID / Camera AI / PARAAD / DQSS / TFT / GNN) 의 deep-research 정합. 본 plan = `~/.claude/plans/hf-research-integration.md` (Wave 2 P0).

## 활성 상태

HF MCP 사용 가능 환경에서 agent = `.claude/agents/hf-research-collector.md`. skill 결합 = `.claude/skills/airlens-research/SKILL.md` Step 3 분기.

## 인증 / token

- 로컬 Hugging Face 인증이 있으면 사용한다.
- token 값이나 user-specific auth state는 정책/agent 파일에 기록하지 않는다.
- token rotation / 새 user 추가 시에도 mirror에는 절차만 기록한다.

## 사용 한도 (D2 default = invoke-only)

- **자동 호출 금지** — `airlens-research` skill 진입 시 본 agent 추천만 (사용자 confirm 후 호출)
- **명시 invoke 만**: `/hf-research <topic>` 또는 자연어
- **1 호출 당 max 20 paper search + 5 hub_repo + 5 space search** (Step 2-4 합산)
- **1 topic 당 max 3 호출 / 주** (rate limit, paper 갱신 빈도 낮음)

## arXiv 인용 의무 (CRITICAL)

각 wiki/synthesis/ 페이지의 frontmatter `papers` 배열 + 본문 References 섹션에 다음 필수:

- arXiv ID (정규식 `^\d{4}\.\d{4,5}$` 형식, 예: `2401.12345`)
- URL: `https://arxiv.org/abs/<arxiv-id>`
- title / authors / publish_date / citation_count

arXiv ID 누락 paper → 본 agent 자동 제외 (검증 통과 못함).

## top-N filter (D3 default = top-5 by citation in last 3 years)

filter 기준 (우선순위):

1. **citation_count desc** — 영향력 우선
2. **publish_date >= today - 3 years** — 최신성 (2023-05-06 이후)
3. **abstract relevance** — 토픽 키워드 매치 (manual triage)
4. top-5 선정

예외: AirLens 도메인 핵심 paper (예: ACAG V6, MAIAC AOD, SDID original) 는 publish_date 5+ 년 전이어도 명시 포함.

## paper + repo + space 통합 (D4 default = 모두)

각 top-5 paper 마다:

- **hub_repo_search** — pretrained model 매칭 (예: AOD attention paper → HF model checkpoint)
- **space_search** — demo space 매칭 (사용자 친화 demo)
- 매칭 없을 시 frontmatter `hf_models: []` / `hf_spaces: []` 빈 배열로 명시

paper-only 모드 옵션 (사용자가 `--no-repo --no-space` 추가 시) — 향후 별 plan.

## wiki 경로 표준

`Obsidian-airlens/wiki/synthesis/<topic-slug>-YYYY-MM-DD.md`

- topic-slug = 토픽을 lowercase + dash (예: `aod-pm25-attention`, `sdid-permutation-test`)
- 동일 토픽 < 30일 전 페이지 존재 시 → `-followup-YYYY-MM-DD.md` suffix
- `wiki-auto-index.py` (PostToolUse Write hook) 자동 인덱싱

## 보안 가드

다음 query 패턴 시 자동 차단:

- `secrets/`, `.env*`, AirLens 내부 path
- 사용자 PII (이메일 / 사용자명 in query)
- 경쟁사 unreleased 정보 search

## AirLens ML 7 도메인 (라우팅 트리거)

| 도메인 | 토픽 키워드 |
|---|---|
| AOD | aerosol optical depth, MAIAC, ACAG, satellite PM2.5, AOD-PM25 model |
| SDID | synthetic difference-in-differences, policy causal inference, ATT estimation |
| Camera AI | smartphone camera air quality, image-based PM estimation, mobile AQ |
| PARAAD | personalized air quality recommendation, health-emotion correlation |
| DQSS | data quality scoring, Bayesian confidence, sensor reliability |
| TFT | temporal fusion transformer, time-series air quality forecast |
| GNN | graph neural network, spatial interpolation, station network |

도메인 매치 → `hf-research-collector` agent 호출. 도메인 외 → `research-scientist` 위임.

## 결합 자산

- **`airlens-research` skill** — ML 도메인 라우팅 진입점 (Step 3 분기)
- **`firecrawl-wiki-ingest` skill** — arXiv full-page (Firecrawl) vs HF metadata+abstract (본 agent) 분기
- **`Obsidian-airlens/wiki/synthesis/`** — LLM Wiki 표준 합성 위치
- **HF MCP 9 tool** — paper_search / hub_repo_search / space_search / hub_repo_details / hf_doc_search 핵심

## 검증 / 측정

- **T+7d (~ 2026-05-13)**: 1회 read-only 호출 (`AOD PM2.5`) → top-5 paper 결과 + arXiv ID 추출 검증
- **T+14d**: invoke 빈도 측정 (`agent-routing.jsonl` grep `hf-research-collector`)
- **T+30d**: 활용도 / wiki/synthesis 누적 페이지 수 / 비용 검토

## History

- 2026-05-06 — 초기 룰 작성. `hf-research-integration.md` plan (Wave 2 P0) 적용. default = Robeedau 인증 / invoke-only / top-5 by citation in last 3 years / paper + repo + space 모두.
