# Wrap Skill — Commit + PR 자동화 정책

## 목적

`/wrap` skill (`.claude/skills/wrap/SKILL.md`) 의 자동화 경계 정의. push 는 사용자 무조건, commit + PR 은 자동. 5 가드 영역 (production migration / secret 변경 / Edge Fn deploy / 결제 라이브 / ML uncertainty) 명시 사용자 확인 강제. 본 plan = `~/.claude/plans/commit-pr-automation.md` Wave 1.

## 활성 상태

skill = `.claude/skills/wrap/SKILL.md` 등록됨 (2026-05-07). 정본 매핑 본 정책 + `multi-agent-worktree.md §R5 R10 R11 R12 R13` + `contributing.md` + `public-repo.md`.

## 자동화 영역 매트릭스 (12 영역)

### 자동 8 영역 (`/wrap` 1 invoke)

| # | 영역 | 자동화 방식 | 가드 |
|---|---|---|---|
| 1 | commit msg 생성 | conventional prefix 자동 추출 + body 1-2 sentence WHY | path → prefix mapping (SKILL.md Step 4a) |
| 2 | `git add` 선별 | 화이트리스트 기반 명시 add | Step 1b 화이트리스트 |
| 3 | `git commit` | heredoc + Co-Authored-By footer | `--no-verify` 금지 |
| 4 | committed broadcast | G4 hook (Bash matcher) 자동 | cross-check 만 |
| 5 | PR body 생성 | `.github/PULL_REQUEST_TEMPLATE.md` 자동 채움 | UI 변경 시 Screenshots placeholder 유지 |
| 6 | `gh pr create` | --base main / --head <current> | base fork 시 사용자 명시 |
| 7 | pr_opened broadcast | G4 hook 자동 | cross-check |
| 8 | R4.1 file mutex 검증 | dashboard 와 비교 | overlap 시 명시 확인 |

### 사용자 무조건 4 영역

| # | 영역 | 정책 |
|---|---|---|
| 9 | **`git push`** | **자동화 영원히 X** (사용자 결정 2026-05-07). skill 은 push prompt 만, 사용자 명시 발화 후 다음 step |
| 10 | main 머지 | R5 — "사람이 serialize" |
| 11 | 정본 9+1+3 PRD/Architecture 변경 | git tracked = 사용자 review (`feedback_git_tracked_user_review.md`) |
| 12 | production migration apply / Edge Fn deploy | R4 + Glass-box 5 가드. skill 차단 + 명시 확인 |

## 5 가드 영역 (자동화 *영원히* 회피)

다음 패턴 변경 staged 시 `/wrap` 자동 abort + 사용자 명시 확인 강제:

1. **production migration** (`supabase/migrations/*.sql`) — R4 mutex + 명시 확인
2. **secret 변경** (`secrets/*` / `.env*` / `SUPABASE_SERVICE_ROLE_KEY` 등 키워드) — gitleaks Layer 1 차단
3. **Edge Function deploy** (`supabase/functions/*/index.ts` + deploy 명령) — R4 mutex
4. **결제 라이브** (Stripe/Polar/IAP) — 사용자 명시
5. **ML/예측 출력 uncertainty** (p10-p90 + DQSS) — auto rewrite 금지 (`humanizer-agent.md` 5 가드와 동일)

5 영역 모두 `humanizer-agent.md` §"운영 한계" 와 동일 정신.

## 보안 가드 (Step 1)

각 commit 전 3 단계 통과 강제:

1. **gitleaks** (`gitleaks detect --staged`) — 100+ 패턴
2. **화이트리스트 path** — `apps/(web|app)`, `packages`, `models`, `scripts`, `.claude`, `.github`, `docs`, `*.md`, `gitleaks.toml`
3. **secret 키워드 grep** — `SUPABASE_SERVICE_ROLE_KEY` / `WAQI_TOKEN` / `OPENAQ_API_KEY` / `CLOUDFLARE_API_TOKEN` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `sk-[a-zA-Z0-9]{20,}`

3 단계 모두 통과 못 하면 즉시 abort + 사용자에게 위반 path/keyword 보고.

## 차단 path

다음은 `git add` 자동 회피 + staged 시 BLOCKED:

- `secrets/*`
- `.env*`
- `Data/*`
- `.worktrees/*`
- `_backup-local/*`
- `Obsidian-airlens/*` (단 `index.md` 만 예외)

## work-feed 통합

`/wrap` 은 work-feed.jsonl 에 직접 broadcast 안 함. G4 hook (Bash matcher PostToolUse) 이 `git commit` / `gh pr create` 결과를 자동 broadcast. skill 은 cross-check 만:

```bash
tail -n 5 .claude/locks/work-feed.jsonl | grep "$COMMIT_SHA"
tail -n 5 .claude/locks/work-feed.jsonl | grep "pr_opened" | grep "#$PR_NUM"
```

누락 시 수동 fallback (`agent-session.sh broadcast committed/pr_opened`).

## R4.1 file mutex 정합

PR open 직전 다른 active session 의 `files[]` 와 비교. overlap 시 사용자 명시 확인. 강제 차단 아님 — 사용자 결정 우선 (Anthropic Agent Teams `task_state` enum 정합).

## 사용 한도

- **세션 당 max 5 invoke** — 5+ commit/PR 한 세션 시 작업 분할 의심 (사용자 재질문)
- **1 invoke 1 PR** — `--multi-pr` 모드는 deferred (F4 trigger)

## 1개월 운영 spot check

- T+7d (2026-05-14): 1회 dry-run invoke (작은 변경 set) → workflow 11 step 한국어 보고 자연스러운지 spot check
- T+14d (2026-05-21): invoke 빈도 측정 (`.claude/logs/agent-routing.jsonl` grep `wrap`)
  - 0회 → 트리거 조건 강화 (description frontmatter 보강) 또는 deprecation 검토
  - 빈번 (≥ 5회) → 5 가드 영역 침범 발생 여부 검증
- T+30d (2026-06-06):
  - 5 가드 영역 침범 ≥ 1건 → policy 강화 또는 skill 일시 비활성
  - `--multi-pr` 모드 활성 결정 (F4)

## 결합 자산

- `.claude/skills/wrap/SKILL.md` — 본 정책 enforce 11 step workflow
- `.github/PULL_REQUEST_TEMPLATE.md` — PR body 자동 채움 source
- `gitleaks.toml` — Layer 1 시크릿 정본
- `scripts/hooks/r4-mutex-check.sh` — R4 자원 mutex
- `scripts/infra/agent-session.sh` — work-feed broadcast
- `.claude/rules/multi-agent-worktree.md §R5 R10 R11 R12 R13`
- `.claude/rules/contributing.md` — conventional commits + 커밋 전 검증
- `.claude/rules/public-repo.md` — `--no-verify` / force-push 금지
- `~/.claude/plans/commit-pr-automation.md` — 본 plan

## History

- 2026-05-07 — 초기 룰 작성. `commit-pr-automation.md` plan Wave 1 적용. push 사용자 무조건 / commit + PR 8 영역 자동 / 5 가드 영원히 X. T+30d 결정 누적.
