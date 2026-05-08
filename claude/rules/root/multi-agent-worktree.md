# Multi-Session Worktree Coordination

claude / codex / gemini 세션이 같은 레포에서 동시에 돌 때 충돌 0 + 상호 visibility를 보장하는 8가지 룰. canonical doc: `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md` §6.4.

## R1. Worktree 강제 분리 (MUST)

- 메인 체크아웃은 **통합 PR 머지·코드 리딩 baseline 전용**. 일반 작업 write 금지.
- 세션마다 `.worktrees/<agent>-<task-slug>/` 신규 worktree 생성.
- 브랜치 명명: `<agent>/<task-slug>` (예: `claude/feat-auth-mfa`, `codex/refactor-models`, `gemini/docs-update`).
- 사용자 명시 `--shared-tree` 또는 "메인에서 작업해" 발화 시에만 R1 우회 (R8 참고).

### R1.1 — read-only 점검은 shared-tree 권장 (2026-05-07)

worktree 강제는 **코드 변경 작업** 에만 적용. 작은 read-only 작업은
shared-tree 가 더 효율적. 근거: 매 worktree 시작 = ~46k tokens 자동 로드
(`Obsidian-airlens/index.md` + `.claude/rules/*` + `MEMORY.md` + dashboard).
read-only 작업에 그 비용은 과함.

| 작업 종류 | 권장 |
|---|---|
| 파일 읽기 / grep / 코드 탐색 | shared-tree (worktree 회피) |
| audit / status 점검 / 문서 read | shared-tree |
| 단순 질문 응답 / 메모리 조회 | shared-tree |
| 코드 변경 (Write/Edit) | worktree 강제 |
| PR 생성 / push / commit | worktree 강제 |
| 머지·deploy·migration | worktree 강제 + R4 mutex |

**판정 휴리스틱**: 작업 끝에 `git diff --stat` 가 비어있을 거면 shared-tree.
변경 commit 가능성 ≥ 1 이면 worktree.

shared-tree 모드 진입: 사용자 명시 `--shared-tree` 또는 "메인에서 작업해"
발화. AI 자체 판단으로 R1 우회 금지 — 사용자 의도 명시 필수.

## R2. 세션 lock 등록 (MUST)

- 위치: `.claude/locks/active-sessions.json` (gitignored).
- 세션 시작 시 entry append, 종료 시 remove.
- atomic write: tmp 파일 + `mv` rename + `flock`.
- 헬퍼: `scripts/infra/agent-session.sh start <task-slug>` / `stop`.

## R3. Heartbeat & Stale GC (SHOULD)

- 활성 세션은 5분마다 `heartbeat_at` 갱신 (`agent-session.sh heartbeat`).
- 다음 세션 시작 시 자동 GC: PID dead OR `now - heartbeat_at > 30min` → entry 제거.
- 수동 트리거: `agent-session.sh gc`.

## R4. 공유 자원 mutex (MUST)

대상:
- production DB migration apply (`production-db`)
- production deploy (`production-deploy`)
- Edge Function deploy (`edge-function-deploy`)
- 결제 라이브 환경 호출 (수동 카테고리, 후속 plan에서 자동화)

수동 절차:
1. 작업 직전 `agent-session.sh claim <resource>` → 성공해야 진행.
2. 다른 세션이 claim 중이면 **차단** + 점유 세션 정보 출력.
3. 작업 후 `agent-session.sh release <resource>`. 1h 자동 만료.

자동 검사 (PreToolUse hook): `scripts/hooks/r4-mutex-check.sh` 가 다음 패턴을 자원으로 매핑하고 다른 세션 점유 시 **차단**:

| 자원 | 매핑 |
|---|---|
| `production-db` | MCP `*supabase__apply_migration` / `*supabase__execute_sql`, Bash `(npx\|pnpm\|npm exec) supabase (db push\|migration up\|migration apply)` |
| `edge-function-deploy` | MCP `*supabase__deploy_edge_function`, Bash `supabase functions deploy` |
| `production-deploy` | Bash `wrangler pages deploy`, `fly deploy`, `gh workflow run *deploy*` |

owner 없음 → allow + stderr reminder. 자기 세션 owner → allow. 다른 세션 owner → **deny** + owner_session/agent/branch/claimed_at 출력. 매핑 미스 → silent allow.

조회: `agent-session.sh who-claims <resource>` (read-only).

