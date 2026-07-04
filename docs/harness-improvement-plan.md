# Agent Harness 점검 및 개선 계획

| 항목 | 값 |
|---|---|
| 작성일 | 2026-07-04 |
| 기준 버전 | v0.2.0 |
| 대상 버전 | v0.2.1 (P0 위생) → v0.3.0 (P1 구조) → v0.3.x (P2 루프) |
| 성격 | **계획 문서** — 이 문서 자체는 코드를 바꾸지 않는다. 모든 변경은 백로그 ID(P0-*/P1-*/P2-*)로 추적한다 |

---

## 0. 요약

| # | 결론 | 대응 |
|---|---|---|
| 1 | **문서가 현실을 앞질러 거짓말 중.** 존재하지 않는 테스트 스크립트 참조 15곳, 훅 수 드리프트(~25 표기 vs 실측 17), 축소 이력 미기록, 이전 프로젝트 도메인 잔재가 에이전트의 런타임 컨텍스트(README/AGENTS.md/AI_BOOTSTRAP.md)에 그대로 주입되고 있다 | **P0** — 전부 Small, 합계 반나절, v0.2.1로 출하 |
| 2 | **게이트는 강하나 피드백 루프가 없다.** 도구 경계(기둥③)는 최강인데, "에이전트 실패 → 새 자동화 규칙" 파이프라인(기둥④)은 기록만 있고 소비가 없다. 문서 드리프트를 잡는 게이트 부재는 하네스 철학의 자기 미적용 | **P1** — v0.3.0 |
| 3 | **자율 개선 루프는 조립 문제다.** 예산·시도 캡(`supervisor-goal.sh`), 분리된 그레이더 재료(`docs/benchmark/` + `core/tests/`)가 이미 존재 — autoresearch 패턴을 신규 발명 없이 조립할 수 있다 | **P2** — v0.3.x |

---

## 1. 배경 및 컨텍스트

- **현황**: v0.2.0. 4계층 구조(L1 `core/hooks/` 정본 → L2 `adapters/` → L3 `templates/` → L4 프로젝트), 실행 훅 17개 + 공용 모듈 1개(`hook_config.py`), 에이전트 5종, 스킬 4종(`supervise`/`tdd`/`diagnose`/`wrap`), 리뷰어 벤치마크 8/8 검출·오탐 0(`docs/benchmark/results.md`).
- **점검 동기**: ① 문서↔현실 드리프트 발견(§3.3), ② 외부 프레임워크 3종(§2) 학습 후 현 하네스를 같은 기준으로 재평가할 필요.
- **범위**: 점검(Part 1) + 우선순위 백로그(Part 2) + 자율 개선 루프 설계(Part 3). **이 문서는 계획만 담는다** — README 정정조차 여기서 하지 않고 P0 항목으로 남긴다.

## 2. 진단 기준 — 외부 프레임워크 3종

### 2.1 하네스 엔지니어링 4기둥
출처: 실밸개발자 "프롬프트 엔지니어링은 끝났습니다: 이제 '하네스'의 시대입니다" + 노션 보충자료 "하네스 엔지니어링 완벽 가이드" (§8).

1. **컨텍스트 파일 = 런타임 설정** — CLAUDE.md/AGENTS.md는 문서가 아니라 에이전트가 실행하는 설정 파일. 거짓이 섞이면 거짓이 실행된다.
2. **CI/CD 구조적 강제** — 규칙은 문장이 아니라 린터·구조 테스트·훅으로 시스템이 강제. 실패 시 에이전트가 스스로 수정.
3. **도구 경계** — 프롬프트는 부탁, 도구 경계는 물리적 차단.
4. **피드백 루프 + 재니터** — 실패 1건 = 새 자동화 규칙 1건. 주기적 자동 정리.

> 핵심 인용: "에이전트가 실수했을 때 프롬프트를 고치지 마세요. 그 실패가 구조적으로 반복 불가능하도록 하네스를 고치세요."

