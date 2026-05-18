# Security Guards — 5 가드 영역 정본 (SOT)

## 목적

AirLens 자동화 시스템 (skill / hook / supervisor / wrap) 가 영구 회피해야 할 5 가드 영역의 *단일 정본 (single source of truth)*. 다른 모든 정책 / skill / hook 은 본 § 를 cross-link — 정의 중복 금지.

본 plan = `~/.claude/plans/purring-snuggling-sphinx.md` Wave 1.

## 5 가드 영역 (자동화 영원히 회피 — Glass-box 정합)

### 1. Production Migration

- **매핑 path**: `supabase/migrations/*.sql`
- **매핑 명령**: `supabase db push`, `supabase migration up`, `supabase migration apply`, `psql` 직접 호출
- **매핑 MCP**: `mcp__supabase__apply_migration`, `mcp__supabase__execute_sql`
- **차단 hook (Layer 3)**: `scripts/hooks/r4-mutex-check.sh` (resource = `production-db`) + `scripts/hooks/pre-tool-guard.sh`
- **사용자 명시 패턴**: 명시 migration name + "맞아" / "진행해" — generic ("옵션1", "전부 알아서", "한번에 진행") 거부
- **근거**: `feedback_hook_specific_naming.md`, `feedback_production_safety_gates.md`

### 2. Secret 변경

- **매핑 path**: `secrets/*`, `.env`, `.env.local`, `.env.production`, `.env.*`
- **매핑 키워드**: `SUPABASE_SERVICE_ROLE_KEY`, `WAQI_TOKEN`, `OPENAQ_API_KEY`, `CLOUDFLARE_API_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `STRIPE_SECRET_KEY`, `sk-{20+}`, `eyJ{32+}`
- **차단 layer**:
  - Layer 1 = gitleaks (pre-commit, `gitleaks.toml`)
  - Layer 2 = CI gitleaks (`.github/workflows/secret-scan.yml`)
  - Layer 3 = `scripts/hooks/pre-tool-guard.sh` (Bash cat/source secrets) + `scripts/hooks/context-mode-guard.sh` (sandbox bypass)
  - Layer 4 = `.claude/skills/wrap/SKILL.md` Step 1 (3중 검증)
  - 참고: `check-hardcoding.py` 는 UI 하드코딩 차단 (색상/gradient) — secret 차단 아님 (코드 품질 hook)
- **우회 path 자동 차단**: `cat`/`tail`/`head`/`awk`/`sed` (pre-tool-guard.sh) + `source` / `.` (pre-tool-guard.sh) + Context Mode `ctx_execute*` (context-mode-guard.sh)
- **우회 path 미차단 (Layer 5 정책만)**: Python `open('secrets/...')`, Node `fs.readFileSync` — Bash matcher 한계, 후속 plan F3 trigger
- **근거**: `feedback_secrets_inspection.md`, `feedback_secrets_python_open_pattern.md`

### 2A. GitHub Actions PR credential boundary

- **매핑 path**: `.github/workflows/*.yml`
- **금지 패턴**: `pull_request` job에서 PR branch code를 checkout/run 하면서 repository secret, App token, `contents: write`, `pull-requests: write`를 같이 사용
- **허용 패턴**:
  - PR code 실행 job = `contents: read` + `actions/checkout` `persist-credentials: false`
  - write/comment/deploy job = trusted base checkout (`ref: ${{ github.base_ref }}`) 또는 checkout 없음
- **차단 layer**: `scripts/maintenance/check-actions-pr-token-safety.py` + `.github/workflows/secret-scan.yml` `actions-pr-token-safety`
- **정본 정책**: `github-actions-pr-security.md`

### 3. Edge Function Deploy

- **매핑 path**: `supabase/functions/*/index.ts` 변경 + deploy 명령
- **매핑 명령**: `supabase functions deploy`
- **매핑 MCP**: `mcp__supabase__deploy_edge_function`
- **차단 hook (Layer 3)**: `scripts/hooks/r4-mutex-check.sh` (resource = `edge-function-deploy`)
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

| 가드 | PreToolUse hook | Skill 검증 | Policy SOT |
|---|---|---|---|
| 1 production migration | `r4-mutex-check.sh` (production-db) + `pre-tool-guard.sh` | wrap Step 2 / supervise #2 | 본 §1 |
| 2 secret 변경 | `pre-tool-guard.sh` + `context-mode-guard.sh` + gitleaks (commit-time) | wrap Step 1 / supervise #1 | 본 §2 |
| 2A PR credential boundary | `check-actions-pr-token-safety.py` (CI) | workflow review | `github-actions-pr-security.md` |
| 3 Edge Fn deploy | `r4-mutex-check.sh` (edge-function-deploy) | wrap Step 2 / supervise #3 | 본 §3 |
| 4 결제 | (사용자 명시 — 자동 hook 부재) | wrap Step 2 / supervise #4 | 본 §4 |
| 5 ML uncertainty | (humanizer agent ban — 자동 hook 부재) | (Glass-box 의무) | 본 §5 |

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
| 3 — Hook PreToolUse | 8 hook (R7.1 stack) | check-hardcoding / pre-tool-guard / r4-mutex / r4-file-mutex / context-mode-guard / gsd-cwd-guard / supervisor / tdd-guard |
| 4 — Skill Step 1 | `.claude/skills/wrap/SKILL.md` Step 1 | 3중 검증 (gitleaks + 화이트리스트 + secret grep) |
| 5 — Policy 5 가드 | 본 file (security-guards.md) | 자동화 영원히 회피 |

상세 = `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md §21 Security Hardening` (Wave 2 신규).

## 결합 자산

- `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md §21` — Wave 2 신규 §
- `gitleaks.toml` — Layer 1+2 정본
- `scripts/hooks/r4-mutex-check.sh` — production-db / edge-function-deploy / production-deploy mutex
- `scripts/hooks/pre-tool-guard.sh` — Bash cat/source/echo secrets 차단
- `scripts/hooks/check-hardcoding.py` — PreToolUse Write|Edit 하드코딩 차단
- `scripts/hooks/context-mode-guard.sh` — Context Mode sandbox bypass 차단
- `.claude/skills/wrap/SKILL.md` Step 1 — gitleaks + 화이트리스트 + secret grep (gitignored in-place)
- `.claude/skills/supervise/SKILL.md` 6 안전장치 — 5 가드 #2 자동 abort (gitignored in-place)
- `~/.claude/plans/purring-snuggling-sphinx.md` — 본 plan

## History

- 2026-05-07 — 초기 SOT 작성. 기존 분산 정의 (supervisor-delegation.md / supervisor-tune.md) → 본 § cross-link 만으로 정정. wrap-skill.md cross-ref 는 `claude/commit-pr-automation` 머지 후 후속 정합. matt-pocock-skills.md `/caveman` 5 가드는 brevity 예외 scope 라 별 § 유지.
