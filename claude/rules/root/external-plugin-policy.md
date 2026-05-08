# External Plug-in Policy (GSD · Context Mode · Claude Mem · /ultra-review)

## 목적

2026-05-06 사용자가 영상("400시간 후 내가 본 6개 스킬")을 본 뒤 다음 4종의 외부 plug-in / 내장 명령을 새로 활성화. 이 룰은 AirLens 정본 13체계 + 22개 프로젝트 hook + 자체 메모리 시스템 + R4 mutex 룰과 충돌 없이 공존시키기 위한 정책을 정한다. 하나의 정본 (sister: `.claude/rules/policy/matt-pocock-skills.md`).

본 룰은 **정책 문서**다. 실제 hook chain wire-up · settings.json 변경 · 자동 갱신 차단 옵션 적용은 **별도 후속 plan** (§7) 에서 처리한다.

## 도입 인벤토리

| Plug-in | 설치 방식 | 작용 범위 | 도입 일자 | License |
|---|---|---|---|---|
| GSD (Get Shit Done, TÂCHES) | `npx get-shit-done-cc --claude --global` v1.38.5 | **글로벌** `~/.claude/settings.json` — hook 9, skill 80+ | 2026-05-06 | MIT (확인 필요) |
| Context Mode (mksglu) | `/plugin install context-mode@context-mode` v1.0.111 | 글로벌 plug-in 캐시 + skill 12 + 11 ctx_\* MCP tools | 이미 §14.1.6 Tier 1 채택 (2026-05-06) | Elastic-2.0 |
| Claude Mem (thedotmack) | `/plugin install claude-mem@thedotmack` v12.6.5 | 글로벌 plug-in 캐시 + skill 10 + auto-capture hook | 2026-05-06 | (확인 필요) |
| /ultra-review (Anthropic) | Claude Code 2.1.86+ 내장 | 클라우드 sandbox + 비용 발생 | 2026-05-06 | Anthropic 내장 |

이미 글로벌 설치된 보조: Skill Creator, Superpowers, frontend-design (이번 룰의 §3 A·B·G 참조).

이미 운영 중인 sister 룰: Matt Pocock 6 skill (`.claude/rules/policy/matt-pocock-skills.md`).

## 5종 충돌 신호

| # | 충돌 | 위험도 | 발견 근거 (탐색 2026-05-06) |
|---|---|---|---|
| C1 | Claude Mem 자동 capture ↔ AirLens `MEMORY.md` + `memory/` | 중 | 두 시스템 모두 결정·feedback 자동 저장 → drift |
| C2 | Claude Mem 자동 CLAUDE.md 갱신 ↔ 정본 9+1+3 supersede 마커 | **고** | `Obsidian-airlens/raw/docs/{platform,web,app,ml,db}/PRD.md` 본문 자동 변경 시 wiki-curator 룰 위반 |
| C3 | GSD `.planning/` 패턴 ↔ AirLens `~/.claude/plans/<name>.md` | 중 | 글로벌 hook 9개가 모든 프로젝트에 적용 → mental model 분기 |
| C4 | Context Mode `permissive` sandbox ↔ R4 mutex 자원 보호 | **고** | sandbox subprocess가 production migration 명령 우회 가능 |
| C5 | `/ultra-review` 클라우드 업로드 ↔ public-repo.md `secrets/`·`Data/` 노출 금지 | **고** | 무차별 업로드 시 시크릿 유출 + 208GB Data 업로드 |

## 3. plug-in 별 사용 정책

### A. Skill Creator (이미 글로벌)

자유 사용. 새 skill 작성 시 `.claude/skills/<name>/SKILL.md` (Matt Pocock 패턴). 첫 머리에 한국어 hood + 정본 매핑 1줄 (`matt-pocock-skills.md` §"한국어 / 정본 정합 강제"와 동일).

### B. Superpowers (이미 글로벌)

새 기능·refactor·plan 작성 시 자체 워크플로우 통합. 제약:

- **충돌 회피** (`/tdd`, `/grill-me`, `/grill-with-docs`, `/improve-codebase-architecture`, `/diagnose`):
  - 우선 순위: in-place (`.claude/skills/`) > context-mode > superpowers
  - 현 시점 5 skill 모두 in-place 부재 (Matt Pocock SKILL.md 가 gitignored, plug-in 으로만 노출) → **context-mode 버전이 default**
  - T+30d 후 in-place 복원 여부 결정 → 결과는 `.claude/rules/policy/matt-pocock-skills.md` §History 누적