### 2.2 루프 엔지니어링 6요소
출처: 실밸개발자 "루프 엔지니어링 — '프롬프트하는 나'를 시스템으로 대체하는 법" (Addy Osmani 정리 기반). 하네스가 **한 번의 실행**을 보장한다면, 루프는 그 위의 아우터 루프(깨우고·시키고·검증하고·기록) — human **on** the loop.

① 자동화/트리거 ② 검증 가능한 완료 조건 ③ 워크트리 격리 ④ 예산 가드레일 ⑤ **분리된 그레이더**(자기 채점 금지) ⑥ 로깅. ②·④가 없으면 "토큰 퍼니스"(돈만 태우는 기계)가 된다.

> 핵심 인용: "그레이더는 절대 자기 채점이 아니어야 한다. 테스트가 통과해도 수동 검증에서 깨질 수 있다 — 검증은 계층으로."

### 2.3 karpathy/autoresearch 역학
출처: github.com/karpathy/autoresearch (§8). 루프 엔지니어링의 실전 최소 구현.

- `program.md` = **인간이 편집하는 "연구 조직 코드"**(경량 스킬) / `train.py` = 에이전트가 편집하는 유일한 표면 / `prepare.py` = 읽기 전용 하네스.
- 고정 예산(5분) + 단일 스칼라 지표(`val_bpb`) → 모든 실험이 비교 가능.
- 루프: 아이디어 → 편집 → commit → 실행 → 지표 grep → 개선이면 keep(브랜치 전진)/아니면 `git reset` → `results.tsv`(untracked) 기록.
- 브랜치 격리(`autoresearch/<tag>`), 크래시 정책(사소하면 1회 수정, 근본 결함이면 discard), **단순성 기준**(개선 폭 vs 복잡도 비용 저울질).

---

## 3. Part 1 — 현황 점검 스코어카드

### 3.1 하네스 4기둥 매핑

