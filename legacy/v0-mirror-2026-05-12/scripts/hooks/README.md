# scripts/hooks/

AirLens Claude Code hook scripts. 2026-05-01부터 tracked (이전: gitignored). 멀티 세션 (claude/codex/gemini) 동기화 + supervisor.py 의 specialist coverage / write_flags / AGENT_ALIASES fix 전파 목적.

## 보안 카테고리별 인벤토리

### 보안 코어 (4) — 출시 후에도 절대 비활성화 금지

| Hook | 설명 |
|---|---|
| `pre-tool-guard.sh` | Bash 실행 시 rm -rf 루트/홈, force-push main, DROP TABLE, secrets/* 접근, source .env 차단 |
| `r4-mutex-check.sh` | production-db / edge-function-deploy / production-deploy 자원 lock. 다른 세션 점유 시 deny |
| `supervisor.py` | UserPromptSubmit 분류 + PreToolUse specialist coverage + PostToolUse Agent dispatch 누적. AGENT_ALIASES intersection 검사가 보안 코어 |
| `fk-type-precheck.py` | Write/Edit/MCP apply_migration 직전 FK 타입 정합성 검증 |

### 코드 품질 (5) — 경고 또는 일부 차단

| Hook | 설명 |
|---|---|
| `check-hardcoding.py` | Write/Edit 시 인라인 색상/매직넘버/중복 상수 차단 |
| `route-change-guard.py` | App.tsx Route 레이아웃 변경 시 경고 |
| `tdd-guard.sh` | 테스트 파일 부재 시 경고 |
| `post-edit-quality-check.py` | Edit 직후 품질 검증 |
| `check-cross-store.sh` | 크로스 스토어 접근 검사 |

### 자동 감지 (1)

| Hook | 설명 |
|---|---|
| `circuit-breaker.py` | 60초 내 3회 실패 감지 → 전략 변경 경고 |

### 분류 / 베이스라인 (3)

| Hook | 설명 |
|---|---|
| `classify-prompt.py` | M1 dry-run: trivial/interactive/autonomous 분류 jsonl 기록 (응답 차단 없음) |
| `session-init.py` | SessionStart 시 프로젝트 에이전트 목록 + 규칙 stderr 주입 |
| `plan-gate.py` | ExitPlanMode 후 plan 플래그 보존 |

### 세션 관리 (5)

| Hook | 설명 |
|---|---|
| `agent-session-start.sh` | hook-managed 세션 lock 등록 (cwd 가 .worktrees/<agent>-<slug>/ 일 때만 활성) |
| `agent-session-heartbeat.sh` | UserPromptSubmit 마다 lock heartbeat 갱신 |
| `session-close.sh` | Stop 시 세션 정리 |
| `session-daily-summary.py` | Stop 시 일일 요약 자동 생성 |
| `session-quality-gate.py` | Stop 시 세션 종료 품질 검증 |

### 기록 / 텔레메트리 (5)

| Hook | 설명 |
|---|---|
| `record-agent-routing.py` | PostToolUse Agent 라우팅 기록 |
| `record-chat-log.py` | UserPromptSubmit 채팅 로그 (출력 대상 `Obsidian-airlens/wiki/log/` gitignored) |
| `record-github-repos.py` | UserPromptSubmit GitHub repos 발화 기록 |
| `record-handoff-on-keyword.py` | UserPromptSubmit 키워드 기반 핸드오프 자동 |
| `record-session-activity.py` | Write/Edit/Bash 활동 로깅 |

### 기타 (3)

| Hook | 설명 |
|---|---|
| `wiki-auto-index.py` | Write/Edit 후 wiki 자동 인덱싱 |
| `token-budget-track.py` | SessionStart 시 자동 로드 컨텍스트 토큰 예산 추적 |
| `supervisor-routing-fixtures.json` | supervisor.py 회귀 테스트 fixture |

## 백업 파일 정책

- `*.bak.*` 패턴: gitignored (예: `supervisor.py.bak.20260501-prelaunch`).
- 임시/실험 패치 시 사용. 회귀 시 즉시 복원 가능.
- Phase 종료 후 정리 권장 (`rm scripts/hooks/*.bak.*`).

## `_DEPRECATED_*` 파일

`_DEPRECATED_agent-dispatch-enforcer.py`, `_DEPRECATED_supervisor-auto-route.py`, `_DEPRECATED_supervisor-enforcer.py` — 2026-04 이전 supervisor 구현. `.gitignore` exclusion 으로 untracked 유지.

## 활성 wire-up

`.claude/settings.local.json` 에서 SessionStart / PreToolUse / PostToolUse / Stop / UserPromptSubmit 의 hook chain 으로 호출. matcher / timeout 정확한 wire-up 은 settings.local.json 참조.

## 환경 호환성

모든 hook (Python + shell) 은 동적 PROJECT_ROOT 결정 패턴을 따른다. 다른 환경 (codex/gemini machine, CI Ubuntu) 에서도 동일하게 동작:

- **Python hooks**: `pathlib.Path(__file__).resolve().parents[2]` — 파일 위치 기반 (hooks 가 `<repo>/scripts/hooks/<file>.py` 위치라는 가정)
- **Shell session hooks** (`agent-session-*.sh`, `r4-*.sh`, `worktree-stale-cleanup.sh`): `git rev-parse --path-format=absolute --git-common-dir` 기준 canonical checkout root 사용. Linked worktree 내부에서도 중앙 `.claude/locks/active-sessions.json` 과 root `.worktrees/` 를 공유.

`token-budget-track.py` 의 MEMORY_DIR 은 PROJECT_ROOT 에서 Claude Code transcoding 규칙 (`/` → `-`, ` ` → `-`) 적용한 `~/.claude/projects/<transcoded>/memory` 로 자동 결정.