- AirLens production migration · Edge Fn deploy · 결제 라이브러리 작업은 **R4 mutex 우선** (superpowers brainstorming 워크플로우보다 hook 이 앞서 차단)

### C. GSD (Get Shit Done) — 제한 사용

AirLens 메인 레포에서 사용 차단. 근거:

- GSD `.planning/phase-N/` 패턴 ↔ AirLens `~/.claude/plans/<name>.md` 패턴 — 동시 사용 시 mental model 분기
- 글로벌 hook 9개 (`~/.claude/settings.json` 등록 — `gsd-check-update.js` · `gsd-session-state.sh` · `gsd-prompt-guard.js` · `gsd-read-guard.js` · `gsd-workflow-guard.js` · `gsd-context-monitor.js` · `gsd-read-injection-scanner.js` · `gsd-phase-boundary.sh` · `gsd-validate-commit.sh`) 가 모든 프로젝트에 자동 작동 — *비활성화는 후속 plan §7 (2)*

**룰** (2026-05-06 `gsd-opt-in-decision.md` plan 승인 — Option B Worktree-격리 sandbox 한정 ratification):

1. AirLens 메인 레포 작업 중 `/gsd-*` 80개 slash command **invoke 금지**
2. GSD 사용 허용 위치 = `.worktrees/gsd-<task-slug>/` (brand prefix `gsd-` 로 일반 `claude/*` worktree 와 분리). R1 worktree 격리 룰과 정합. 별도 sandbox 프로젝트도 허용 (out-of-tree)
3. `.gitignore` 에 `.planning/` 추가 — **2026-05-06 시행** (worktree 의 `.planning/` 메인 트리 누설 방지)
4. 메인 레포 cwd 에서 `.planning/config.json` 생성 시도 PreToolUse Write/Edit **차단** — `gsd-cwd-guard.sh` 신규 hook, 후속 plan §7 (3) 트리거
5. T+30d (2026-06-05) sandbox 활성 worktree count = 0 시 Option A (전면 차단) 자동 회귀 — 학습/평가 의도 검증 실패의 fallback. 결과 §History 누적

**검증 결과 (2026-05-06, `external-plugin-hook-isolation.md` 탐색 + `gsd-opt-in-decision.md` plan §2)**:

- GSD 9 hook 모두 advisory 또는 opt-in. 차단 가능 hook 4개 (`gsd-prompt-guard`, `gsd-read-guard`, `gsd-workflow-guard`, `gsd-validate-commit`) 중 실제 차단 동작은 `gsd-validate-commit.sh` 만 — 그것조차 `.planning/config.json { hooks.community: true }` opt-in 필요
- AirLens 에 `.planning/config.json` 부재 → opt-in 비활성 → 9 hook 효과적 no-op (advisory stdout/stderr 만, latency < 5ms)
- **2026-05-06 추가 검증**: `~/.claude/settings.json` 에 `gsd-*` hook 매치 0 — §4 표 (글로벌 9 hook 활성) 가 stale (v1.38.5 wrapper 가 settings.json 직접 등록 대신 plug-in cache 만 활용). 룰 4 (cwd-guard) 만 enforcement path 잔존
- **결론**: hook 무력화 action 불필요. Option B sandbox 활성 시 cwd-guard hook (룰 4) 로 메인 레포 격리 보장

### D. /review · /ultra-review

`/review` (로컬, 내장): 자유 사용. 기존 routing 매핑 (`CLAUDE.md` §Skill routing) 유지.

`/ultra-review` (클라우드, 비용 발생): **조건부 — 사전 5단계 체크리스트 필수**:

```bash
# 1) gitleaks 통과 (Layer 1 secret scan)
gitleaks detect --config=gitleaks.toml --no-banner -v

# 2) 업로드 경로 화이트리스트 — 다음 외 *모두 차단*
ALLOWED='^(apps/web|apps/app|packages|models)/'
git diff --name-only main..HEAD | grep -vE "$ALLOWED" \
  && echo "차단 — non-whitelisted path 포함" \
  || echo "통과"

# 3) 차단 경로가 diff 에 있으면 중단:
#    secrets/, .env*, Data/, Obsidian-airlens/, .worktrees/, _backup-local/, platform-data/

# 4) 트리거 조건 — 둘 중 하나 만족 시에만:
#    (a) >500 LOC 변경
#    (b) 결제 (Stripe/Polar/IAP) · production migration · secret · Edge Fn deploy · auth 처리 포함

# 5) 비용 인지 — Pro/Max 3회 무료 후 ~$5–20/run. 사용자 명시 승인 후 실행.
```