wire-up (`.claude/settings.local.json`): PreToolUse 체인에 `pre-tool-guard.sh` 다음, `supervisor.py` 앞에 `r4-mutex-check.sh` 삽입 (자세한 JSON 예시는 R7 참고).

## R5. PR/머지 직렬화 (MUST)

- 각 에이전트는 자기 worktree·브랜치에서 push + PR 생성까지만.
- main 머지는 **사람이 serialize** (`public-repo.md` "PR 우회 금지" 강화).
- 머지 후 다른 에이전트는 자기 worktree에서 `git fetch && git rebase origin/main`.

## R6. 타 에이전트 브랜치 침범 금지 (MUST NOT)

- claude 세션은 `codex/*`, `gemini/*` 브랜치에 push / force-push / `branch -D` 금지.
- codex / gemini도 대칭 적용.
- 강제 회수 필요 시 사용자에게 확인 후 진행.

## R7. 세션 시작 표준 절차

수동:
```bash
AGENT=claude  # or codex / gemini

scripts/infra/agent-session.sh list                 # active 세션 표시
scripts/infra/agent-session.sh gc                   # stale entry 정리
scripts/infra/agent-session.sh start feat-auth-mfa  # worktree + lock entry
cd .worktrees/claude-feat-auth-mfa

# ... 작업 ...

scripts/infra/agent-session.sh stop                 # lock 해제
git worktree remove .worktrees/claude-feat-auth-mfa # 옵션
```

자동 (codex/gemini): 래퍼가 worktree 생성 + 5분 백그라운드 heartbeat + 종료 시 cleanup.
```bash
scripts/infra/codex-session.sh refactor-models           # codex CLI 진입
scripts/infra/gemini-session.sh docs-update              # gemini CLI 진입
```

자동 (claude): hook 스크립트가 cwd-기반 lock 등록·heartbeat·R4 mutex 자동 검사. 다음을 `.claude/settings.local.json`에 1회 wire-up:
```json
{
  "hooks": {
    "SessionStart":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "scripts/hooks/agent-session-start.sh" }] }],
    "UserPromptSubmit":  [{ "matcher": "*", "hooks": [{ "type": "command", "command": "scripts/hooks/agent-session-heartbeat.sh" }] }],
    "PreToolUse": [
      { "matcher": "Bash",                 "hooks": [{ "type": "command", "command": "scripts/hooks/pre-tool-guard.sh" }] },
      { "matcher": "*",                    "hooks": [{ "type": "command", "command": "scripts/hooks/r4-mutex-check.sh" }] },
      { "matcher": "Write|Edit|MultiEdit", "hooks": [{ "type": "command", "command": "scripts/hooks/supervisor.py" }] }
    ]
  }
}
```
PreToolUse 순서: 안전(pre-tool-guard) → 자원 mutex(r4-mutex-check) → plan/specialist(supervisor).
hook은 silent + best-effort. cwd가 `.worktrees/<agent>-<slug>/` 가 아니면 자동 no-op. hook-managed 세션은 `pid=0`, GC는 heartbeat-only로 stale 판정.

### R7.1 Hook Execution Order — 실제 등록 상태 (2026-05-06)

위 snippet 은 *최소 권장 wire-up*. 실제 `.claude/settings.local.json` 에는 추가 hook 이 누적되어 있다. claude 가 실패 hook 을 디버그할 때 우선 이 표를 참조.

**PreToolUse `Write|Edit` 5-stack** (등록 순서 = 실행 순서, Write 와 Edit 모두 fire):

| # | command | 책임 | 차단 조건 |
|---|---|---|---|
| 1 | `check-hardcoding.py` | 하드코딩 색상/숫자/문자열 차단 | `APP_CONFIG` / `t()` 없는 raw 값 |
| 2 | `supervisor.py` | specialist dispatch 검증 | FEATURE/MULTI_DEPT 의도에 specialist 미지정 |
| 3 | `tdd-guard.sh` | test 파일 존재 검증 | 신규 prod 코드 + 대응 test 파일 부재 |
| 4 | `gsd-cwd-guard.sh` | `.planning/` 메인 누설 차단 | cwd ≠ `.worktrees/gsd-*/` 인데 `.planning/**` write |
| 5 | `fk-type-precheck.py` | FK type drift 차단 | migration 의 FK 타입 drift |

**추가 PreToolUse `Edit` 1-stack** (Edit 만 fire, Write 는 fire 안 함):

| # | command | 책임 | 차단 조건 |
|---|---|---|---|
| - | `route-change-guard.py` | route 정의 변경 보호 | 보호된 route 파일의 path 변경 |

