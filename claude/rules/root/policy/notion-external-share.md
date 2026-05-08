# Notion External Share Policy

## 목적

정본 9+1+3 PRD 의 외부 공유 (외부 협업자 / 학술 협업자 / 투자자 view) 정책. Notion MCP 14 tool 사용 시 어느 PRD 가 외부 가능 / internal-only 인지 정의. one-way sync (AirLens → Notion) 만 허용 — 정본 보호. 본 plan = `~/.claude/plans/notion-prd-sync.md` (Wave 2 P2).

## 활성 상태

Notion MCP 등록됨. skill = `.claude/skills/notion-prd-sync/SKILL.md` 가 본 룰 enforce. **Notion workspace ID 는 사용자가 추후 sync 시 제공** (D2 deferral).

## 외부 공유 화이트리스트 (D1 결정)

### 외부 가능 (4 PRD)

| PRD | 정본 path | 외부 공유 대상 |
|---|---|---|
| Platform PRD | `Obsidian-airlens/raw/docs/platform/PLATFORM_PRD.md` | 외부 협업자 / 투자자 |
| Web PRD | `Obsidian-airlens/raw/docs/web/WEB_PRD.md` | 외부 협업자 (apps/web 영역) |
| App PRD | `Obsidian-airlens/raw/docs/app/APP_PRD.md` | 외부 협업자 (apps/app 영역) |
| Models PRD | `Obsidian-airlens/raw/docs/ml/MODELS_PRD.md` | 학술 협업자 (ML 도메인) |

### Internal-only (외부 차단)

- Platform Architecture / Web Architecture / App Architecture / Models Architecture (4 architecture)
- DB Schema (`Obsidian-airlens/raw/docs/db/DATABASE_SCHEMA.md`)
- Operations / Agent Harness (`Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md`)
- 보조 (revenuecat-integration / sky-journal / wiki/synthesis/)

화이트리스트 외 PRD sync 시도 시 skill 자동 차단.

## sync 방향 (D3 = one-way)

**AirLens → Notion 만 허용**. bidirectional 금지 — 정본 supersede 마커 / wiki-curator 룰 보호.

- Notion 쪽 수정사항 → 매 sync 에 overwrite (외부 협업자에게 사전 고지 필수)
- 외부 피드백은 Notion comment → AirLens 가 수동으로 정본 반영 (manual loop)

## sync 주기 (D4 = 수동 invoke)

**default = 수동 invoke 만**: `/notion-prd-sync <prd>` 또는 자연어 ("Platform PRD Notion 에 sync").

- cron / PostCommit hook 자동 sync 미지원 (옵션 b/c) — 별 plan
- PR 머지 시 자동 sync (옵션 c) — GitHub Actions 통합 별 plan

## 보안 가드 (CRITICAL)

화이트리스트 PRD 라도 sync 전 diff scan 필수:

- secret 키워드 (`SUPABASE_SERVICE_ROLE_KEY` / `WAQI_TOKEN` / `OPENAQ_API_KEY` / `CLOUDFLARE_API_TOKEN` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`) 매치 시 차단
- 사용자 PII (`redacted@example.com` 등) 매치 시 차단
- 미공개 결정 마커 (`[INTERNAL]`, `[CONFIDENTIAL]`, `[NDA]`) 매치 시 차단

## API rate limit

- **1 PRD 당 max 1 sync / 시간** — 무분별 호출 방지
- **1 세션 당 max 5 sync** — 비용 통제

## Notion workspace 위치 (D2 deferral)

본 룰 작성 시점 미결정. 사용자가 `/notion-prd-sync` 첫 invoke 시 다음 정보 제공 필요:

- Notion workspace ID (또는 root parent page ID)
- 권한 — Notion MCP 가 write 권한 가진 workspace 인지

skill workflow Step 0 에서 사용자 확인.

## D5 Pro dashboard 분리

**default = 본 plan 외 별 plan**: 정본 PRD sync 와 별개. Notion 별도 workspace 운영 시 `~/.claude/plans/notion-pro-dashboard.md` 별 plan trigger.

## 결합 자산

- **정본 9+1+3 PRD** (4 외부 가능 / 9 internal-only)
- **`wiki-curator` 패턴** — supersede 마커 보호 (`external-plugin-policy.md` C2 와 동일 정신)
- **`public-repo.md`** — secret 노출 차단 베이스
- **Notion MCP `notion-search` / `notion-create-pages` / `notion-update-page`** — 핵심

## 검증 / 측정

- **D2 결정 후**: 1 화이트리스트 PRD 1건 sync test
- **diff scan**: 의도적 secret 포함 PRD 시도 → 차단 동작 확인
- **rate limit**: 1시간 내 동일 PRD 2회 sync 시도 → 차단 동작 확인

## History

- 2026-05-06 — 초기 룰 작성. `notion-prd-sync.md` plan (Wave 2 P2) 적용. 외부 4 PRD 화이트리스트 (Platform / Web / App / Models). default = one-way / 수동 invoke / Notion workspace ID deferral.