5단계 모두 통과 후 `/ultra-review` 호출. 거부 시 `/review` (로컬) 로 fallback.

### E. Context Mode (이미 §14.1.6 채택)

본 룰은 §14.1.6 Tier 1 채택 결정을 *연장* 한다. 추가 제약:

- **C4 충돌 회피 (고위험)**:
  - `permissive` sandbox 는 filesystem 전체 접근. `ctx_execute` subprocess 가 R4 자원 명령(`supabase apply_migration` · `supabase functions deploy` · `wrangler pages deploy` · `fly deploy`) 을 실행하면 R4 mutex hook 이 *Bash matcher* 에서 잡되 sandbox 내부 명령은 **잡히지 않을 수 있음**
  - **룰**: `ctx_execute` blacklist 패턴에 R4 자원 매핑(`scripts/hooks/r4-mutex-check.sh` §"자원 매핑") 등록 → ctx-doctor 결과로 검증
  - sandbox 내부에서 production secret 환경 변수 (`SUPABASE_SERVICE_ROLE_KEY` 등) 노출 금지 — `secrets/` 직접 접근 시 차단
  - 실제 blacklist 적용은 후속 plan §7 (2)
- **R4 mutex hook 자체가 현재 settings.local.json PreToolUse 체인에 wire-up 안 됨** (스크립트 존재 + multi-agent-worktree.md R4 룰 명시 — 그러나 hook 미활성). 후속 plan §7 (1) `r4-mutex-wireup.md` 에서 wire-up + reproduce 테스트 — **2026-05-06 완료** (Bash + `*supabase__*` MCP catch, 4 case reproduce PASS. lock 파일 idle 정상)
- 5 namespace 충돌 skill (`tdd` · `grill-me` · `grill-with-docs` · `improve-codebase-architecture` · `diagnose`) 은 §B Superpowers 에서 정의

**Context Mode `ctx_execute` 제약 (2026-05-06 검증, `external-plugin-hook-isolation.md`)**:

- sandbox `permissive` 고정 — `~/.claude/plugins/cache/context-mode/.../openclaw.plugin.json` 의 configSchema 가 `enabled: true/false` 만 노출. blacklist/denylist 키 부재. CLI flag · env var (`CTX_SANDBOX=strict` 등) 부재 확인
- R4 mutex hook (이번 wire-up) 은 `Bash` + `*supabase__*` MCP 만 catch — `mcp__context-mode__ctx_execute` (또는 동등 명) 우회 path 잔존
- **자체 룰 (자동 hook 없음)**:
  1. R4 자원 명령 (`supabase db push`, `supabase migration up|apply`, `supabase functions deploy`, `wrangler pages deploy`, `fly deploy`, `gh workflow run *deploy*`) 을 `ctx_execute` 로 **invoke 금지**
  2. `secrets/` · `.env*` · production secret env var (`SUPABASE_SERVICE_ROLE_KEY` 등) 접근 `ctx_execute` 로 **invoke 금지**
- ✅ **2026-05-06 `context-mode-guard.sh` wire-up 완료** (별 plan `context-mode-sandbox-guard`). 별 hook 분리 결정 — `r4-mutex-check.sh` 확장 옵션 *제거됨* (단일 책임 원칙: R4 자원 mutex vs Context Mode sandbox bypass 차단은 다른 의도). PreToolUse `*` matcher, GSD cwd-guard 다음 위치. 3 위험 tool (`ctx_execute` / `ctx_execute_file` / `ctx_batch_execute`) 의 zod schema 키 (`code` / `path`+`code` / `commands[].command`) 정확 매칭. 10 case reproduce PASS (R4 patterns 4 / secrets 3 / read-only false-positive 회피 3).
- T+7d (~ 2026-05-13) 실 사용 후 — Context Mode 신규 dangerous tool (예: `ctx_run`) 등록 시 hook 정규식 추가 검토

### F. Claude Mem

자동 capture: 활성 — session-level 디버깅 컨텍스트 · 코드 패턴 capture 용으로만 사용.