| 기둥 | 현재 구현 (파일) | 상태 | 증거·격차 → 백로그 |
|---|---|---|---|
| ① 컨텍스트 파일 | `templates/{CLAUDE,AGENTS,GEMINI}.md.template`, `rules/`, `AI_BOOTSTRAP.md`, `agents/master-registry.json` | **부분** | 구조는 우수하나 무결성 파손 — 격차 #1(팬텀 테스트 참조)·#2(도메인 잔재)·#3(훅 수 드리프트)·#6(plans 경로 이중 진실)이 에이전트에게 거짓 런타임 설정을 주입 → P0-1~P0-5 |
| ② CI/CD 구조적 강제 | `.github/workflows/ci.yml`(registry model-drift guard), `core/git-hooks/`(gitleaks pre-commit/pre-push), `core/tests/sanitize-audit.sh` | **부분** | 레지스트리 드리프트는 잡지만 **문서 드리프트 게이트 부재** — 격차 #1·#3·#4가 CI를 통과해 옴. 로컬 sanitize-audit은 상시 FAIL(격차 #8)로 신뢰 상실. "실패→규칙" 철학의 자기 미적용 → P0-7, P1-1, P1-2 |
| ③ 도구 경계 | `pre-tool-guard.sh`, `agent-proxy.sh`, `secret-content-scan.py`, r4-mutex 3종, `circuit-breaker.py`, 에이전트별 read-only tool set, `context-mode-guard.sh` | **충족 (최강)** | 유일 약점: `supervisor.py` 스텁(격차 #5) — 의도 라우팅 경계가 스킬 프롬프트(부탁) 수준에 머묾 → P1-4 |
| ④ 피드백 루프 + 재니터 | `session-quality-gate.py`(Stop), `circuit-breaker.py`, `supervisor-goal-audit.sh` | **미비 (최약)** | `supervisor.jsonl`에 기록만 하고 아무도 읽지 않음. 재니터·주기 정리·"실패→새 규칙" 파이프라인 전무 → P1-5, Part 3 전체 |

보조 개념(노션 의사코드 대비): 라우터=`plan-gate.py` 4-tier **충족**(supervisor 라우팅만 반쪽) · 유한 재시도=`circuit-breaker.py` **충족** · writer≠reviewer=에이전트 역할 분리+벤치마크 **충족** · 컨텍스트 매니저/GC=**부재**(장기 과제, 이번 백로그 범위 외).

### 3.2 루프 6요소 매핑

| # | 요소 | 현재 | 상태 | 격차 → 백로그 |
|---|---|---|---|---|
| 1 | 자동화/트리거 | `/supervise` 수동 디스패치 | **부분** | 스케줄/웨이크 없음. P2에서도 **의도적으로 수동 유지**(human on the loop) |
| 2 | 검증 가능한 완료 조건 | `supervisor-goal-audit.sh score`, quality-gate | **부분** | wave 완료 조건이 프롬프트 규율에 의존 → P2-2(스칼라 지표) |
| 3 | 워크트리 격리 | `core/infra/agent-session.sh`, r4-mutex, file-mutex | **충족** | — |
| 4 | 예산 가드레일 | `supervisor-goal.sh init <slug> <N> [<budget>]` | **부분** | 인프라 존재, 훅 수준 강제·토큰 계측 없음 → P2-4 |
| 5 | 분리된 그레이더 | `core/tests/` 4종 + `docs/benchmark/ground-truth.md` | **부분** | 진짜 그레이더이나 커버리지 협소 — per-hook 테스트가 문서에만 존재(격차 #1) → P1-3, P2-2 |
| 6 | 로깅 | `.agent/logs/supervisor.jsonl`, session store | **부분** | 실행 원장(results.tsv 상당) 부재, 로그 소비 부재 → P1-5, P2-3 |

### 3.3 확인된 격차 7건 (검증 명령 병기 — 2026-07-04 실측)

| # | 격차 | 검증 명령 → 실측 결과 |
|---|---|---|
| 1 | **팬텀 테스트 참조 15곳** — `README.md:303-308`, `AGENTS.md:51-54·116-118·124`, `docs/architecture.md:127-129`가 `core/tests/adapter-smoke/<ai>/run.sh`, `cross-ai-parity.sh`, `verify-all.sh`, `bootstrap-test.sh`를 지시하나 전부 미존재 | `grep -rn 'adapter-smoke\|cross-ai-parity\|verify-all\|bootstrap-test' README.md AGENTS.md docs/architecture.md` → 15건 매치, 대상 파일 0개 |
| 2 | **도메인 잔재** — `AI_BOOTSTRAP.md:35`(Step 5 항목 2)의 Guarded Domains 목록에 이전 프로젝트 특화 항목 포함. 도메인 중립 원칙(`rules/policy/security-guards.md`의 일반 5영역) 위반. 해당 용어는 이 문서에 재기재하지 않는다 — 원문 참조 | `sed -n '35p' AI_BOOTSTRAP.md` |
| 3 | **훅 수 드리프트** — `README.md:223`, `CHANGELOG.md:36`이 "~25 portable hooks" 표기 | `find core/hooks -maxdepth 1 -type f -perm -u+x ! -name README.md \| wc -l` → **17** (+ 비실행 공용 모듈 `hook_config.py` 1개) |
| 4 | **축소 이력 미기록** — `CHANGELOG.md:40-42`(0.1.0)는 에이전트 10종·스킬 16종·codex-skills를 나열하나 현재 5종/4종. 0.2.0에 Removed 기록 없음 | `ls agents/*.md \| wc -l` → 5, `ls -d skills/*/ \| wc -l` → 4 |
| 5 | **supervisor.py 스텁** — 헤더 자체가 "Supervisor stub". `skills/supervise/SKILL.md`의 풍부한 계약 대비 미구현 | `head -5 core/hooks/supervisor.py` |
| 6 | **plans 경로 이중 진실** — `skills/supervise/SKILL.md`·`core/infra/supervisor-goal-audit.sh`는 `~/.agent/plans`(env `AGENT_PLANS_DIR`), `core/hooks/secret-content-scan.py:60` 주석은 `~/.claude/plans` | `grep -rn '\.claude/plans' core/ skills/ --exclude-dir=legacy` |
| 7 | **더티 트리** — ` M gitleaks.toml`, `?? .omc/`, `?? CLAUDE.md`(개인 경로 포함 루트 파일, 배포 템플릿 아님) | `git status --short` |
| 8 | **sanitize-audit 스캔 범위 부정합** — `.github/workflows/ci.yml:100`의 CI 잡은 grep 패턴 리터럴을 담고 있고 CI의 git grep은 자기 자신을 제외하지만, 로컬 `sanitize-audit.sh`에는 ci.yml 제외 규칙이 없어 **클린 트리에서도 로컬 감사가 항상 FAIL**. `.claude/locks/` 런타임 아티팩트도 스캔에 걸림 (2026-07-04 실측) | `bash core/tests/sanitize-audit.sh` → FAIL: ci.yml, .claude/locks/active-sessions.json |

---

## 4. Part 2 — 개선 백로그

항목 형식: `ID / 작업 / 근거 / 완료 조건(기계 검증) / 규모(S≤1h, M=반나절, L=1일+)`.

### 4.1 P0 — 위생 (v0.2.1, 7건 전부 S, 합계 반나절)

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P0-1 | README/AGENTS.md/architecture.md의 테스트 참조를 실존 4개(`sanitize-audit`/`adapter-parity`/`hook-config-test`/`post-commit-autosync-test`)로 정정. 누락 스크립트 신설은 P1로 이관 | 격차 #1 | 격차 #1의 grep 명령 0건(legacy/ 제외) 또는 참조 경로 전부 실존 | S |
| P0-2 | AI_BOOTSTRAP.md Step 5 도메인 중립화 — 특화 항목 제거, `hook-config.yml risk_areas` 참조로 교체 + **`sanitize-audit.sh` 패턴 목록에 해당 용어 추가**("실패→규칙" 실천) | 격차 #2 | `bash core/tests/sanitize-audit.sh` clean + 패턴 목록에 신규 항목 존재 | S |
| P0-3 | 훅 수 표기 정정 — 정의 고정: "실행 훅 17 + 공용 모듈 1". README/CHANGELOG 수정, 계수 명령 병기 | 격차 #3 | 문서 수치 = 격차 #3 find 명령 출력 | S |
| P0-4 | CHANGELOG Unreleased에 `Removed: agents 10→5, skills 16→4` 축소 이력 기록 | 격차 #4 | CHANGELOG Removed 섹션 존재, 수치 = 격차 #4 ls 명령 출력 | S |
| P0-5 | plans 경로 단일화 — 정본 `~/.agent/plans`(AI-불가지 원칙; adapter가 도구별 경로 번역). `secret-content-scan.py:60` 주석 수정 | 격차 #6 | `grep -rn '\.claude/plans' core/ skills/ --exclude-dir=legacy` 0건 | S |
| P0-6 | 작업 트리 정화 — 루트 `CLAUDE.md`(개인 경로) .gitignore 처리 또는 템플릿 흡수, `gitleaks.toml` 변경 검토 후 커밋/원복, `.omc/` ignore | 격차 #7 | `git status --short` 출력 없음 | S |
| P0-7 | sanitize-audit 스캔 범위 정합 — `ci.yml` 자기 제외 추가(또는 CI 잡의 패턴도 런타임 토큰 조립로 전환), `.claude/locks/` 등 런타임 아티팩트 제외 | 격차 #8 | 클린 워킹 트리에서 `bash core/tests/sanitize-audit.sh` PASS | S |

### 4.2 P1 — 구조 (v0.3.0)

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P1-1 | **doc-reality 게이트** `core/tests/doc-reality-test.sh` 신설 — 문서 내 참조 경로 실존 검증 + 수치 클레임(훅/에이전트/스킬 수) 실측 대조. `ci.yml`에 잡 추가. 격차 #1·#3·#4 재발 방지의 규칙화(기둥②의 자기 적용) | 기둥② | P0 이전 README에 FAIL, P0 이후 PASS 데모; CI 등록 | M |
| P1-2 | `core/tests/verify-all.sh` 실구현 — 실존 테스트 4종 + doc-reality + gitleaks 묶음 러너(README Quick commands 약속 이행) | 격차 #1 | `bash core/tests/verify-all.sh` exit 0, 하위 테스트별 pass/fail 라인 출력 | S–M |
| P1-3 | per-hook 단위 테스트 ≥4개(`pre-tool-guard`, `secret-content-scan`, `plan-gate`, `tdd-guard` 우선) — synthetic event JSON → decision JSON 픽스처. **P2 그레이더 확장의 선행 조건** | 루프 요소⑤ | `core/tests/<hook>-test.sh` ≥4개 존재, verify-all에 포함 | M–L |
| P1-4 | `supervisor.py` 스텁 해소 — master-registry `matches.keywords` 기반 최소 라우팅(매칭 telemetry 기록, feature급 의도에 specialist 미지정 시 `ask`) | 격차 #5 | synthetic prompt 이벤트 테스트 통과, `supervisor.jsonl`에 매칭 기록 | M |
| P1-5 | 텔레메트리 소비(기둥④ 1단계 재니터) — `core/infra/telemetry-digest.sh`: `supervisor.jsonl` deny/ask 통계 → 규칙 후보 리포트 | 기둥④ | 샘플 로그 입력 → 요약 출력 검증 | M |
| P1-6 | `cross-ai-parity.sh` 실구현 — `adapter-parity.sh` 확장: 동일 논리 이벤트 → 3 adapter → 동일 decision | 격차 #1 | README Verification 절 명령이 실제 통과 | M |

### 4.3 P2 — 자율 개선 루프 (v0.3.x, §5 설계의 구현)

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P2-1 | `skills/harness-loop/SKILL.md` 작성 — §5의 루프 규정(program.md 상당, 인간만 편집) | §5 | 스킬 로드 후 드라이런 1회에서 §5 절차 9단계가 순서대로 로그에 남음 | M |
| P2-2 | `core/tests/grade.sh` 작성 — GATE(기존 테스트 4종+gitleaks) + 벤치마크 리플레이 → `harness_score: X.Y` 단일 라인 출력 | 루프 요소②⑤ | 현행 코드로 실행 시 `harness_score: 8.0` 재현(기준선), GATE 실패 시 0.0 | M |
| P2-3 | 결과 원장 + 브랜치 규약 — `.agent/loop/results.tsv`(untracked, 5열: commit/harness_score/duration_s/status/description≤80자), 브랜치 `harness-loop/<tag>` | 루프 요소⑥ | 드라이런 후 results.tsv에 keep/discard 행 기록 확인 | S |
| P2-4 | 예산·타임아웃 연동 — `supervisor-goal.sh init` 재사용(세션당 시도 N=5), 런당 10분 타임아웃 kill→`timeout`·discard, GATE 연속 2회 실패 시 circuit-breaker 중단 | 루프 요소④ | 강제 실패 시나리오에서 5회 후 정지 + 원장에 기록 | S |
| P2-5 | 파일럿 3회 + 회고 — 기본 미션(리뷰어 프롬프트 쌍)으로 3세션 실행, keep율·비용·오탐 회고를 `docs/benchmark/`에 추가 | 검증 계층 | 회고 문서 존재 + results.tsv ≥3 세션분 | M |

---

## 5. Part 3 — `/harness-loop` 자율 개선 루프 설계 (단일 권고안)

autoresearch 패턴을 이 레포 자신에게 적용한다: **에이전트가 밤새 하네스(우선 리뷰어 프롬프트)를 실험적으로 개선하고, 분리된 그레이더가 채점하고, 사람은 PR만 리뷰한다.**

### 5.1 대응표

| autoresearch | harness-loop 대응물 | 설계 근거 |
|---|---|---|
| `program.md` (인간 편집 규정) | `skills/harness-loop/SKILL.md` — **인간만 편집**, 루프 규칙·금지사항 수록, 경량 유지 | 스킬이 이 레포의 관례적 "프로그램" 단위 |
| `train.py` (에이전트 편집 표면) | **미션당 TARGET 1개 선언.** 기본 미션: 리뷰어 프롬프트 쌍(`agents/code-reviewer.md` + `agents/security-reviewer.md`). 훅 표면 미션은 해당 per-hook 테스트(P1-3) 존재 시에만 허용 | 그레이더(벤치마크)가 정확히 리뷰어를 측정하므로 신호 직결. **TARGET 밖 diff는 그레이더가 자동 discard**(git diff 검사) = 물리적 경계(기둥③) |
| 고정 5분 예산 → 비교 가능성 | **고정 결함 세트**(`docs/benchmark/ground-truth.md` 8건) + 고정 입력 diff | 시간이 아니라 입력 고정으로 런 간 비교성 확보 |
| `val_bpb` (단일 스칼라) | `core/tests/grade.sh` 출력 **`harness_score: X.Y`** 한 줄. 산식: GATE(sanitize-audit·adapter-parity·hook-config-test·post-commit-autosync·gitleaks 전부 통과 못하면 **0**) 통과 시 `score = 검출수 − 0.5×오탐수` (만점 8.0) | 회귀 바닥(GATE)과 개선 신호(METRIC) 분리 = 계층 검증. 현 기준선 8.0/오탐 0이므로 초기 미션은 "기준선 유지 + 프롬프트 축소(단순화 승리)" 또는 ground-truth 확장(추가 결함 2건 → 만점 10.0) |
| 분리된 그레이더 | `grade.sh` + `core/tests/`는 루프 에이전트 **편집 금지**(TARGET-외 diff discard 규칙으로 구조 보장). 워커는 pass 여부를 판단하지 않고 `grep '^harness_score:' run.log`만 수행 | 자기 채점 금지(루프 요소⑤) |
| 실험 루프 | §5.2 절차 | 그대로 이식 |
| `results.tsv` (untracked) | `.agent/loop/results.tsv` — 5열: `commit / harness_score / duration_s / status(keep·discard·crash·timeout) / description(≤80자)` | 로깅(요소⑥) |
| 예산·NEVER STOP 대체 | **수동 트리거만**(`/harness-loop <mission>`, cron 없음 — human on the loop). `supervisor-goal.sh init` 재사용: 세션당 시도 N=5, 런당 타임아웃 10분 kill→timeout·discard, GATE 연속 2회 실패 → circuit-breaker 연동 중단 | 기존 goal-mode 인프라 재사용, "토큰 퍼니스" 방지(요소④) |
| 크래시 정책 | 사소(문법 오류) 1회 수정 재시도, 근본 결함이면 discard + `status=crash` | 원문 정책 축약 |
| 단순성 기준 | 점수 동률 시 **diff가 작아지는 변경만 keep**; +100줄 초과 diff는 검출 +1 이상일 때만 keep | 복잡도 비용 명문화 |
| 병합 | advance된 브랜치 → `/wrap`(gitleaks+risk gate) → PR → **인간 리뷰 필수, auto-merge 금지** | "테스트 통과 ≠ 실제 동작" 전훈(계층 검증) |

### 5.2 루프 절차 (SKILL.md에 수록될 정본)

브랜치 `harness-loop/<tag>`에서 반복:

1. git 상태 확인(현재 브랜치/커밋)
2. 개선 아이디어 1건 선택 → **TARGET 파일만** 편집
3. `git commit`
4. `bash core/tests/grade.sh > run.log 2>&1` (출력 리다이렉트 — 컨텍스트 오염 금지)
5. `grep '^harness_score:' run.log` — 빈 출력이면 크래시 → `tail -n 50 run.log`로 원인 확인, 크래시 정책 적용
6. TARGET-외 diff 검사에 걸리면 무조건 discard
7. `.agent/loop/results.tsv`에 기록 (results.tsv는 커밋하지 않음)
8. 점수 개선(또는 동률+단순화)이면 keep — 브랜치 전진 / 아니면 `git reset --hard`
9. 시도 캡(N=5)·타임아웃·circuit-breaker 조건 확인 후 반복 또는 종료 → 종료 시 요약 보고 + `/wrap` 제안

### 5.3 비용·선행 조건

- **런당 비용**: `grade.sh`의 벤치마크 리플레이 = 리뷰어 에이전트 1회 호출(런당 수 분·수만 토큰) — 세션당 5회 캡의 산정 근거.
- **선행 조건**: P0 전부(에이전트 컨텍스트의 거짓 제거 — 거짓 설정 위에서 루프를 돌리면 거짓을 학습한다), P1-2(GATE 러너), 훅 표면 미션은 P1-3.

---

## 6. 실행 순서 및 마일스톤

```
P0-1 ~ P0-6 (일괄, 반나절)          → v0.2.1 태그
  └→ P1-1 doc-reality 게이트 · P1-2 verify-all   (P0 완료가 PASS 전제)
       └→ P1-3 per-hook 테스트 · P1-4 supervisor · P1-5 텔레메트리 · P1-6 parity → v0.3.0
            └→ P2-1 ~ P2-5 (§5 조립)             → v0.3.x
```

- 각 마일스톤 커밋은 conventional commit(`docs:`/`fix:`/`feat:`/`test:`) + CHANGELOG 갱신.
- P2 착수 전 게이트: `bash core/tests/verify-all.sh` green + doc-reality green.

## 7. 이 문서 자체의 검증

커밋 전 수행(전부 레포 루트 기준):

1. §3.3 표의 각 검증 명령을 실행해 실측 결과 열과 대조 — 훅 17, 테스트 4, 에이전트 5, 스킬 4.
2. `bash core/tests/sanitize-audit.sh` — **이 문서가 오염 파일 목록에 나타나지 않을 것.** (전체 감사는 격차 #8의 기존 원인으로 P0-7 완료 전까지 FAIL이 정상)
3. `gitleaks detect --no-git --source docs/ --config gitleaks.toml`.
4. 백로그 항목 수 검증: `grep -cE '^\| P[0-2]-[0-9]+' docs/harness-improvement-plan.md` = **18** (P0 7 + P1 6 + P2 5), 각 행에 완료 조건 존재.
5. 스코어카드(§3.1·§3.2)의 격차 행 ↔ 백로그 ID 상호 링크 고아 0건 (모든 "부분/미비" 행에 P* 링크 존재).
6. AGENTS.md 규약 준수 — 도메인 중립 언어, 커밋 메시지 `docs(plan): add harness improvement plan`.

## 8. 참고 자료

| 자료 | 위치 |
|---|---|
| 영상: "프롬프트 엔지니어링은 끝났습니다: 이제 '하네스'의 시대입니다" (실밸개발자) | youtu.be/6gvnDSAcZww |
| 영상: "루프 엔지니어링 — '프롬프트하는 나'를 시스템으로 대체하는 법" (실밸개발자) | youtu.be/A7gwGNsL6y4 |
| 노션: 하네스 엔지니어링 완벽 가이드 (4기둥·의사코드 보충자료) | raspy-roll-970.notion.site/AI-333f7725c9d98147957afad16db3b655 |
| karpathy/autoresearch (README + program.md) | github.com/karpathy/autoresearch — 로컬 참조 클론: 드라이브 `_repos/reference/autoresearch` (`repos.yaml`의 `repoId: karpathy/autoresearch`, 클론 확인 2026-07-04) |
