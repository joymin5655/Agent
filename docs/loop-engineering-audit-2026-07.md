# Loop Engineering 설계 감사

| 항목 | 값 |
|---|---|
| 작성일 | 2026-07-11 |
| 기준 버전 | v0.2.6 |
| 성격 | **감사 + 판정 문서** — 코드를 바꾸지 않는다. 발굴 작업은 LE-* 백로그(`harness-improvement-plan.md` §4.12)로 추적 |
| 기준 | [`concepts/loop-engineering.md`](concepts/loop-engineering.md)의 15항목 설계 체크리스트 (출처: Addy Osmani *Loop Engineering* + cobusgreyling/loop-engineering, 2026-07 접근) |

---

## 0. 요약

- 하네스의 척추(maker/checker 분리 · bounded iteration · durable state · 런 로그)는 이미 루프 엔지니어링 컨센서스와 정합 — **15항목 중 meets 6 / partial 6 / missing 3**.
- 최대 갭은 **신뢰의 단위**: 준비도 L0→L3 사다리는 "루프/프로젝트 단위로 신뢰를 점진 승급"을 요구하는데, 하네스의 자동화 노브는 전부 세션-전역 env-var였다. per-project trust tier(`customization.md` § Trust tiers)가 1단계 응답.
- 나머지 갭(전역 비용 kill switch, anti-flake 규율, human synthesis cadence)은 LE-* 백로그로 등재만 하고 이 감사에서는 구현하지 않는다.

## 1. 15항목 판정표

| # | 기준 | 판정 | 근거 (경로) | 갭 → 백로그 |
|---|---|---|---|---|
| 1 | 명시 목표 + non-goals | partial | `/spec`이 spec.md에 목표를 강제(`skills/spec/SKILL.md`); non-goals 섹션은 관례일 뿐 필수 아님 | 소형 — spec 템플릿에 Non-goals 상례화 (LE 미등재, spec 개정 시 편승) |
| 2 | 스코프된 작업 표면 | meets | NEVER_ALLOW 스크린(`core/hooks/plan-scope-allow.py`), 리스크 영역 5종(`rules/policy/security-guards.md`), R4 자원 mutex | — |
| 3 | 지속 케이던스 | partial | goal-mode는 세션 재시작 생존(SQLite, `core/infra/supervisor-goal.sh`); 스케줄러 자체(cron/automations)는 런타임 소관으로 하네스 밖 | 의도적 — 하네스는 런타임-불가지론, 스케줄링은 어댑터 위 |
| 4 | 외부 durable 상태 | meets | `.agent/locks/goal-state.db`(supervisor_goals), 실행 원장 `.agent/plans/<slug>/RECORD.md`(F-2), 매 완료 시 기계 생성 | — |
| 5 | maker/checker 분리 | meets | supervise 리뷰 레인 + `/verify-completion` refute-by-default fresh-spawn(`skills/verify-completion/SKILL.md`) + 리뷰어/verifier read-only 도구셋 CI 가드(`core/tests/registry-drift.sh` 체크 5) | — |
| 6 | 반복 상한 + 에스컬레이션 | meets | audit FAIL → 자동 재시도 금지·사용자 핸드오프(`skills/supervise/SKILL.md`), goal-mode 토큰 예산 캡 | — |
| 7 | 읽히는 에스컬레이션 | partial | FAIL 핸드오프·graceful-wrap 스텁은 있음; "결정 필요할 때만 알림" 규율은 미명문(notification fatigue 방어 부재) | LE-7에 편승 |
| 8 | 최소권한 커넥터 | partial | 리뷰·검증 에이전트 read-only 도구셋(기계 가드), prod DB/배포 MCP ask(`hooks/hooks.json` supabase 매처); MCP write-scope 점진 승급 개념은 없음 | LE-2 |
| 9 | allowlist 없는 auto-merge 금지 | partial | `--auto-merge`는 명시 opt-in 플래그(기본 수동 push); 경로 allowlist·티어 게이팅은 없음 | LE-2 |
| 10 | 병렬 작업 격리 | meets | `concepts/multi-session-worktree.md` + R4 파일 mutex 훅(`core/hooks/r4-*.sh`) | — |
| 11 | 단계 승급 L0→L3 | **missing → 착수** | per-project/per-loop 신뢰 계층 부재 — 자동화 노브 전부 세션-전역 env-var. trust tier(personal/collab)가 L2↔L1 매핑의 1단계 | trust-tier PR (본 감사 동반), 자동 래칫은 LE-4 |
| 12 | 런 로그 관측성 | meets | jsonl 싱크(`.agent/logs/*.jsonl`) + `core/infra/telemetry-digest.sh` + RECORD.md 원장 | — |
| 13 | 비용 상한 + kill switch | partial | goal-mode 토큰 예산은 있음(`supervisor-goal.sh track-tokens`); 비-goal-mode·전역 kill switch는 없음 | LE-3 |
| 14 | anti-flake 규율 | **missing** | completion_tests 실패는 일괄 abort — flake 분류/격리(quarantine) 개념 없음 | LE-6 |
| 15 | human synthesis cadence | **missing** | 루프가 쉬핑한 diff를 사람이 주기적으로 읽는 장치 없음(comprehension debt 무방비) | LE-7 |

## 2. 판정 원칙 유지 사항

- **하드 세이프가드는 어느 신뢰 티어에서도 불변**: 리스크 영역 abort · R4 mutex · gitleaks · 테스트 실패 abort. 티어는 *프롬프트 마찰*을 조정할 뿐 *안전 게이트*를 조정하지 않는다.
- 약화 토글 env-only 원칙(`templates/hook-config.yml.template` NOTE)은 trust-tier 설계에서도 보존 — personal 승격의 durable 소스는 워크스페이스 밖 사용자측 파일만.

## 3. 이 문서 자체의 검증

- 판정표 경로 전수는 작성 시점 repo 실측 (`core/hooks/plan-scope-allow.py`, `core/infra/supervisor-goal.sh`, `core/tests/registry-drift.sh` 등 존재 확인).
- 외부 기준의 원문은 세션 스크래치에 보존 후 증류 — repo에는 체크리스트(개념 문서)만 반입, 원문 복제 없음.
- missing 3건 중 구현에 착수한 것은 #11(trust tier) 1건뿐이며, 나머지는 백로그 등재가 이 문서의 완료 조건.