- **C2 충돌 회피 (고위험)**:
  - **자동 CLAUDE.md 갱신 비활성** (Claude Mem 설정 옵션 — 정확 옵션 명은 후속 plan §7 (2) 에서 확인 후 적용)
  - 자동 갱신 *대상에서 제외* (강제 화이트리스트):
    - `Obsidian-airlens/` (정본 9 + LLM Wiki — wiki-curator 룰)
    - `apps/{web,app}/CLAUDE.md` · `models/CLAUDE.md` · 루트 `CLAUDE.md`
    - 정본 9+1+3 supersede 마커 패턴 보호
  - 자동 갱신 *허용* 영역: `.claude/notes/<topic>.md` 같은 Claude Mem 전용 디렉터리 (또는 자동 갱신 자체 비활성, 검색만 사용 — 후속 plan §7 (2) 에서 결정)
- **C1 메모리 시스템 역할 분리**:
  - AirLens `MEMORY.md` + `memory/<topic>.md` (`~/.claude/projects/.../memory/`): **사용자 결정 · feedback · project 상태** (수동 promotion, instinct-status 패턴 — `MEMORY.md` 헤더 §"Types of memory" 참조)
  - Claude Mem SQLite + vector: **session-level 디버깅 · 코드 패턴** (자동 capture, `mem-search` skill 검색 전용)
  - 같은 사실을 두 곳에 저장하지 않음 — 자동 capture 가 결정 메모리 (`feedback_*` · `project_*`) 영역을 건드리지 않도록 룰 명시
- T+30d 통합 / 한쪽 폐기 결정. 결과는 §History 누적

**Claude Mem invoke 제약 (2026-05-06 검증, `external-plugin-hook-isolation.md`)**:

- `~/.claude/plugins/cache/thedotmack/claude-mem/12.6.5/hooks.json` PostToolUse `*` matcher 가 `worker-service.cjs hook claude-code observation` 호출 — **무조건** capture, 비활성 config 키 부재
- `auto_update_claude_md` · `disable_md_sync` · `skip_paths` · `CLAUDE_MEM_NO_AUTO_UPDATE` 류 config 키 / 환경 변수 부재 확인. 자동 갱신 로직은 `worker-service.cjs` 내부 하드코드
- **자체 룰 (자동 hook 없음)**:
  1. `learn-codebase` skill: AirLens 에서 invoke **금지** — protected path (`Obsidian-airlens/`, root `CLAUDE.md`, `apps/{web,app}/CLAUDE.md`, `models/CLAUDE.md`, `.claude/rules/**`) 자동 갱신 위험
  2. `mem-search` skill: 자유 사용 (read-only 검색)
  3. `do` · `pathfinder` · `version-bump` 등 write 가능 skill: protected path 회피 명시 후 invoke
  4. 자동 capture (PostToolUse hook) 는 비활성 불가능 — *검색 전용* 데이터로만 활용
- ✅ **2026-05-06 `claude-mem-watch.py` Stop hook wire-up** (별 plan `claude-mem-protected-path-watch`). 정본 13체계 mtime + sha256 hash + size 를 매 Stop event 에 `.claude/logs/claude-mem-watch.jsonl` 로 silent 기록 (no alert, no block). 14 path 측정 (13 present + 1 missing apps/app/CLAUDE.md). 4 case reproduce PASS. T+30d (2026-06-05) jsonl 분석 → unauthorized modification ≥ 1건 시 옵션 2 (`/plugin disable claude-mem`) trigger / 0건 시 plug-in 유지

### G. frontend-design (이미 글로벌)

자유 사용. 충돌 없음 (read-only UI 가이드).

## 4. Hook 체인 정합성 진단

탐색 (2026-05-06 초기 + `gsd-opt-in-decision.md` plan §2 재측정):

