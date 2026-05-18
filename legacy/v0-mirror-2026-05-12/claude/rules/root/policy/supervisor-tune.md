# Supervisor Tune Policy — /supervisor-tune skill

## 목적

`/supervisor-tune` skill (`.claude/skills/supervisor-tune/SKILL.md`, gitignored in-place) 의 운영 정책. 누적 데이터 분석 → 분류 룰 갱신 *안* 제시. 자동 룰 변경 X (_DEPRECATED 패턴 회피). 본 plan = `~/.claude/plans/purring-snuggling-sphinx.md` Wave 2.

## 활성 상태

- skill 등록 (2026-05-07)
- 사용자 명시 invoke 시에만 활성
- supervisor.py / classify-prompt.py 직접 수정 X — 갱신 안 *제시* 만

## 학습 default 모드

**default = 옵션 C 보고만** (사용자 결정 2026-05-07).

- 옵션 C (default): 보고만 (적용 X) — 사용자 명시 발화로 적용
- 옵션 B: 안건 일부만 (multi-select)
- 옵션 A: 안 일괄 적용 (자동 commit + PR via `/wrap`) — 위험, 사용자 명시 invoke 시만

옵션 A 의 위험 = supervisor 잘못된 학습 시 회복 어려움. C default 로 사용자 review 강제.

## 데이터 source

| jsonl | 기록자 | 누적 |
|---|---|---|
| `.claude/logs/agent-routing.jsonl` | `scripts/hooks/record-agent-routing.py` (자동) | 143 records (2026-05-07) |
| `.claude/logs/plan-tier-classifications.jsonl` | `scripts/hooks/classify-prompt.py` (M1 dry-run) | 151 records |
| `.claude/logs/supervisor-tune.jsonl` | 본 skill (자동 누적) | 신규 |

모두 gitignored.

## 갭 식별 임계

| 갭 | 임계 | 안 종류 |
|---|---|---|
| dispatch >> invoke | matched_agent ≥ 10 / invoked = 0 | 정책 1 file (안내 갭) |
| tier fallback:default | > 60% (W3 적용 후 18% — 정상 범위) | classify-prompt.py 키워드 |
| intent 편향 | 한 intent > 50% | supervisor.py match_agents 룰 |
| routing fallback | > 30% | supervisor.py classify_intent 패턴 |

## 안전장치

### 1. 자동 룰 변경 절대 X

옵션 A/B 진행 시도 *재invoke 후 명시 발화* 강제. `/supervisor-tune --apply <id>` 같은 명시 모드만.

### 2. 5 가드 영역 회피

5 가드 영역 정의 = [`security-guards.md`](security-guards.md) SOT (2026-05-07 신규).

위 5 영역에 해당하는 intent 의 supervisor 분류 룰 갱신은 *사용자 결정 강제* + manual review. 본 skill 자동 룰 변경 금지.

### 3. 잘못된 학습 회복

- `.claude/logs/supervisor-tune.jsonl` 누적 — 직전 적용 안 추적
- `/supervisor-tune --history` 로 마지막 5건 조회
- 적용 안의 commit 은 `/wrap` 으로 자동 생성 → git revert 가능
- supervisor.py 본문 수정은 *사용자 명시 시만* — 본 skill 우회 X

### 4. 사용 한도

- **세션 당 max 2 invoke** — 잘못된 학습 trial 차단
- **데이터 ≥ 50 record 필요** — 적은 데이터 기반 룰 변경 회피 (현재 모두 충족)

## DEPRECATED 패턴 회피

본 skill 이 회피하는 fail 패턴:

### `_DEPRECATED_supervisor-auto-route.py` 의 자동 룰 진화

폐기 사유 = 자동 룰 변경이 잘못된 방향으로 학습 시 회복 어려움. 사용자 검토 단계 부재.

본 skill 회피 = *제안만*. 적용은 사용자 명시. 매 적용은 `/wrap` 으로 git tracked → revert 경로 보존.

## 1개월 운영 spot check

- T+7d (2026-05-14): 1회 dry-run invoke (옵션 C) → 갱신 안 한국어 흐름 spot check
- T+14d (2026-05-21): invoke 빈도 측정 + 갭 변화 측정
  - tier fallback:default 가 18% → ≤ 30% 유지 → W3 보강 효과 검증
  - 새 갭 발견 ≥ 1 → 보고만, 사용자 결정
- T+30d (2026-06-06):
  - `supervisor-tune.jsonl` 적용 비율 측정. 0% → skill deprecate / ≥ 50% → 자동 적용 모드 별 plan
  - 같은 갭 3 회 누적 보고 → 사용자 명시 결정 강제

## 결합 자산

- `.claude/skills/supervisor-tune/SKILL.md` — 본 정책 enforce 7 step workflow
- `.claude/logs/agent-routing.jsonl` — routing 데이터 (`record-agent-routing.py` 자동 누적)
- `.claude/logs/plan-tier-classifications.jsonl` — tier 데이터
- `.claude/logs/supervisor-tune.jsonl` — 본 skill 학습 누적 (신규)
- `scripts/hooks/supervisor.py` — match_agents 룰 정본 (진단 only, 수정 X)
- `scripts/hooks/classify-prompt.py` — 키워드 보강 대상 (옵션 A/B 시)
- `.claude/skills/wrap/SKILL.md` — 적용 시 commit + PR
- `.claude/rules/policy/security-guards.md` — 5 가드 영역 SOT (2026-05-07 신규)
- `.claude/rules/policy/wrap-skill.md` — `/wrap` skill 정책 (cross-ref 후속 정합)
- `~/.claude/plans/purring-snuggling-sphinx.md` — 본 plan

## History

- 2026-05-07 — 초기 룰 작성. `purring-snuggling-sphinx.md` plan Wave 2 적용. default = 옵션 C 보고만 (자동 룰 변경 X) / 데이터 ≥ 50 record 강제 / 5 가드 영역 회피 / supervisor.py 본문 수정 X (deprecated 패턴 회피).
