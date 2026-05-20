# Security Guards — 5 가드 영역 정본 (SOT)

## 목적

AirLens 자동화 시스템 (skill / hook / supervisor / wrap) 가 영구 회피해야 할 5 가드 영역의 *단일 정본 (single source of truth)*. 다른 모든 정책 / skill / hook 은 본 § 를 cross-link — 정의 중복 금지.

본 plan = `~/.claude/plans/purring-snuggling-sphinx.md` Wave 1.

## 5 가드 영역 (자동화 영원히 회피 — Glass-box 정합)

### 1. Production Migration

- **매핑 path**: `supabase/migrations/*.sql`
- **매핑 명령**: `supabase db push`, `supabase migration up`, `supabase migration apply`, `psql` 직접 호출
- **매핑 MCP**: `mcp__supabase__apply_migration`, `mcp__supabase__execute_sql`
- **차단 hook (Layer 3)**: `scripts/hooks/r4-mutex-check.sh` (resource = `production-db`) + `scripts/hooks/pre-tool-guard.sh` (DROP/TRUNCATE TABLE). **Decision = `ask` (2026-05-18 wobbly-percolating-panda)** — `deny` 자동 차단에서 사용자 명시 확인 후 통과로 완화. 자동화 영원히 회피 정신 유지 (자동 통과 X).
- **사용자 명시 패턴**: 명시 migration name + "맞아" / "진행해" — generic ("옵션1", "전부 알아서", "한번에 진행") 거부
- **근거**: `feedback_hook_specific_naming.md`, `feedback_production_safety_gates.md`

### 2. Secret 변경