| 영역 | 위치 | 수 | 상태 |
|---|---|---|---|
| 프로젝트 PreToolUse | `.claude/settings.local.json` | 11 commands (10 matcher block) | 활성. C1.2 (2026-05-06) 후 SessionStart 3 + UserPromptSubmit 6 추가 wire-up |
| 글로벌 SessionStart | `~/.claude/settings.json` | **3** (gsd-check-update + gsd-session-state + context-mode-cache-heal) | 활성. GSD 2 + Context Mode 1 |
| 글로벌 PostToolUse | `~/.claude/settings.json` | **3** (gsd-context-monitor + gsd-read-injection-scanner + gsd-phase-boundary) | advisory (opt-in `.planning/config.json` 부재 시 stdout 만) |
| 글로벌 PreToolUse | `~/.claude/settings.json` | **4** (gsd-prompt-guard + gsd-read-guard + gsd-workflow-guard + gsd-validate-commit) | advisory. 차단 동작은 `gsd-validate-commit.sh` 만 — `.planning/config.json { hooks.community: true }` opt-in 필요. AirLens 미설정 → 효과적 no-op (advisory stdout/stderr 만) |
| 합계 글로벌 | `~/.claude/settings.json` | **10** (9 GSD + 1 Context Mode) | 모두 등록됨. 단 GSD 9 는 opt-in 비활성 시 no-op |
| 합계 프로젝트 + 글로벌 | — | 21 commands | 프로젝트 hook 11 commands + 글로벌 10 hook |

**우선 순위 룰** (정책 명시 — R4 + GSD cwd-guard + Context Mode guard wire-up 모두 2026-05-06 완료):

```
1. 안전 (pre-tool-guard.sh, gsd-prompt-guard.js — 글로벌 매치 0 시 no-op)
2. 자원 mutex (r4-mutex-check.sh — ✅ 2026-05-06 wire-up 완료)
3. cwd-guard (gsd-cwd-guard.sh — ✅ 2026-05-06 wire-up 완료, Option B sandbox 격리 enforcement)
4. Context Mode guard (context-mode-guard.sh — ✅ 2026-05-06 wire-up 완료, sandbox bypass 차단)
5. specialist (supervisor.py)
6. plug-in 자체 hook (Context Mode sandbox routing, Claude Mem capture)
7. 워크플로우 가드 (gsd-workflow-guard.js — 글로벌 매치 0 → 자동 no-op, 명시 비활성 불필요)
```

**검증된 gap** (이번 룰은 명시만, fix 는 후속 plan):

- ✅ **R4 mutex hook**: 2026-05-06 wire-up 완료 (4 case reproduce PASS). 더 이상 gap 아님
- ✅ **GSD 글로벌 hook 9 개**: settings.json 매치 0 검증 → 무력화 action **불필요** (`gsd-opt-in-decision.md` plan §2). 후속 plan `external-plugin-hook-isolation.md` (2) 의 (a) 항목 *제거됨*
- ✅ **Context Mode sandbox guard**: 2026-05-06 wire-up 완료 (별 plan `context-mode-sandbox-guard`). `context-mode-guard.sh` 가 3 위험 tool (`ctx_execute` / `ctx_execute_file` / `ctx_batch_execute`) 의 R4 + secrets/ + production secret env 차단. 10 case reproduce PASS
- ✅ **gsd-cwd-guard.sh**: 2026-05-06 wire-up 완료. `.claude/settings.local.json` PreToolUse 체인 R4 mutex 다음. 5 case reproduce PASS

## 5. 1개월 운영 spot check

- T+7d (2026-05-13): 각 plug-in 1회 invoke 후 충돌 spot check (한국어 흐름 자연스러운지 + 5 가드 영역 — Glass-box · 보안 경고 · destructive · multi-step · 사용자 재질문 — 풀 문장 유지 확인)
- T+14d (2026-05-20): hook 체인 latency 측정 (PreToolUse 50ms 기준). `token-budget-track.py` 결과 cross-check
- T+30d (2026-06-05):
  1. Claude Mem ↔ AirLens 메모리 시스템 통합 / 분리 결정
  2. in-place 5 skill (`tdd` · `grill-me` · `grill-with-docs` · `improve-codebase-architecture` · `diagnose`) 복원 여부 결정 → `.claude/rules/policy/matt-pocock-skills.md` §History 갱신
  3. GSD 글로벌 hook 비활성 여부 결정

각 spot check 결과는 본 룰 §History 누적.

## 6. 관련 자원

