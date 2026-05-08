# Supervisor Delegation Policy — /supervise skill

## 목적

`/supervise` skill (`.claude/skills/supervise/SKILL.md`, gitignored in-place) 의 운영 정책. plan 파일 → supervisor 위임 → 자동 진행. _DEPRECATED 자동 차단 패턴 (`scripts/hooks/_DEPRECATED_supervisor-auto-route.py` + `_DEPRECATED_supervisor-enforcer.py`) 회피. 본 plan = `~/.claude/plans/purring-snuggling-sphinx.md` Wave 1.

## 활성 상태

- skill 등록 (2026-05-07)
- supervisor.py 본문은 **수정 X** — 위임 진입점 / 호출자 역할만 (deprecated 차단 패턴 회피)
- 사용자 명시 invoke 시에만 활성 (자동 진입 X)

## 위임 default 모드

**default = 옵션 A (full auto)** (사용자 결정 2026-05-07).

- 옵션 A (default): 모든 Wave 자동 진행 + 매 Wave 끝 commit + push prompt + PR via `/wrap`
- 옵션 B: Wave 1 만 진행, 나머지 deferral
- 옵션 C: dispatch 안 보고 후 사용자 직접 진행 (advisory only)

옵션 A 진행 중 6 안전장치 강제 — *어느 단계에서든* 트리거 시 즉시 중단.

## 6 안전장치 (CRITICAL — 자동 중단)

| # | 트리거 | 즉시 중단 동작 |
|---|---|---|
| 1 | 사용자 발화 "stop" / "잠깐" / "멈춰" / "취소" | 현재 step commit (있으면) + broadcast `blocked` + 보고 |
| 2 | 5 가드 영역 검출 | 자동 abort + 사용자 명시 확인 강제 |
| 3 | R4.1 file mutex 차단 (다른 session 이 같은 file 작업 중) | broadcast `blocked` --to + 사용자 결정 대기 |
| 4 | gitleaks fail (Layer 1) | abort + 위반 path 보고 |
| 5 | test fail | abort + fail log 보고 |
| 6 | type check fail | abort + error 보고 |

## 5 가드 영역

정의 + 차단 매핑 정본 = [`security-guards.md`](security-guards.md) (SOT, 2026-05-07 신규).

5 가드 영역 검출 시 본 skill 옵션 C (advisory) 강제 전환.

## DEPRECATED 패턴 회피

본 skill 이 회피하는 *과거 fail 패턴*:

### `_DEPRECATED_supervisor-auto-route.py` (UserPromptSubmit hook v5)

폐기 사유 = **plan-gate 강제 차단** + 자동 라우팅이 너무 강했음. 사용자가 의도하지 않은 plan 생성 단계 강제 진입.

회피 = 본 skill 은 *명시 invoke 만*. UserPromptSubmit hook 자동 호출 X. plan 부재 시 사용자에게 묻기만 하고 강제 X.

### `_DEPRECATED_supervisor-enforcer.py` (PreToolUse Write|Edit)

폐기 사유 = FEATURE 의도 + plan 부재 시 Write/Edit *자동 차단*. plan-gate flag (`/tmp/airlens-plan-approved`) 가 부재하면 모든 Write 차단되어 사용자 워크플로우 마비.

회피 = 본 skill 은 advisory + AskUserQuestion. Write 차단 hook X. supervisor.py PreToolUse Write|Edit 는 기존 dispatch 검증 (R7.1 hook stack #2) 만 — 변경 X.

## DISPATCHED_FLAG 통합

`/tmp/airlens-dispatched-agents` (cumulative — 2026-05-01 fix 정합):

- 같은 Wave 내 같은 specialist 반복 dispatch 회피
- `/supervise` 진행 중 누적 update (Step 7)
- 매 prompt reset 안 함 (cumulative learning)

## 사용 한도

- **세션 당 max 3 invoke** — 자동 진행이 잘못된 학습 흔적 시 차단 (잘못된 학습 회복 가능성 보존)
- **plan 당 max 1 진행** — 같은 plan 동시 2 worktree spawn 회피 (R4.1 + R6 — 다른 브랜치 침범 금지)

## 1개월 운영 spot check

- T+7d (2026-05-14): 1회 dry-run invoke (작은 plan, 옵션 C advisory) → dispatch 안 한국어 흐름 자연스러운지
- T+14d (2026-05-21): invoke 빈도 측정 (`agent-routing.jsonl` grep `supervise`)
  - 0 회 → deprecate 검토
  - ≥ 5 회 → W4 supervisor 자동 spawn 결정 trigger
- T+30d (2026-06-06):
  - 6 안전장치 트리거 ≥ 1건 → 정책 강화
  - 옵션 A 진행 후 사용자 stop 발화 ≥ 3 → default 옵션 B 로 전환 검토
  - DISPATCHED_FLAG 누적 사용량 측정

## 결합 자산

- `.claude/skills/supervise/SKILL.md` — 본 정책 enforce 8 step workflow
- `scripts/hooks/supervisor.py` — match_agents / select_workflow 룰 정본 (수정 X)
- `/tmp/airlens-dispatched-agents` — cumulative dispatch
- `scripts/hooks/r4-file-mutex-check.sh` — R4.1 mutex
- `scripts/infra/agent-session.sh` — broadcast / dashboard / start
- `.claude/skills/wrap/SKILL.md` — commit + PR 자동
- `.claude/rules/multi-agent-worktree.md §R14` — 5 deferral 워크플로우
- `.claude/rules/policy/security-guards.md` — 5 가드 영역 SOT (2026-05-07 신규)
- `.claude/rules/policy/wrap-skill.md` — `/wrap` skill 정책 (5 가드 cross-ref 후속 정합)
- `~/.claude/plans/purring-snuggling-sphinx.md` — 본 plan

## History

- 2026-05-07 — 초기 룰 작성. `purring-snuggling-sphinx.md` plan Wave 1 적용. default = 옵션 A full auto / 6 안전장치 강제 / 5 가드 영원히 회피 / supervisor.py 수정 X (deprecated 패턴 회피).