**PreToolUse `*` 2-stack** (모든 tool 대상):

| # | command | 책임 | 차단 조건 |
|---|---|---|---|
| 1 | `r4-mutex-check.sh` | 자원 mutex (production-db / edge-function-deploy / production-deploy) | 다른 세션 owner 시 |
| 2 | `context-mode-guard.sh` | Context Mode sandbox bypass 차단 | `ctx_execute*` 가 R4 자원 / `secrets/` / production secret env 접근 |

**PreToolUse `Bash` 2-stack**: `pre-tool-guard.sh` (보안 가드) → `rtk hook claude` (RTK 출력 압축).

**PreToolUse `mcp__supabase__apply_migration` 1-stack**: `fk-type-precheck.py` (`Write|Edit` 와 동일 스크립트, migration 한정 재호출).

**PostToolUse `Write|Edit` 4-stack**: `post-edit-quality-check.py` → `check-cross-store.sh` → `record-session-activity.py` → `wiki-auto-index.py`.

**Stop `*` 4-stack**: `session-quality-gate.py` → `session-daily-summary.py` → `session-close.sh` → `claude-mem-watch.py` (정본 13체계 mtime+sha256 기록).

**UserPromptSubmit `*` 5-stack**: `supervisor.py` → `record-github-repos.py` → `record-chat-log.py` → `record-handoff-on-keyword.py` → `classify-prompt.py` (plan-tier 분류 M1).

**우선순위 원칙**:
1. 빠른 차단 (하드코딩 / 보안) 가 먼저 — latency 최소
2. 자원 mutex (R4) → cwd-guard (Option B) → sandbox guard (Context Mode) → specialist dispatch (supervisor)
3. 기록 / observability hook (record-*, wiki-auto-index) 는 PostToolUse / Stop 으로 후순위

**검증 명령** (`.claude/settings.local.json` 변경 후):

```bash
jq '.hooks.PreToolUse[] | select(.matcher == "Write|Edit") | .hooks[].command' .claude/settings.local.json
```

위 표의 6 row 와 출력 순서 일치 확인.

## R4.1 코드 파일 mutex (T1-A, 2026-05-07)

R4 의 *자원* mutex (production-db / edge-fn / production-deploy) 와 평행하게, *코드 파일 단위* 의 mutex 를 추가한다. PR #222 사고처럼 codex 와 claude 가 동일 파일 (`AtmosphericBackground.tsx` 등) 을 동시에 작업하면 머지 시 conflict.

### lock schema 확장

`.claude/locks/active-sessions.json` 의 각 session entry 에 `files[]` 배열:

```json
{
  "session_id": "claude-wt-feat-foo",
  ...
  "files": [
    { "path": "apps/web/src/components/Foo.tsx", "first_seen": "2026-05-07T08:00:00Z", "last_edit": "2026-05-07T08:30:00Z" }
  ]
}
```

### 자동 갱신

PreToolUse `Write|Edit|MultiEdit` hook 에서 `agent-session.sh touch <path>` 호출. 같은 파일이 다른 active session 의 `files[]` 에 있으면 **`{"decision":"ask"}`** 반환 (block 아님 — 친구 AI 마찰 최소화).

### Wire-up

`scripts/hooks/r4-file-mutex-check.sh` (R7.1 표 4-bis 위치, gsd-cwd-guard 다음). hook 이 ask 반환 시 사용자가 yes/no 선택.

### 적용 제외

- 신규 파일 (다른 session 에 등록 안 됨) — 자유 작업
- 같은 session 의 재진입 (session_id 일치) — 항상 allow
- 자기 worktree 내부의 fixture / test 데이터 — 패턴 (`*.fixture.json`, `*-test.json`) 화이트리스트

## R10. Untracked file 영속 보호 (T1-C, 2026-05-07)

rebase / merge 중 blocking untracked file 발생 시 `/tmp` 사용 금지.

### 사고 (2026-05-06, PR #217)

`policy-drift-watch.py` (7740 bytes) untracked 상태로 rebase 시 `/tmp` 이동 → 시스템 cleanup 으로 영구 소실. `.worktrees/codex-*/scripts/hooks/` mirror 에서 우연히 복구.

### 룰

- **금지**: `mv <file> /tmp/`, `cp <file> /tmp/` 로 untracked file 백업
- **허용** (둘 중 하나):
  1. `git stash --include-untracked --message "<reason>"` — git 내부 보관, 영속
  2. `scripts/infra/safe-stash.sh save <slug>` — `~/.claude/backup/<date>-<slug>/` 영속 저장. `restore <slug>` 로 복원