- `.claude/rules/policy/matt-pocock-skills.md` — Matt Pocock 6 skill 정책 (sister 룰 — 동일 패턴)
- `.claude/rules/multi-agent-worktree.md` — R4 mutex 자원 보호 (C4 충돌 정책의 베이스)
- `.claude/rules/public-repo.md` — secret 노출 금지 (D `/ultra-review` 화이트리스트의 베이스)
- `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md` — §10 sub-section "External Plug-ins" + §14.1.6 Context Mode Tier 1 채택 (이미)
- `~/.claude/settings.json` (글로벌) — GSD hook 9 인벤토리 (변경 시 사용자 확인)
- `.claude/settings.local.json` (프로젝트) — 22 hook 인벤토리 (변경 시 후속 plan)
- `scripts/hooks/r4-mutex-check.sh` — R4 자원 매핑 패턴 정본
- `scripts/hooks/supervisor.py` — specialist dispatch (gitignored, in-place)
- `~/.claude/plans/intro-0-00-after-spending-inherited-deer.md` — 본 룰의 발의 plan

## 7. 후속 plan (트리거만, 본 룰에서는 작성하지 않음)

본 룰은 정책 *문서* 만. hook 활성화 · settings 편집 · sandbox blacklist 적용은 다음 plan 에서:

1. **`r4-mutex-wireup.md`** — ✅ 2026-05-06 완료. R4 mutex hook 을 `.claude/settings.local.json` PreToolUse 체인에 추가. 우선 순위 §4 §룰 2 위치. 4 case reproduce PASS.
2. **`external-plugin-hook-isolation.md`** — scope 재축소 + 전체 진행 완료. (a) ~~GSD 글로벌 hook 9 프로젝트 무력화~~ → settings.json 매치 0 검증 결과 *제거됨*. (b) ✅ 2026-05-06 별 plan `claude-mem-protected-path-watch` *관측 단계* 완료 — `scripts/hooks/claude-mem-watch.py` (~80라인) Stop hook + jsonl 로그. T+30d 분석 후 disable 결정 (별 plan `claude-mem-disable.md` 또는 `claude-mem-keep.md` 후속 trigger). (c) ✅ 2026-05-06 별 plan `context-mode-sandbox-guard` 로 완료 — `scripts/hooks/context-mode-guard.sh` (~91라인) wire-up.
3. **`gsd-cwd-guard.sh`** — ✅ 2026-05-06 완료. Option B sandbox 룰 4 enforcement. PreToolUse Write/Edit matcher. cwd 가 `.worktrees/gsd-*/` 가 아닌데 `.planning/**` write 시도 시 차단. `scripts/hooks/gsd-cwd-guard.sh` (51 라인). `.claude/settings.local.json` PreToolUse 체인 R4 mutex 다음. 5 case reproduce PASS (메인 DENY · 일반 write ALLOW · `claude/*` worktree DENY · `gsd-*` worktree ALLOW · 절대경로 DENY).

## History