- **매핑 path**: `secrets/*`, `.env`, `.env.local`, `.env.production`, `.env.*`
- **매핑 키워드**: `SUPABASE_SERVICE_ROLE_KEY`, `WAQI_TOKEN`, `OPENAQ_API_KEY`, `CLOUDFLARE_API_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `STRIPE_SECRET_KEY`, `sk-{20+}`, `eyJ{32+}`
- **차단 layer**:
  - Layer 1 = gitleaks (pre-commit, `gitleaks.toml`)
  - Layer 2 = CI gitleaks (`.github/workflows/secret-scan.yml`)
  - Layer 3 = `scripts/hooks/pre-tool-guard.sh` (Bash cat/source secrets) + `scripts/hooks/context-mode-guard.sh` (sandbox bypass) + `scripts/hooks/secret-content-scan.py` (Write/Edit/MCP content scan, 2026-05-14)
  - Layer 4 = `.claude/skills/wrap/SKILL.md` Step 1 (3중 검증)
  - 참고: `check-hardcoding.py` 는 UI 하드코딩 차단 (색상/gradient) — secret 차단 아님 (코드 품질 hook)
- **우회 path 자동 차단**: `cat`/`tail`/`head`/`awk`/`sed` (pre-tool-guard.sh) + `source` / `.` (pre-tool-guard.sh) + Context Mode `ctx_execute*` (context-mode-guard.sh) + Python `open('secrets/' \| '.env*')` / Node `fs.readFileSync('secrets/' \| '.env*')` / 하드코딩 KEY value / `sk-{40+}` / JWT 리터럴 (secret-content-scan.py Write\|Edit\|MultiEdit) + MCP `mcp__supabase__{execute_sql,apply_migration,deploy_edge_function}` query/name/files 안 secret 패턴 (secret-content-scan.py MCP matcher)
- **우회 path 미차단 (Layer 5 정책만 — 후속 우회 패턴 발견 시 본 항목 갱신)**: (Layer 3 강화 2026-05-14 완료)
- **근거**: `feedback_secrets_inspection.md`, `feedback_secrets_python_open_pattern.md`

### 3. Edge Function Deploy

- **매핑 path**: `supabase/functions/*/index.ts` 변경 + deploy 명령
- **매핑 명령**: `supabase functions deploy`
- **매핑 MCP**: `mcp__supabase__deploy_edge_function`
- **차단 hook (Layer 3)**: `scripts/hooks/r4-mutex-check.sh` (resource = `edge-function-deploy`). **Decision = `ask` (2026-05-18 wobbly-percolating-panda)** — `deny` 자동 차단에서 사용자 명시 확인 후 통과로 완화. R5 PR serialize 가 enforce 우선.
- **placeholder content 차단**: 사용자 결정 정책 (`feedback_supabase_deploy_placeholder_risk.md` — placeholder content "see /tmp/...") accept 위험)

### 4. 결제 라이브 (Stripe / Polar / IAP / RevenueCat)

- **매핑 영역**: 결제 관련 코드 변경 (`apps/web/src/lib/billing/`, `apps/app/src/billing/`, Stripe/Polar Edge Fn)
- **매핑 키워드**: `STRIPE_SECRET_KEY`, `POLAR_API_KEY`, `RC_PUBLIC_KEY`, `webhookSecret`
- **차단 layer**: 사용자 명시 강제 (자동 hook 부재 — 사용자 결정 영역)
- **skill 차단**: wrap-skill Step 2 + supervise 6 안전장치 #2

### 5. ML / 예측 출력 Uncertainty

- **매핑 영역**: ML 출력 컴포넌트 (`CorrelationCard`, `GlobeOverlay`, `TodayPanel`, `RoiSection`, `ForecastBand`, etc.)
- **매핑 의무**: p10-p90 uncertainty 구간 + DQSS 배지 (5단계 grade A/B/C/D/F)
- **차단 layer**: `humanizer-agent.md` (영어 외부 공개 텍스트), `magic-21st-policy.md` (Glass-box 의무)
- **auto rewrite 금지**: copy-humanizer agent 의 rule-of-three / em-dash 패턴이 단정 표현 강제 X (Glass-box 우선)
- **근거**: CLAUDE.md §"4대 원칙 §3 Glass-box Output"

## Cross-link (다른 정책에서 본 § 참조)

- `wrap-skill.md` §"5 가드 영역" → 본 § (`claude/commit-pr-automation` 머지 후 적용)
- `supervisor-delegation.md` §"5 가드 영역" → 본 §
- `supervisor-tune.md` §"5 가드 영역 회피" → 본 §
- `matt-pocock-skills.md` `/caveman` 5 가드 — *부분 overlap* (Destructive 확인 = 본 §1 + force-push + DROP TABLE; brevity 예외 scope 다름, 별 § 유지)
- `multi-agent-worktree.md` §R14 6 안전장치 #2 → 본 §

## 차단 매핑 표 (가드 → hook + skill + policy)

| 가드 | PreToolUse hook | Decision | Skill 검증 | Policy SOT |
|---|---|---|---|---|
| 1 production migration | `r4-mutex-check.sh` (production-db) + `pre-tool-guard.sh` (DROP/TRUNCATE) | **ask** (2026-05-18) | wrap Step 2 / supervise #2 | 본 §1 |
| 2 secret 변경 | `pre-tool-guard.sh` + `context-mode-guard.sh` + `secret-content-scan.py` (Write/Edit/MCP) + gitleaks (commit-time) | **deny** 유지 | wrap Step 1 / supervise #1 | 본 §2 |
| 3 Edge Fn deploy | `r4-mutex-check.sh` (edge-function-deploy) | **ask** (2026-05-18) | wrap Step 2 / supervise #3 | 본 §3 |
| 4 결제 | (사용자 명시 — 자동 hook 부재) | — | wrap Step 2 / supervise #4 | 본 §4 |
| 5 ML uncertainty | (humanizer agent ban — 자동 hook 부재) | — | (Glass-box 의무) | 본 §5 |

**Decision 분기 (2026-05-18 wobbly-percolating-panda)**: §2 Secret 변경 = `deny` 유지 (자동 통과 X). §1 production migration / §3 Edge Fn deploy = `deny → ask` 완화 (사용자 명시 확인 시 통과). §4 결제 / §5 ML uncertainty = 자동 hook 부재 (사용자 결정 영역). Karpathy §careful 정신 잔존 — Automation 우회 X.

## 위반 학습 jsonl (Wave 4 — 신규)

`.claude/logs/security-violations.jsonl` — gitignored. 각 차단 1 record:

```json
{"ts":"2026-05-07T...","guard":2,"hook":"pre-tool-guard.sh","reason":"secrets/ 직접 접근 차단","session_id":"claude-main-...","decision":"deny"}
```

T+30d 분석 → 우회 시도 패턴 / false-positive 식별. 자동 룰 갱신 X (supervisor-tune 회피 패턴 정합).

## 5 층 보안 stack (요약)

| Layer | 위치 | 책임 |
|---|---|---|
| 1 — gitleaks | `gitleaks.toml` + `scripts/git-hooks/pre-commit` | 100+ secret 패턴 차단, allowlist 기반 |
| 2 — CI | `.github/workflows/secret-scan.yml` | gitleaks Action 재실행 |
| 3 — Hook PreToolUse | 9 hook (R7.1 stack) | check-hardcoding / secret-content-scan / pre-tool-guard / r4-mutex / r4-file-mutex / context-mode-guard / gsd-cwd-guard / supervisor / tdd-guard. **Decision 분기 (2026-05-18)**: §2 Secret = `deny` / §1·§3 R4 자원 = `ask` |
| 4 — Skill Step 1 | `.claude/skills/wrap/SKILL.md` Step 1 | 3중 검증 (gitleaks + 화이트리스트 + secret grep) |
| 5 — Policy 5 가드 | 본 file (security-guards.md) | 자동화 영원히 회피 |

상세 = `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md §21 Security Hardening` (Wave 2 신규).

## 결합 자산

- `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md §21` — Wave 2 신규 §
- `gitleaks.toml` — Layer 1+2 정본
- `scripts/hooks/r4-mutex-check.sh` — production-db / edge-function-deploy / production-deploy mutex
- `scripts/hooks/pre-tool-guard.sh` — Bash cat/source/echo secrets 차단
- `scripts/hooks/secret-content-scan.py` — Write/Edit/MCP content secret 패턴 차단 (Layer 3, 2026-05-14)
- `scripts/hooks/check-hardcoding.py` — PreToolUse Write|Edit 하드코딩 차단
- `scripts/hooks/context-mode-guard.sh` — Context Mode sandbox bypass 차단
- `.claude/skills/wrap/SKILL.md` Step 1 — gitleaks + 화이트리스트 + secret grep (gitignored in-place)
- `.claude/skills/supervise/SKILL.md` 6 안전장치 — 5 가드 #2 자동 abort (gitignored in-place)
- `~/.claude/plans/purring-snuggling-sphinx.md` — 본 plan

### Sister SOT (enforce 영역 분리 — 2026-05-14)

`security-guards.md` 의 5 가드 = *"자동화 영원히 회피"* (사용자 결정 강제). 신규 enforce 영역은 별 SOT 로 분리 (drift 회피):

- `.claude/policy-archive/rate-limit-policy.md` — Edge Function rate-limit middleware enforce (tatum_hq §17-18 흡수, 14/33 미적용 인벤토리, hook Phase 1 warning-only)
- `.claude/policy-archive/auth-boundary.md` — Auth Boundary (tatum_hq §20, Round C placeholder)
- `.claude/policy-archive/idor-response-policy.md` — IDOR 403/404 응답 코드 (tatum_hq §21, Round C placeholder)
- `.claude/policy-archive/rls-policy.md` — RLS 정책 SOT (62 테이블 / 139 정책 / 26 service_role bypass / 네이밍 표준 / 5-tier role 분류, Round D1 신규)
- `.claude/policy-archive/data-source-integrity.md` — 외부 source 변조 차단 SOT (Round D2 신규). 4 Edge Fn fetch + 8 batch ingest / 4-layer 신뢰성 stack §4 / Integrity 4 패턴 (TLS / ETag / SHA256 / Zod schema). 변조 감지 시 DQSS F + p10-p90 NaN.
- `.claude/policy-archive/dqss-uncertainty-policy.md` — Glass-box §5 자동화 SOT (Round D3 신규). 19 ML 출력 컴포넌트 audit + `dqss-uncertainty-check.py` PostToolUse advisory hook (Phase 1 warning-only). 자동화 영원히 회피 정신 유지 — block X / rewrite X.
- `.claude/policy-archive/model-artifact-integrity.md` — ML model artifact 변조 차단 SOT (Round D4 신규). Supabase Storage `app-models` bucket (NOT R2) / 1 model (sky-seg ONNX) / Layer 1 manifest sha256 ✅ baseline / Layer 2 client verify ⚠️ 미확인 / Layer 3 Ed25519 signature ❌ 부재. 3-Layer attestation 모델 + Build → Publish chain attestation 4-step + Glass-box 정합 (변조 감지 → DQSS F + p10-p90 NaN). D2 §Pattern 3 concrete.
- `scripts/hooks/rate-limit-check.py` — rate-limit enforce hook (Phase 1)
- `scripts/hooks/dqss-uncertainty-check.py` — Glass-box uncertainty advisory hook (Phase 1 warning-only, Round D3)
- `scripts/hooks/ai-rules-exposure-check.py` — AI tool config exposure (`.cursor*` 등) 차단 hook
- `~/.claude/plans/worktrees-codex-korean-social-feed-doc-noble-duckling.md` — Round A+B plan

## History

- 2026-05-07 — 초기 SOT 작성. 기존 분산 정의 (supervisor-delegation.md / supervisor-tune.md) → 본 § cross-link 만으로 정정. wrap-skill.md cross-ref 는 `claude/commit-pr-automation` 머지 후 후속 정합. matt-pocock-skills.md `/caveman` 5 가드는 brevity 예외 scope 라 별 § 유지.
- 2026-05-14 — Layer 3 우회 path 차단 보강. `scripts/hooks/secret-content-scan.py` (~140 LOC) 신규 wire-up. PreToolUse `Write|Edit|MultiEdit` matcher (check-hardcoding.py 다음 #2 위치) + `mcp__supabase__{execute_sql,apply_migration,deploy_edge_function}` matcher (fk-type-precheck.py 직전). 7 secret 패턴: Python `open('secrets/')` / `open('.env*')` / Node `fs.readFileSync('secrets/')` / `fs.readFileSync('.env*')` / 하드코딩 KEY value (`SUPABASE_SERVICE_ROLE_KEY` 등 9 키워드 + 20+ chars) / `sk-{40+}` 리터럴 / JWT `eyJ...eyJ...sig` 리터럴. EXEMPT 화이트리스트: `.env.example`, `gitleaks.toml`, `Obsidian-airlens/`, test/fixture, `.claude/rules/`, `.claude/skills/`, `/plans/`. reproduce 11/11 PASS (positive 4 + allow 4 + MCP 3). gitleaks.toml allowlist 본 test fixture path 추가. §2 "우회 path 미차단" 영역 → "Layer 3 강화 완료" 정정. plan = `~/.claude/plans/secrets-bypass-hook-block.md`.
- 2026-05-14 — P1 followup. `pre-tool-guard.sh` L52 정규식 확장 — Bash 5 명령군 (`cat\|echo\|tee\|cp\|mv`) → **19 명령군** (`cat\|tac\|nl\|head\|tail\|less\|more\|awk\|sed\|grep\|egrep\|fgrep\|hexdump\|xxd\|od\|strings\|dd\|fold\|rev\|tee\|cp\|mv\|ln`). 직전 PR #315 후 점검에서 `head/tail/grep/awk/sed secrets/x` 등 미차단 우회 path 발견. `scripts/hooks/tests/pre-tool-guard-test.sh` (~70 LOC) reproduce 15/15 PASS (existing 3 + P1 9 + negative 3). plan = `~/.claude/plans/secrets-bypass-p1-followup.md`. settings.local.json `Read(.env*)` deny 추가는 메인 트리 (gitignored) 사용자 직접 적용.
- 2026-05-14 — P2 followup. `secret-content-scan.py` 의 `extract_chunks()` 확장 — `walk_strings()` recursive helper + MCP write/external tool 분기 추가 (firecrawl 5 / context-mode 3 / WebFetch / Notion 3 / Google Drive 2 / stitch 2 = **16 tool matchers**). secret 패턴 `sk-` / JWT 의 quote 요구 제거 (`['"]` → `\b` word-boundary) — URL query string 안 secret 도 catch. reproduce 16/16 PASS (P1 11 + P2 5: firecrawl_scrape url sk- / ctx_fetch_and_index url JWT / WebFetch url sk- / Notion nested sk- / 무관 url allow). settings.local.json 6 신규 matcher block 추가 (gitignored, 메인 트리 직접 적용). plan = `~/.claude/plans/secrets-bypass-mcp-url-content.md`.
- 2026-05-14 — P3 followup. `pre-tool-guard.sh` stdin redirect 차단 신규 if block — `<\s*[^>]*secrets/` 정규식 (`python3 < secrets/x` / `node < secrets/db.env` / `tr a b < secrets/key` 차단, `echo > out.txt` 같은 output redirect 는 회피). `settings.local.json permissions.deny` 에 **LS / Glob 10 entry 추가** (`LS(secrets/**)` / `Glob(secrets/**)` / `Glob(**/.env*)` 5 변형) — metadata 인벤토리 차단. reproduce 19/19 PASS (existing 12 + P3 3 + negative 4). Base64 / hex encoded secret 은 사용자 의도 영역 — 정책만 명시 (skip). plan = `~/.claude/plans/secrets-bypass-p3-followup.md`. 3 PR 누적 (#315 Layer 3 / #316 P1 Bash / 본 P3) — `secret-content-scan.py` + `pre-tool-guard.sh` Layer 3 보강 종결.
- 2026-05-14 — P4 followup. `pre-tool-guard.sh` L52 정규식 확장 — 8 명령군 추가 (`rg` / `ag` / `bat` / `md5sum` / `shasum` / `sha256sum` / `sha512sum` / `wc` / `diff` / `cmp`). modern grep/cat alternatives + hash full-read + content-compare 명령 차단. 별 if block 신규 — `find\s+.*secrets/.*-exec` (`find secrets/ -exec cat {} \;` / `find . -path '*secrets/*' -exec md5sum` 차단). `settings.local.json permissions.deny` 에 **Grep 11 entry 추가** (`Grep(secrets/**)` / `Grep(.env*)` 5 변형 / `Grep(**/.env*)` 5 변형) — Read deny 우회 path 차단. reproduce 34/34 PASS (existing 27 + P4-A 3 + P4-B 7 + P4-C 2 + negative P4 3 + existing negative 4). vim/vi/nano/emacs (editor 의도) + stat/file/du (metadata 인벤토리) + eval/base64 + 5 가드 §1/§3 hook 자동 차단 = skip 정책 (사용자 결정 영역). plan = `~/.claude/plans/secrets-bypass-p4-followup.md`. 4 PR 누적 종결 (#315 Layer 3 / #316 P1 Bash / #319 P3 stdin+LS/Glob / 본 P4 modern+hash+find+Grep).
- 2026-05-14 — P5 followup. `pre-tool-guard.sh` L52 정규식 확장 — **17 명령군 추가** (압축 12: `gunzip` / `bunzip2` / `bzip2` / `bzcat` / `xz` / `xzcat` / `unxz` / `lzma` / `lz4cat` / `tar` / `unzip` / `7z` + crypto 3: `gpg` / `openssl` / `age` + 원격 1: `rsync`). 별 if block 신규 2 — **A1 curl/wget @secrets/ exfiltration** (`(curl|wget)\s+.*(--data-binary\s+@|--post-file=|-d\s+@|-F\s+\S*=@).*secrets/` — content 원격 전송 차단) + **D xargs 인디렉션** (`secrets/.*\|.*xargs|xargs\s+.*\bsecrets/` — find -exec 와 동등). reproduce 56/56 PASS (existing 27 P1+P3+P4 + A1 4 + A2 2 / scp 회귀 + B 압축 6 + C 암호 4 + D xargs 2 + negative 11). 변수 인터폴레이션 (`cat $S/x`) / 경로 인코딩 (`cat sec""rets/x`) = FP HIGH skip 정책 (Layer 5 정책만 — Layer 1 gitleaks 의존). plan = `~/.claude/plans/secrets-bypass-p5-followup.md`. 5 PR 누적 종결 (#315 Layer 3 / #316 P1 Bash / #317 P2 MCP / #319 P3 stdin+LS/Glob / #320 P4 modern+hash+find+Grep / 본 P5 exfil+압축+crypto+xargs).
- 2026-05-14 — P6 followup (5-PR sequence post-audit patch). P5 머지 후 audit 결과 3 HIGH 잔존 path 식별 (R1.1 shared-tree audit). **L52 regex +1** (`zip` — archive 가 secrets/ 포함, P5 압축군은 *해제* 만 catch). **A1 if block 확장** (`-T\s+|--upload-file\s+` 추가 — `curl -T secrets/x` / `curl --upload-file secrets/x` 누락 path 보강). reproduce 61/61 PASS (P5 56 + P6-A1 2 + P6-zip 1 + P6 negative 2) + secret-content-scan 16/16 회귀. Skip 정책 (옵션 C — Layer 5 정책 영역만): `pv` / `socat` / `logger` / `compgen` — AirLens dev 환경 빈도 ~0 추정. 옵션 B 선택 (HIGH 3 만) → regex 인플레이션 최소 (44→45 명령군). plan = `~/.claude/plans/secrets-bypass-p6-followup.md`. **6 PR 누적 종결** (#315 Layer 3 / #316 P1 Bash / #317 P2 MCP / #319 P3 stdin+LS/Glob / #320 P4 modern+hash+find+Grep / #323 P5 exfil+압축+crypto+xargs / 본 P6 curl -T + zip).
- 2026-05-14 — Sister SOT 분리 추가 — tatum_hq Instagram 5 anti-pattern (§17-21) 흡수. 본 SOT 의 5 가드 "회피" 정신 유지 + enforce 영역은 별 SOT 3 file (`rate-limit-policy.md` / `auth-boundary.md` placeholder / `idor-response-policy.md` placeholder). 5→8 가드 확장 회피 — drift 위험 ↑. PreToolUse stack 13 → 15 (rate-limit-check.py / ai-rules-exposure-check.py). 9 reproduce PASS. plan = `~/.claude/plans/worktrees-codex-korean-social-feed-doc-noble-duckling.md`.
- 2026-05-14 — Round D1 sister SOT 추가 — `.claude/policy-archive/rls-policy.md` 신규 (auth-boundary.md 3 layer §3 data 보호). audit = 62 ENABLE RLS / 139 CREATE POLICY / 26 service_role bypass Edge Fn (33 중 79%) / 네이밍 4 drift 패턴 (legacy 보존). 표준 `<table>_<role>_<action>` + 5-tier role 분류 (public / authenticated / owner / service_role / admin). enforce hook `rls-policy-check.py` 는 Round E deferral (T+14d). plan = `~/.claude/plans/rls-policy-sot.md` (parent `worktrees-codex-korean-social-feed-doc-noble-duckling.md` Round D1).
- 2026-05-14 — Round D2 sister SOT 추가 — `.claude/policy-archive/data-source-integrity.md` 신규 (4-layer 신뢰성 stack §4 외부 source 변조 차단). audit = 4 Edge Fn fetch (firms-proxy / weather-grid-proxy / data-collector / global-grid-snapshot) + 8 batch ingest source (open_meteo / earthdata / cams / maiac / era5 / sentinel5p / world_bank / global_grid) / checksum + schema validation **0 endpoint** 부재 발견. Integrity 4 패턴 (TLS / ETag / SHA256 manifest / Zod schema validation) 권장 매트릭스. Glass-box 정합 — 변조 감지 시 DQSS F + p10-p90 NaN 의무. enforce hook `source-integrity-check.py` 는 Round E deferral (T+14d). 발의 = tatum_hq §18 *확장* (무한 스크롤 → 외부 source 변조 대칭). plan = `~/.claude/plans/data-source-integrity-sot.md` (parent `worktrees-codex-korean-social-feed-doc-noble-duckling.md` Round D2).
- 2026-05-14 — Round D4 sister SOT 추가 — `.claude/policy-archive/model-artifact-integrity.md` 신규 (ML model artifact 변조 차단). parent plan §"Round D" D4 표현 "Cloudflare R2" stale 정정 → 실제 storage = **Supabase Storage `app-models` bucket** (migration 00302). audit = 1 model (sky-seg ONNX) / Layer 1 manifest sha256 ✅ baseline (versions[].sha256 + size_bytes 포함) / Layer 2 client-side verify ⚠️ docstring 가정 (apps/app loader 코드 audit 미확인) / Layer 3 manifest signature ❌ 부재 (위조 가능). 3-Layer attestation 모델 (Layer 1 ✅ / Layer 2 T+30d / Layer 3 T+90d Ed25519 + public key pin) + Build → Publish chain attestation 4-step (training → upload → manifest write → deploy 각 hash 검증) + multi-model 확장 후보 5 (Camera AI / AOD / TFT / GNN / Causal). Glass-box 정합 — 변조 감지 시 DQSS F + p10-p90 NaN (D2/D3 sister 정합). enforce hook (`apps/app` ONNX loader audit / CI manifest verify / `model-signature-check.py`) 모두 Round E deferral (T+14d-T+90d). 5 가드 침범 0 — §2 secret (Ed25519 private key, T+90d) + §3 Edge Fn deploy (`sky-seg-model-distribute` 변경) 인접. plan = `~/.claude/plans/model-artifact-integrity-sot.md` (parent `worktrees-codex-korean-social-feed-doc-noble-duckling.md` Round D4).
- 2026-05-14 — Round D3 sister SOT 추가 — `.claude/policy-archive/dqss-uncertainty-policy.md` + `scripts/hooks/dqss-uncertainty-check.py` (~110 LOC) 신규. **§5 자동화 첫 시도** — block X / rewrite X 정신 유지, PostToolUse advisory only. audit = 19 ML 출력 컴포넌트 (Forecast / Correlation / Globe / Today / Insights) + 정합 사용 예시 = `ForecastCard.tsx` (`pm25_p10` / `pm25_p50` / `pm25_p90` / `dqss: 'A'|...|'F'`). hook: 4 path scope + 5 EXEMPT (test / fixture / wireframe / admin) + 3 Glass-box 신호 (p10 / p90 / dqss case-insensitive). 8 reproduce PASS. Phase 2 (PreToolUse + `{"decision":"ask"}`) Round E deferral (T+14d 2026-05-28). settings.local.json PostToolUse 4→5 stack 은 gitignored — 사용자 직접 메인 트리 적용. plan = `~/.claude/plans/dqss-uncertainty-enforce.md` (parent `worktrees-codex-korean-social-feed-doc-noble-duckling.md` Round D3).
- 2026-05-18 — **block → ask 완화** (`wobbly-percolating-panda.md`). 사용자 발화 "시크릿값을 제외하고 완화". §2 Secret 변경 전체 Layer 1-5 유지 + §1 production migration / §3 Edge Fn deploy R4 자원 영역만 `deny → ask` 완화. 3 hook 변경: `r4-mutex-check.sh` line 140 (3 자원 모두 ask) / `context-mode-guard.sh` GUARD 분기 (GUARD 1/3 = ask, GUARD 2 = deny) + log_violation decision 3rd argv 추가 / `pre-tool-guard.sh` emit_ask() 신규 + DROP/TRUNCATE 만 emit_ask 호출 + log_violation decision 3rd arg. §"차단 매핑 표" 갱신 (Decision 컬럼 신규) + §"5 층 보안 stack" Layer 3 row Decision 분기 명시 + §1/§3 본문 분기 명시. §2 회귀 0 (P1-P6 누적 모두 유지) / §4 §5 변경 영역 0 (자동 hook 부재) / sister SOT enforce 영역 변경 영역 0 (rate-limit / dqss / ai-rules-exposure 이미 advisory 또는 ask). destructive safety (rm -rf / force push / git reset --hard / data/artifacts) 유지. Karpathy §careful 정신 잔존 — automation 우회 X. AskUserQuestion 답: Q1 §2 전체 유지 / Q2 block→ask / Q3 sister 포함 (실 변경 영역 0). plan = `~/.claude/plans/wobbly-percolating-panda.md`.
