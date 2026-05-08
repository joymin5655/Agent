# Firecrawl Wiki Ingest Policy

## 목적

Firecrawl MCP 12 tool (firecrawl_search / scrape / crawl / extract / map / browser_*) 의 안전한 사용 정책. 화이트리스트 / rate limit / 라이선스 / wiki 경로 표준 정의. 본 plan = `~/.claude/plans/firecrawl-wiki-ingest.md` (Wave 2 P1).

## 활성 상태

`.claude/settings.local.json` `enabledMcpjsonServers` 에 `firecrawl` 등록됨 (이미 활성). skill = `.claude/skills/firecrawl-wiki-ingest/SKILL.md` 가 본 룰을 enforce.

## 화이트리스트 도메인 (12)

invoke 가능 도메인. 외 도메인 시도 시 skill workflow Step 3 에서 차단.

### 위성 / 대기질 공공 데이터 (5)

- `nasa.gov` — NASA 본 site
- `earthdata.nasa.gov` — Earth Science 데이터 (MAIAC AOD source)
- `airkorea.or.kr` — 한국 환경부 대기질
- `who.int` — WHO Air Quality
- `epa.gov` — US EPA 대기질

### 라이브러리 docs (9)

- `react.dev` — React 19
- `supabase.com` — Supabase docs (apps/web 핵심 dependency)
- `vitejs.dev` — Vite 6
- `tailwindcss.com` — Tailwind CSS
- `typescriptlang.org` — TypeScript
- `langchain.com` — LangChain / LangGraph
- `microsoft.github.io` — AutoGen (Microsoft)
- `docs.crewai.com` — CrewAI
- `docs.all-hands.dev` — OpenHands

### AI 에이전트 및 프레임워크 (GitHub Docs)

- `python.langchain.com` — LangChain Python SDK
- `js.langchain.com` — LangChain JS SDK
- `microsoft.github.io/autogen` — AutoGen
- `docs.crewai.com` — CrewAI
- `docs.all-hands.dev` — OpenHands (formerly OpenDevin)
- `docs.auto-gpt.ai` — AutoGPT
- `docs.cline.bot` — Cline (formerly Claude Dev)
- `docs.aider.chat` — Aider
- `docs.superpowers.ai` — Superpowers (Claude Code plugin)
- `docs.gstack.dev` — gstack (Garry Tan)

### 학술 / 논문 (2)

- `arxiv.org` — arXiv (HF paper_search 와 분기 — Firecrawl 은 full-page crawl, HF 는 metadata/abstract)
- `scholar.google.com` — Google Scholar (메타 검색만, full-text 회피)

## 추가 도메인 절차

새 도메인 추가 시:

1. 사용자가 `.claude/rules/firecrawl-policy.md` 본 §"화이트리스트 도메인" 에 도메인 추가 (별 plan 불요)
2. 라이선스 확인 필수 — CC / MIT / Apache / public domain / "Site Terms allow scraping" 중 하나
3. robots.txt 자동 검사 (skill workflow Step 1) — Disallow 시 차단

## Rate limit

- **1 도메인 당 max 50 page / 일** — 무분별 crawl 차단
- **1 plan 당 max 200 page** — plan 단위 비용 통제
- **1 호출 당 max 1 세션** — 동시 crawl 차단 (R4 mutex 정신 정합)

초과 시 skill 자동 차단 + 사용자 재질문.

## 라이선스 / 출처 표기 (D4 = frontmatter + 본문 인용)

각 wiki/imports/<domain>/<slug>-YYYY-MM-DD.md 페이지에 다음 frontmatter 필수:

```yaml
---
source: <full URL>
domain: <whitelist domain>
license: <CC-BY-4.0 / MIT / public-domain / site-terms>
fetched: <YYYY-MM-DD>
crawled_pages: <int>
---
```

본문 첫 줄에 출처 인용:

> 출처: [<title>](<URL>) — fetched <date>, license <license>

원본 인용 ≥ 50자 시 quote block (`> ...`) 사용. 출처 footer 추가 권장.

## 보안 가드 (CRITICAL)

다음 패턴 query / URL 에 포함 시 skill 자동 차단:

- `secrets/**`, `.env*`, `SUPABASE_SERVICE_ROLE_KEY`, `WAQI_TOKEN`, `OPENAQ_API_KEY`, `CLOUDFLARE_API_TOKEN`
- AirLens 내부 path (`/Volumes/WD_BLACK SN770M 2TB/AirLens-platform/secrets/...`)
- 사용자 PII (`joymin5655@gmail.com` 같은 이메일 — query 에 포함 금지)

## wiki 경로 표준

`Obsidian-airlens/wiki/imports/<domain-slug>/<page-slug>-YYYY-MM-DD.md`

- domain-slug = 도메인의 dot 을 dash 로 (예: `react-dev`, `earthdata-nasa-gov`)
- page-slug = URL path 마지막 세그먼트 + dash + 변환

`wiki-auto-index.py` (PostToolUse Write hook) 가 신규 페이지 자동 인덱싱.

## D2 PreToolUse hook 결정

**default = (a) skill 본문에서만 검증** — settings.local.json 미변경, 사용자 직접 우회 가능 (수동 firecrawl_search 호출). hard 차단 hook (옵션 b) 은 invoke 빈도 데이터 측정 후 별 plan.

T+7d 후 invoke 빈도 측정 → 0회 또는 화이트리스트 외 시도 ≥ 1건 시 hard hook 별 plan trigger.

## 결합 자산

- **`airlens-research` skill** — wiki 합성 패턴 동일 적용
- **`Obsidian-airlens/wiki/imports/`** — 신규 디렉터리 (외부 출처 격리)
- **`scripts/hooks/wiki-auto-index.py`** — 자동 인덱싱
- **`public-repo.md`** — 보안 정책 베이스
- **HF MCP `paper_search`** — arXiv 분기 (Firecrawl full-page vs HF metadata)

## 검증 / 측정

- **T+7d (~ 2026-05-13)**: 1 화이트리스트 도메인 1 page ingest 검증 (예: `https://react.dev/learn/thinking-in-react`)
- **T+14d**: 화이트리스트 외 시도 시 차단 동작 확인
- **T+30d**: invoke 빈도 + 비용 측정. hard hook 별 plan trigger 여부 결정.

## History

- 2026-05-06 — 초기 룰 작성. `firecrawl-wiki-ingest.md` plan (Wave 2 P1) 적용. 화이트리스트 12 도메인 (위성 5 + docs 5 + 학술 2). default = soft 검증 (skill 본문, hook 없음).