### 자동화

`safe-stash.sh prune 30` 으로 30일 이상 된 snapshot 자동 정리. cron / weekly-digest 에서 호출 가능.

## R8. 사용자 명시 override

- `--shared-tree` 인자 또는 사용자 발화 ("이번엔 메인에서 작업해") → R1 우회.
- R2 lock 등록 + R4 공유 자원 mutex는 그래도 강제.

## R9. 헤비 deps 공유 (옵션)

worktree마다 `node_modules` / `.venv` 새로 설치는 디스크·시간 소모. 같은 lockfile 상태를 공유한다고 확신할 때만 opt-in 심볼릭 링크:
```bash
cd .worktrees/claude-feat-auth-mfa
scripts/infra/worktree-link-deps.sh
```
대상: `node_modules`, `apps/web/node_modules`, `apps/app/node_modules`, `models/.venv`. 브랜치 간 `package.json` / `pyproject.toml` 차이 있으면 사용 금지. 메인과 worktree에서 동시에 install 실행 금지.

## R11. SessionStart dashboard (SHOULD, Tier 2)

SessionStart hook (`scripts/hooks/agent-session-start.sh`) 가 자동으로 `agent-session.sh dashboard` 출력. AI 는 다른 active session 의 진행 상황 + 최근 work-feed event 를 인지 후 작업 시작.

dashboard 출력 = JSON (sessions[] + shared_resource_locks{} + recent_events[20]). silent 실패 (Tier 2 파일 부재 시 hook 자체는 PASS).

## R12. 의미 있는 결정 broadcast (SHOULD, Tier 2)

다음 시점에 `agent-session.sh broadcast decision "<설명>"` 호출 권장:
- 옵션 분기 결정 (e.g., "Option A 선택")
- 새 plan 작성 시
- 외부 의존성 추가/제거
- production 자원 (DB / Edge Fn / deploy) 작업 시작

추가 권장 시점 (Tier 2 plan §12 보강):
- 새 worktree 생성 직후 → `broadcast started "<task>"`
- commit 직후 → `broadcast committed "<sha> <message>"` --files <paths>
- PR 생성 직후 → `broadcast pr_opened "<#PR> <title>"`
- 작업 완료 직후 → `broadcast done "<summary>"` (Stop hook 가 자동 호출)

`broadcast` 는 work-feed.jsonl 에 append-only. 8 event 타입 화이트리스트 (started/intent/decision/committed/pr_opened/blocked/handoff/done). schema_version "1.0.0" + ts 자동 stamping.

## R13. Blocked 시 broadcast 의무 (MUST, Tier 2)

다음 시 `agent-session.sh broadcast blocked "<이유>" --to <session_id>` 호출:
- 다른 세션의 작업 결과를 기다려야 진행 가능 (handoff 필요)
- 사용자 결정 대기 중 다른 세션이 동시 작업 중인 영역
- R4 / R4.1 mutex 충돌로 차단됨

`handoff` event 는 Swarm `Result(agent=..., context_variables=...)` shape:
```json
{
  "event": "handoff",
  "session_id": "<from>",
  "to": "<receiving_session>",
  "intent": "<one-line 의도>",
  "context_files": ["a.tsx", "b.tsx"],
  "rationale": "<이유>"
}
```
receiving session 의 SessionStart dashboard 가 자기 ID 를 `to` 로 가진 handoff event 를 발견하면 prompt context 에 자동 주입 (subscriber 패턴 — `.claude/subscribers/handoff-router.py`, 사용자 선택 daemon).

## R14. 5 Deferral 안전 워크플로우 (2026-05-07)

`/supervise` skill 의 5 deferral 항목 (사용자 명시 plan = `~/.claude/plans/purring-snuggling-sphinx.md` Wave 3) 진행 시 R1-R13 정합 표준 절차. 5 항목 자체는 데이터 후 결정 보존 — 본 §R14 는 *진행 시* 안전 워크플로우 만 정의.

### 5 deferral 항목 인벤토리

1. **W4 supervisor 자동 spawn** (옵션 B AskUserQuestion) — `~/.claude/plans/commit-pr-automation.md` §P3
2. **`/ship` (Yeachan-Heo) vs `/wrap` 비교 문서** — F1
3. **`/wrap --multi-pr` mode** (monorepo packages) — F4
4. **OMC 풀 채택** (`omc team N:claude` spawn + tmux) — separate plan
5. **hermes-agent ACP 평가** — F2

