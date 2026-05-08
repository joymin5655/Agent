# Deprecated hooks (archive)

본 디렉터리는 *역사 기록* 만 — `.claude/settings.local.json` 등록 절대 금지.

## 보관 hook

각 file 자체는 `.gitignore` 의 `scripts/hooks/_archive/_DEPRECATED_*` 로 ignore (history 보존 목적, repo 노출 X).

| File | Size | 폐기 시점 |
|---|---|---|
| `_DEPRECATED_supervisor-auto-route.py` | 14.3K | UserPromptSubmit v5 |
| `_DEPRECATED_supervisor-enforcer.py` | 4.2K | PreToolUse `Write\|Edit` |
| `_DEPRECATED_agent-dispatch-enforcer.py` | 3.5K | PreToolUse `Write\|Edit` |

## 폐기 사유 (요약)

1. **`_DEPRECATED_supervisor-auto-route.py`** — UserPromptSubmit v5. plan-gate (`/tmp/airlens-plan-approved`) 강제 차단이 너무 강함. 사용자가 의도하지 않은 plan 생성 단계 강제 진입.

2. **`_DEPRECATED_supervisor-enforcer.py`** — PreToolUse `Write|Edit`. FEATURE 의도 + plan 부재 시 *모든 Write/Edit 자동 차단*. plan-gate flag 부재 시 워크플로우 마비.

3. **`_DEPRECATED_agent-dispatch-enforcer.py`** — PreToolUse `Write|Edit`. required-agents 부재 시 자동 차단.

상세 = `.claude/rules/policy/supervisor-delegation.md` §"DEPRECATED 패턴 회피".

## 절대 회피 패턴

`/supervise` + `/supervisor-tune` 신규 skill 은 본 폐기 패턴을 *명시적 회피*:

- 자동 차단 hook X — advisory + AskUserQuestion 만
- plan-gate flag X — 사용자 명시 발화로만 적용
- supervisor.py 본문 수정 X — 진입점 / 호출자 역할만

복원 시도 시 (실수든 의도든):
- `.claude/rules/policy/supervisor-delegation.md` History 참조
- `~/.claude/plans/purring-snuggling-sphinx.md` plan 참조
- 본 README 의 폐기 사유 재확인

## History

- 2026-05-07 — `scripts/hooks/_DEPRECATED_*` → 본 `_archive/` 로 이동. `.gitignore` 갱신 (`_archive/_DEPRECATED_*`). `.claude/settings.local.json` reference 부재 검증 완료.