- 2026-05-06 — 초기 룰 작성. 영상 후 4종 plug-in 도입. Context Mode 는 §14.1.6 에 이미 Tier 1 채택. R4 mutex hook 미활성 gap 발견. 후속 plan 2건 트리거.
- 2026-05-06 — 후속 plan 1 (`r4-mutex-wireup.md`) 적용 완료. R4 mutex hook 이 `.claude/settings.local.json` PreToolUse 체인 6 번째에 wire-up. 4 case reproduce (unclaimed / owned-by-self / owned-by-other DENY / no-lock-file) 모두 PASS.
- 2026-05-06 — 후속 plan 2 (`external-plugin-hook-isolation.md`) scope 재정의. §3 C (GSD) opt-in 비활성 검증 결과 footnote 추가 — action 불필요 결론. §3 E (Context Mode) `ctx_execute` 제약 footnote 추가 — sandbox `permissive` 고정 + blacklist 부재 확인, behavioral 룰 4 항목 명시. §3 F (Claude Mem) invoke 제약 footnote 추가 — 자동 갱신 disable config 부재 확인, write skill 회피 룰 4 항목 명시. 후속 plan 5 trigger (gsd-opt-in-decision · claude-mem-disable · claude-mem-write-guard · r4-mutex-extend-context-mode · context-mode-disable) deferral.
- 2026-05-06 — codex 강연 audit 3종 (Advanced Context Engineering · AI Agent Workflow · AI Automation Founder) 정본 13체계 흡수. `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md` §15 신규 (15.1 Context Engineering / 15.2 Workflow Discipline / 15.3 Automation Boundaries). 원본 audit 보존 위치 `Obsidian-airlens/wiki/synthesis/codex-2026-05-06/`. plan = `~/.claude/plans/codex-smooth-bentley.md`. follow-up plan 4건 (data null + APP_PRD addendum / ai_readiness_audit script / Electron desktop / Animated Glass Icons) trigger 만, deferral.
- 2026-05-06 — `gsd-opt-in-decision.md` plan (`~/.claude/plans/snazzy-stargazing-hartmanis.md`) 승인. **Option B Worktree-격리 sandbox 한정** ratification. §3 C 룰 본문 5 항목 갱신 (룰 4 cwd-guard 신규, 룰 5 T+30d sandbox count = 0 자동 회귀 추가). §4 표 GSD 글로벌 hook count 9→0 정정 (settings.json 매치 부재 검증). §7 후속 plan 갱신 — `external-plugin-hook-isolation.md` (a) GSD 글로벌 hook 무력화 항목 제거, 신규 (3) `gsd-cwd-guard.sh` 트리거. T+30d (2026-06-05) sandbox 활성 worktree count 측정 예정. trigger = `/gsd-graphify` (config gate 정상 종료).
- 2026-05-06 — 후속 plan 3 (`gsd-cwd-guard.sh`) 즉시 적용 완료. `scripts/hooks/gsd-cwd-guard.sh` (51 라인) + `.claude/settings.local.json` PreToolUse Write\|Edit 체인 R4 mutex 다음 wire-up. 5 case reproduce PASS (메인 DENY · 일반 write ALLOW · `claude/*` worktree DENY · `gsd-*` worktree ALLOW · 절대경로 DENY). Option B 룰 4 enforcement gap 닫힘. `.gitignore` `.planning/` 추가도 동일 turn 시행. PR #202 commit `6139f420` main 머지.
- 2026-05-06 — 별 plan `context-mode-sandbox-guard` (`~/.claude/plans/snazzy-stargazing-hartmanis.md` overwrite) 적용 완료. `scripts/hooks/context-mode-guard.sh` (~91 라인) + PreToolUse `*` matcher 4 위치 wire-up. 3 위험 tool (`ctx_execute` / `ctx_execute_file` / `ctx_batch_execute`) zod schema 정확 매칭 (`code` / `path`+`code` / `commands[].command`). 10 case reproduce PASS (R4 4 / secrets 3 / read-only false-positive 회피 3). §3 E `ctx_execute` 제약 footnote + §4 우선 순위 표 + §7 후속 plan (c) 모두 ✅ 갱신. PR #203 commit `b80ac0b4` main 머지.
- 2026-05-06 — 별 plan `claude-mem-protected-path-watch` (plan 파일 overwrite) 관측 단계 적용 완료. `scripts/hooks/claude-mem-watch.py` (~80 라인) Stop hook + 정본 14 path (CLAUDE.md 4 + Obsidian docs 9 + 1 누락 apps/app/CLAUDE.md) mtime+sha256 hash+size 를 `.claude/logs/claude-mem-watch.jsonl` 로 silent 기록. 4 case reproduce PASS (모든 path 측정 / empty stdin / hash 일관성 / invalid JSON). PreToolUse hook intercept 불가능한 Node fs.writeFileSync 우회 path 의 *관측 메커니즘* 확보. T+30d (2026-06-05) jsonl 분석 → unauthorized 변경 ≥ 1건 시 disable plan trigger / 0건 시 plug-in 유지. §3 F invoke 제약 footnote + §7 (b) 모두 ✅ 갱신.
- 2026-05-06 — `vectorized-snacking-crown.md` plan Wave 1 cleanup 적용 완료. §4 글로벌 hook 표 정정 — `~/.claude/settings.json` 직접 검증 결과 10 hook 등록됨 (3 SessionStart + 3 PostToolUse + 4 PreToolUse, GSD 9 + Context Mode cache-heal 1). 직전 §History (2026-05-06 `gsd-opt-in-decision`) 의 "settings.json 매치 0" 기재는 *부분 stale* — settings.json 에 등록은 되어 있으나 enforcement (실제 차단) 는 `.planning/config.json` opt-in 시에만. 결론 동일 (AirLens 미설정 → 효과적 no-op). drift 원인 = v1.38.5 wrapper 가 npm 설치 시 settings.json 등록을 *수행함* (이전 가정 "plug-in cache 만" 잘못). C1.1 (multi-agent-worktree.md §R7.1 신규) + C1.2 (orphan agent-session-start.sh / heartbeat.sh wire-up + supervisor.py.bak 삭제) 동일 plan 에서 처리.