### 항목별 표준 절차 (트리거 시점에 적용)

각 항목 시작 시 9 step:

```
1. 사용자 명시 결정 ("X 항목 진행")
2. /supervise <plan-slug> invoke → dispatch 안 (Wave 1 default = 옵션 A full auto)
3. 별 worktree 생성: .worktrees/claude-deferral-<항목-slug>/
   예: .worktrees/claude-deferral-w4-supervisor-spawn/
4. R11 dashboard 확인 — 다른 active session 인지
5. R4.1 file mutex 자동 — 같은 file 작업 중인 다른 session 시 차단
6. 진행 중 broadcast started → intent → decision → committed → pr_opened → done
7. 다른 session 으로 handoff 필요 시 broadcast handoff event (Swarm Result shape, R13)
8. /wrap 으로 commit + PR (push 사용자 직접 — R5 + push 자동화 X 정책)
9. 머지 R5 (사용자 직접)
```

### 5 항목 간 의존성

| # | 항목 | 의존 | 안전 조건 |
|---|---|---|---|
| 1 | W4 supervisor 자동 spawn | T+30d agent-routing 데이터 + Wave 1 (`/supervise`) | 옵션 B (AskUserQuestion 확인) — 옵션 A (full auto) 회피 |
| 2 | `/ship` vs `/wrap` 비교 | 없음 — 즉시 가능 | 문서만 — 코드 변경 0 |
| 3 | `/wrap --multi-pr` | `/wrap` 사용 빈도 ≥ 5 (T+14d 측정) | monorepo 변경 동반 시만 활성 |
| 4 | OMC 풀 채택 | T+30d sandbox 활성 worktree count > 0 | 글로벌 `~/.claude/settings.json` 변경 — 사용자 명시 승인 |
| 5 | hermes ACP 평가 | OMC 통합 성공 후 | 별 sandbox 프로젝트 (out-of-tree) — AirLens 메인 영향 0 |

### 동시 진행 가능 / 회피

| 동시 가능 | 동시 회피 |
|---|---|
| 2 (`/ship` 비교 문서) + 3 (`--multi-pr`) — 다른 영역 | 1 (W4) + 4 (OMC) — supervisor.py 양쪽 수정 충돌 |
| 5 (hermes 별 sandbox) + 다른 어느 것 | 4 (OMC 글로벌 env) + 다른 worktree 작업 — env propagation 위험 |

### 6 안전장치 (`/supervise` 옵션 A 진행 중 즉시 중단)

R14 진행도 `/supervise` 위임 → 6 안전장치 자동 적용:

1. 사용자 발화 "stop" / "잠깐" / "멈춰" / "취소"
2. 5 가드 영역 검출 (production migration / secret / Edge Fn / 결제 / ML uncertainty)
3. R4.1 file mutex 차단
4. gitleaks fail (Layer 1)
5. test fail (`npm run test:run` / `pytest`)
6. type check fail (`tsc` / `mypy`)

중단 시 = 현재 step commit (있으면) + work-feed broadcast `blocked` event + 사용자 보고. handoff 가능 시 다른 session 으로 인계 안.

### 결합 자산

- `.claude/skills/supervise/SKILL.md` — Wave 1 위임 진입점
- `.claude/rules/policy/supervisor-delegation.md` — 본 §R14 정책 베이스
- `.claude/skills/wrap/SKILL.md` — 각 Wave 끝 commit + PR

## Anthropic Agent Teams vocabulary 정합 (Tier 2)

R11-R13 의 task_state enum 은 Anthropic Claude Code 2.1+ Agent Teams 와 정합:

| AirLens lock entry | Anthropic Agent Teams |
|---|---|
| `task_state: pending` | task in pending state |
| `task_state: in_progress` | task being worked on |
| `task_state: blocked` | (AirLens 확장 — Anthropic 기본 enum 외) |
| `task_state: reviewing` | (AirLens 확장 — code review 단계) |
| `task_state: completed` | task done |

근거: `Obsidian-airlens/wiki/synthesis/multi-agent-coord-research-2026-05-07.md` Area 4 — Anthropic Agent Teams primitive 와 AirLens R4 mutex + agent-session.sh claim 가 *동일 패턴*. vocabulary 정합으로 새 contributor 가 Anthropic 공식 docs (`code.claude.com/docs/en/agent-teams`) 읽고 AirLens 인프라 즉시 이해 가능.
