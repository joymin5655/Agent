# Agent Harness 점검 및 개선 계획

| 항목 | 값 |
|---|---|
| 작성일 | 2026-07-04 |
| 기준 버전 | v0.2.0 |
| 대상 버전 | v0.2.1 (P0 위생) → v0.3.0 (P1 구조) → v0.3.x (P2 루프) |
| 성격 | **계획 문서** — 이 문서 자체는 코드를 바꾸지 않는다. 모든 변경은 백로그 ID(P0-*/P1-*/P2-*/H-*/W-*/A-*/G-*)로 추적한다 |

---

## 0. 요약

| # | 결론 | 대응 |
|---|---|---|
| 1 | **문서가 현실을 앞질러 거짓말 중.** 존재하지 않는 테스트 스크립트 참조 15곳, 훅 수 드리프트(~25 표기 vs 실측 17), 축소 이력 미기록, 이전 프로젝트 도메인 잔재가 에이전트의 런타임 컨텍스트(README/AGENTS.md/AI_BOOTSTRAP.md)에 그대로 주입되고 있다 | **P0** — 전부 Small, 합계 반나절, v0.2.1로 출하 |
| 2 | **게이트는 강하나 피드백 루프가 없다.** 도구 경계(기둥③)는 최강인데, "에이전트 실패 → 새 자동화 규칙" 파이프라인(기둥④)은 기록만 있고 소비가 없다. 문서 드리프트를 잡는 게이트 부재는 하네스 철학의 자기 미적용 | **P1** — v0.3.0 |
| 3 | **자율 개선 루프는 조립 문제다.** 예산·시도 캡(`supervisor-goal.sh`), 분리된 그레이더 재료(`docs/benchmark/` + `core/tests/`)가 이미 존재 — autoresearch 패턴을 신규 발명 없이 조립할 수 있다 | **P2** — v0.3.x |

---

## 1. 배경 및 컨텍스트

- **현황**: v0.2.0. 4계층 구조(L1 `core/hooks/` 정본 → L2 `adapters/` → L3 `templates/` → L4 프로젝트), 실행 훅 17개 + 공용 모듈 1개(`hook_config.py`), 에이전트 2종(`code-reviewer`/`security-reviewer`), 스킬 2종(`supervise`/`wrap`), 리뷰어 벤치마크 8/8 검출·오탐 0(`docs/benchmark/results.md`). **2026-07-04 트림**: 에이전트 5→2·스킬 4→2(제거분은 `legacy/trim-2026-07-04/`에 보존), codex-skills는 legacy로 은퇴 — 근거·상세는 §4.6 A-0. (현재값은 §7.1 산출물 카운트가 정본 — 2026-07-09 기준 훅 파일 19개·스킬 4종(이후 `spec`·`verify-completion` 추가). 위 v0.2.0 수치는 당시 스냅샷.)
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
| ③ 도구 경계 | `pre-tool-guard.sh`, `agent-proxy.sh`, `secret-content-scan.py`, r4-mutex 3종, `circuit-breaker.py`, 에이전트별 read-only tool set, `context-mode-guard.sh` | **충족 (최강)** | 과거 약점이던 `supervisor.py` 스텁(격차 #5)은 **✅ P1-4로 해소(2026-07-05)** — 의도 라우팅이 스킬 프롬프트(부탁)에서 훅의 승인 게이트(`ask`)로 승격됨. (`ask`는 deny가 아니라 interrupt-and-confirm이므로 강제가 아닌 확인 요구다.) 그 결정 로그를 재니터가 소비하는 단계도 **✅ P1-5로 해소(2026-07-05)** — `telemetry-digest.sh`(수동 실행). 잔여: 리포트→규칙 자동 반영 파이프라인은 Part 3 몫 |
| ④ 피드백 루프 + 재니터 | `session-quality-gate.py`(Stop), `circuit-breaker.py`, `supervisor-goal-audit.sh`, `telemetry-digest.sh` | **부분** | `supervisor.jsonl`을 읽어 action/specialist 통계 + 규칙후보(GHOST/NO-ACCEPT) 리포트를 내는 1단계는 **✅ P1-5로 해소(2026-07-05)** — `core/infra/telemetry-digest.sh`, 수동 실행·read-only. 잔여: 주기 실행(cron/훅 연동 없음)과 리포트→실제 규칙 반영("실패→새 규칙" 자동 파이프라인)은 여전히 사람이 직접 수행 → Part 3 전체 |

보조 개념(노션 의사코드 대비): 라우터=`plan-gate.py` 4-tier **충족**(supervisor 라우팅만 반쪽) · 유한 재시도=`circuit-breaker.py` **충족** · writer≠reviewer=에이전트 역할 분리+벤치마크 **충족** · 컨텍스트 매니저/GC=**부재**(장기 과제, 이번 백로그 범위 외).

### 3.2 루프 6요소 매핑

| # | 요소 | 현재 | 상태 | 격차 → 백로그 |
|---|---|---|---|---|
| 1 | 자동화/트리거 | `/supervise` 수동 디스패치 | **부분** | 스케줄/웨이크 없음. P2에서도 **의도적으로 수동 유지**(human on the loop) |
| 2 | 검증 가능한 완료 조건 | `supervisor-goal-audit.sh score`, quality-gate | **부분** | wave 완료 조건이 프롬프트 규율에 의존 → P2-2(스칼라 지표) |
| 3 | 워크트리 격리 | `core/infra/agent-session.sh`, r4-mutex, file-mutex | **충족** | — |
| 4 | 예산 가드레일 | `supervisor-goal.sh init <slug> <N> [<budget>]` | **부분** | 인프라 존재, 훅 수준 강제·토큰 계측 없음 → P2-4 |
| 5 | 분리된 그레이더 | `core/tests/` 9종(GATE 4종 + per-hook/infra) + `docs/benchmark/ground-truth.md` | **부분** | 진짜 그레이더이나 커버리지 아직 협소 — per-hook 테스트 부분 착수(`pre-tool-guard`·`session-quality-gate` 신설/P3, `plan-gate`·`tdd-guard` 잔여) → P1-3, P2-2 |
| 6 | 로깅 | `.agent/logs/supervisor.jsonl`, session store, `telemetry-digest.sh` | **부분** | 로그 소비는 **✅ P1-5로 해소(2026-07-05)** — `telemetry-digest.sh`. 실행 원장(results.tsv 상당)은 여전히 부재 → P2-3 |

### 3.3 확인된 격차 9건 (검증 명령 병기 — 2026-07-04 실측)

| # | 격차 | 검증 명령 → 실측 결과 |
|---|---|---|
| 1 | **팬텀 테스트 참조 15곳** — `README.md:303-308`, `AGENTS.md:51-54·116-118·124`, `docs/architecture.md:127-129`가 `core/tests/adapter-smoke/<ai>/run.sh`, `cross-ai-parity.sh`, `verify-all.sh`, `bootstrap-test.sh`를 지시하나 전부 미존재 **✅ P0-1로 해소(기존 커밋, 2026-07-04 표기 갱신)** | `grep -rn 'adapter-smoke\|cross-ai-parity\|verify-all\|bootstrap-test' README.md AGENTS.md docs/architecture.md` → 0건(`660b5aa`) |
| 2 | **도메인 잔재** — `AI_BOOTSTRAP.md:35`(Step 5 항목 2)의 Guarded Domains 목록에 이전 프로젝트 특화 항목 포함. 도메인 중립 원칙(`rules/policy/security-guards.md`의 일반 5영역) 위반. 해당 용어는 이 문서에 재기재하지 않는다 — 원문 참조 **✅ P0-2로 해소(2026-07-04)** | `sed -n '35p' AI_BOOTSTRAP.md` |
| 3 | **훅 수 드리프트** — `README.md:223`, `CHANGELOG.md:36`이 "~25 portable hooks" 표기 **✅ P0-3로 해소(기존 커밋, 2026-07-04 표기 갱신)** | `find core/hooks -maxdepth 1 -type f -perm -u+x ! -name README.md \| wc -l` → **17** (+ 비실행 공용 모듈 `hook_config.py` 1개); 라이브 문서 "~25" 잔존 0건 |
| 4 | **축소 이력 미기록** — `CHANGELOG.md:40-42`(0.1.0)는 에이전트 10종·스킬 16종·codex-skills를 나열하나 당시(2026-07-04) 2종/2종. 0.2.0에 Removed 기록 없음 **✅ P0-4로 해소(기존 커밋, 2026-07-04 표기 갱신)** | `ls agents/*.md \| wc -l` → 2, `ls -d skills/*/ \| wc -l` → 2; CHANGELOG Removed 섹션에 10→5(0.2.0)·5→2/4→2(2026-07-04) 트림 이력 존재 |
| 5 | **supervisor.py 스텁** — 헤더 자체가 "Supervisor stub". `skills/supervise/SKILL.md`의 풍부한 계약 대비 미구현 **✅ P1-4로 해소(2026-07-05)** | `head -5 core/hooks/supervisor.py` → "Supervisor v0.2 (minimal dispatcher). Dispatch, not advise." (`f9af460`+`8d1a789`) |
| 6 | **plans 경로 이중 진실** — `skills/supervise/SKILL.md`·`core/infra/supervisor-goal-audit.sh`는 `~/.agent/plans`(env `AGENT_PLANS_DIR`), `core/hooks/secret-content-scan.py:60` 주석은 `~/.claude/plans` **✅ P0-5로 해소(2026-07-04)** | `grep -rn '\.claude/plans' core/ skills/ --exclude-dir=legacy` |
| 7 | **더티 트리** — ` M gitleaks.toml`, `?? .omc/`, `?? CLAUDE.md`(개인 경로 포함 루트 파일, 배포 템플릿 아님) **✅ P0-6으로 해소(기존 커밋, 2026-07-04 표기 갱신)** | `git status --short` → 클린(`.omc/` gitignore 처리, 루트 `CLAUDE.md` untracked) |
| 8 | **sanitize-audit 스캔 범위 부정합** — `.github/workflows/ci.yml:100`의 CI 잡은 grep 패턴 리터럴을 담고 있고 CI의 git grep은 자기 자신을 제외하지만, 로컬 `sanitize-audit.sh`에는 ci.yml 제외 규칙이 없어 **클린 트리에서도 로컬 감사가 항상 FAIL**. `.claude/locks/` 런타임 아티팩트도 스캔에 걸림 (2026-07-04 실측) **✅ P0-7로 해소(2026-07-04)** | `bash core/tests/sanitize-audit.sh` → FAIL: ci.yml, .claude/locks/active-sessions.json |
| 9 | **hook-config.yml `risk_areas:`/`resources:`/`hardcoding:` 미배선** — `setup.sh --project`가 출하하는 `templates/hook-config.yml.template`을 런타임에 읽는 훅이 0개(전부 스크립트 하드코딩). 실동작 로더는 `hook_config.py`의 secret-scan 확장(`.agent/hook-config.yml`) 뿐인데, 그 스키마(`secret_patterns`/`exempt_paths`/`credential_key_names`)는 출하 템플릿에 없음. 문서 드리프트 감사(Phase 3, 2026-07-04)에서 발견 → P1-8 **부분 해소(2026-07-05, `2ab9428`)**: 실로더 스키마는 템플릿에 출하 + 소비 증명 테스트로 드리프트 가드 완료. `risk_areas:`/`resources:`/`hardcoding:`를 실제 훅 런타임에 배선하는 것은 여전히 미해결 잔여 | `grep -rln 'yaml.safe_load' core/` → `core/hooks/hook_config.py` 1개뿐 |

---

## 4. Part 2 — 개선 백로그

항목 형식: `ID / 작업 / 근거 / 완료 조건(기계 검증) / 규모(S≤1h, M=반나절, L=1일+)`.

### 4.1 P0 — 위생 (v0.2.1, 11건 전부 S — 최초 7건 합계 반나절 + 훅 감사 배치 4건 2026-07-04)

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P0-1 ✅ (기존 커밋으로 이미 해소 — 2026-07-04 표기 갱신) | README/AGENTS.md/architecture.md의 테스트 참조를 실존 4개(`sanitize-audit`/`adapter-parity`/`hook-config-test`/`post-commit-autosync-test`)로 정정. 누락 스크립트 신설은 P1로 이관 | 격차 #1 | 격차 #1의 grep 명령 0건(legacy/ 제외) 또는 참조 경로 전부 실존 — 실측 0건 확인(`660b5aa`) | S |
| P0-2 ✅ 2026-07-04 | AI_BOOTSTRAP.md Step 5 도메인 중립화 — 특화 항목 제거, `hook-config.yml risk_areas` 참조로 교체 + **`sanitize-audit.sh` 패턴 목록에 해당 용어 추가**("실패→규칙" 실천) | 격차 #2 | `bash core/tests/sanitize-audit.sh` clean + 패턴 목록에 신규 항목 존재 | S |
| P0-3 ✅ (기존 커밋으로 이미 해소 — 2026-07-04 표기 갱신) | 훅 수 표기 정정 — 정의 고정: "실행 훅 17 + 공용 모듈 1". README/CHANGELOG 수정, 계수 명령 병기 | 격차 #3 | 문서 수치 = 격차 #3 find 명령 출력 — 라이브 문서에 "~25" 잔존 0건(CHANGELOG의 0.1.0 이력 항목은 당시 시점 기록이라 예외) | S |
| P0-4 ✅ (기존 커밋으로 이미 해소 — 2026-07-04 표기 갱신) | CHANGELOG Unreleased에 `Removed: agents 10→5, skills 16→4` 축소 이력 기록 | 격차 #4 | CHANGELOG Removed 섹션 존재, 수치 = 격차 #4 ls 명령 출력 — 확인됨(추후 5→2/4→2 2차 트림도 별도 기록) | S |
| P0-5 ✅ 2026-07-04 | plans 경로 단일화 — 정본 `~/.agent/plans`(AI-불가지 원칙; adapter가 도구별 경로 번역). `secret-content-scan.py:60` 주석 수정 | 격차 #6 | `grep -rn '\.claude/plans' core/ skills/ --exclude-dir=legacy` 0건 | S |
| P0-6 ✅ (기존 커밋으로 이미 해소 — 2026-07-04 표기 갱신) | 작업 트리 정화 — 루트 `CLAUDE.md`(개인 경로) .gitignore 처리 또는 템플릿 흡수, `gitleaks.toml` 변경 검토 후 커밋/원복, `.omc/` ignore | 격차 #7 | `git status --short` 출력 없음 — 확인됨(`.omc/` gitignore 처리, 루트 `CLAUDE.md` untracked) | S |
| P0-7 ✅ 2026-07-04 | sanitize-audit 스캔 범위 정합 — `ci.yml` 자기 제외 추가(또는 CI 잡의 패턴도 런타임 토큰 조립로 전환), `.claude/locks/` 등 런타임 아티팩트 제외 | 격차 #8 | 클린 워킹 트리에서 `bash core/tests/sanitize-audit.sh` PASS | S |
| P0-8 ✅ 2026-07-04 | plan-gate 배선 버그 수정 — `UserPromptSubmit`(이벤트에 `tool_name` 부재 → 무음 no-op)에서 `PostToolUse`(matcher `ExitPlanMode\|Task\|Agent`)로 재배선 | 훅 감사 중 발견된 회귀 — 플랜 승인 플래그가 한 번도 기록되지 않고 있었음 | `ExitPlanMode` 픽스처 이벤트 → `/tmp/agent-plan-approved` 생성 확인 (`f822505`) | S |
| P0-9 ✅ 2026-07-04 | `session-quality-gate.py` 로그 목적지 정정 — 플러그인 설치 캐시(`parents[2]`)가 아니라 활성 프로젝트로: stdin 이벤트 `cwd` → `CLAUDE_PROJECT_DIR` → `os.getcwd()` 순으로 해석 | 훅 감사 중 발견된 회귀 — 플러그인으로 설치 시 위반 로그가 사용자 프로젝트가 아닌 플러그인 캐시에 쌓이고 있었음 | 프로젝트 디렉터리에 `.agent/logs/` 위반 로그 생성 확인 (`3ec9e7f`) | S |
| P0-10 ✅ 2026-07-04 | `session-init.py` 환경 경고 — `gitleaks`/`git`이 PATH에 없으면 stderr에 WARN(세션은 차단하지 않음). 정식 `--doctor` 서브커맨드는 P1-7로 이관 | 시크릿 스캔 환경 열화를 세션 시작 시 알릴 방법 부재 | `gitleaks`/`git` 부재 픽스처 → stderr WARN, stdout 무출력 (`f6ebf6e`) | S |
| P0-11 ✅ 2026-07-04 | `session-init.py` Python 3.9 호환 플로어 — `pathlib.Path \| None` 리턴 애노테이션(PEP 604)이 def-time에 평가되어 3.10 미만에서 `TypeError`로 크래시하던 것을 `from __future__ import annotations`로 수정. README에 3.9+ 지원 명시 | 훅 감사 중 발견된 회귀 — 구버전 Python 환경에서 세션 시작 훅이 로드 자체를 실패 | Python 3.9 환경에서 `session-init.py` import 성공 (`1d5cd62`) | S |

### 4.2 P1 — 구조 (v0.3.0)

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P1-1 ✅ 2026-07-09 | **doc-reality 게이트** `core/tests/doc-reality.sh`+`doc-reality-test.sh` 신설 — 모든 tracked `*.md`(재귀·중첩 README 포함, plan/CHANGELOG/legacy 제외)의 (A) 참조경로 실존 + (B) 백로그 6계열 카운트 + (C) 산출물 카운트를 실측 대조. CommonMark 펜스 추적(0-3스페이스, 미종료=malformed HIT). `ci.yml` 5번째 잡. 격차 #1·#3·#4 재발 방지의 규칙화(기둥②의 자기 적용) | 기둥② | ✅ 실측(2026-07-09, PR #31 머지 `080fda5`): 게이트 exit 0·배터리 37/37·CI 5잡 green. 적대적 리뷰 4라운드(refute-by-default, 5→2→0 CONFIRMED) 하드닝 — 미종료펜스 실명·fence-about-fences 오탐·≥4스페이스들여쓴펜스 false-neg·중첩README 스코프갭·`./`회피 전부 수정. 부수: plan §7 머신판독 SSOT 앵커화 + 잔존 팬텀참조 정리 | M |
| P1-2 ✅ 2026-07-10 | `core/tests/verify-all.sh` 통합 러너 — **동적 발견**(`core/tests/*.sh` 전부, self+self-test만 제외 → 게이트 4 + 배터리 13 자동 포함, 신규 스크립트 무편집 편입=anti-rot) + evals 2층(CI와 동일 호출) + gitleaks(부재 시 loud SKIP, 무음 pass 아님). `set -u`(NOT -e, 하나 실패해도 전부 실행), 서브셸 격리, floor 가드(0체크=exit1 거부). `verify-all-test.sh`(21체크: 완결성·fail전파·all-green·list=run·empty-floor·gitleaks SKIP-not-pass). README Verification 통합. **ci.yml 7번째 잡 `verify`**(self-test→full run; CI 밖 orphan 10체크의 유일 실행자·미래 스크립트 자동 커버) | 격차 #1 | ✅ 실측(2026-07-10): `verify-all.sh` 20/20 exit 0·`verify-all-test.sh` 21/21·doc-reality/sanitize/supply-chain/gitleaks PASS·금지토큰 0. 적대적 리뷰(3차원 refute-by-default, 5 CONFIRMED 수정: MAJOR empty-set false-green floor·--list set-u 크래시·gitleaks SKIP 무커버리지 mutation-proof·CI orphan 배선; 3 REFUTED=hardening) | S–M |
| P1-3 ✅ 2026-07-10 | per-hook 단위 테스트 ≥4개(`pre-tool-guard`, `secret-content-scan`, `plan-gate`, `tdd-guard` 우선) — synthetic event JSON → decision JSON 픽스처. **P2 그레이더 확장의 선행 조건** | 루프 요소⑤ | ✅ 실측(2026-07-10): `plan-gate-test.sh`(7체크, `AGENT_PLAN_FLAG` seam 신설로 라이브 승인플래그 무오염) + `tdd-guard-test.sh`(12체크, 격리 mktemp git repo, RGR red/green/no-test verdict) 신설. 기존 `pre-tool-guard-test.sh`(61체크)·`quality-gate-completion-test.sh`(22체크)·`secret-content-scan`=`hook-config-test.sh`·`check-hardcoding-test.sh`(14체크, B1) 합쳐 전 gate 훅 커버, verify-all 자동편입. 동반: tdd-guard 오도성 주석(hook-config override 주장하나 미배선) 정정→아래 신설 backlog | M–L |
| P1-4 ✅ 2026-07-05 (재정의 2026-07-04) | **dispatch, not advise** — `supervisor.py`가 권고 힌트(`systemMessage`)가 아니라 라우팅 결정을 내리게 한다: master-registry `matches.keywords` 매칭 후 specialist 미지정 feature급 의도엔 `ask`. 근거: advisory 힌트는 세션 로그 218건 감사에서 무시율 ~98%(관측) — 프롬프트는 부탁이지 강제가 아니므로 결정 자체를 훅이 내려야 함(기둥③ 자기 적용) | 격차 #5 + 훅 감사(advisory 무시율 ~98%, n=218) | synthetic prompt 이벤트 테스트 통과, `supervisor.jsonl`에 매칭 기록 + `ask` 발동(힌트가 아니라 결정) 확인 — ✅ 실측(2026-07-05): synthetic 이벤트 스위트 30/30 pass, `supervisor.jsonl`에 match/ask-intent/dispatched/ghost 기록 확인, `ask`는 힌트가 아니라 PreToolUse 결정 JSON으로 반환 (`f9af460` red 테스트 + `8d1a789` 구현) | M |
| P1-5 ✅ 2026-07-05 | 텔레메트리 소비(기둥④ 1단계 재니터) — `core/infra/telemetry-digest.sh`: `supervisor.jsonl` deny/ask 통계 → 규칙 후보 리포트 | 기둥④ | 샘플 로그 입력 → 요약 출력 검증 — ✅ 실측(2026-07-05, 리스펙 반영 재구현): action별 카운트 + specialist 퍼널(match→ask→dispatched, 전환율) + 상위 keyword + `NO-ACCEPT`(반복 ask에도 미배차)·`GHOST`(고스트 스페셜리스트)·`OVER-GENERAL`(단일 keyword가 전체 match의 >70%) 3종 규칙후보, `--window`(기본 30일)·`--json` 지원, 의존성 bash+python3만(jq 없음 — 1차 초안이 썼던 jq는 `setup.sh --doctor`의 jq WARN-tier 판정과 모순이라 리스펙에서 구조적으로 제거). 픽스처 스위트 21/21 pass(레거시 v0.1 레코드 degrade 3체크 포함). 커밋: red 테스트 2회(`32495e6`→`1914987`) + 구현 재작성(jq 기반 `9d9c4ad`/`79e3452`를 bash+python3 전용으로 교체). 1차 라운드는 `agent-harness:code-reviewer` 리뷰(needs-changes → 반영·재검증) 거침 | M |
| P1-6 ✅ 2026-07-10 | `adapter-parity.sh` 강화(신규 `cross-ai-parity.sh` 아님 — 그 이름은 P0-1이 제거한 팬텀, 문서는 이미 `adapter-parity.sh` 참조): 동일 논리 이벤트 → 3 adapter → **정규화 decision 동일성**(substring 아님) + full JSON 동일성. 매트릭스=3동사(deny/allow/ask)×2 tool_input shape — **각 shape을 그 필드를 실제 읽는 훅으로 구동**(command→pre-tool-guard.sh, file/content→check-hardcoding.py: 하드코딩 content deny/clean allow)해 필드 오역이 decision을 뒤집게(=비-vacuous)×shell-special(quoted command+content). **부수 보안수정**: codex/gemini adapter synthetic-mode가 `--command`/`--content`를 `python3 -c` 리터럴에 문자열보간(`'''$CMD'''`)→인용부호/개행/`'''` 포함 시 파싱깨짐(파리티 붕괴)+**주입으로 allow 강제=가드 우회** → env 전달(무보간)로 수정, quoted 케이스가 회귀락 | 격차 #1 | ✅ `bash core/tests/adapter-parity.sh` 24/24 exit 0(8시나리오×parity+decision+strict), 3 adapter self-test green, 적대리뷰 CONFIRMED 0(리뷰가 file/content vacuous-pass MINOR 적발→content-reading 훅으로 실질화) | M |
| P1-7 ✅ 2026-07-05 (신설) | `setup.sh --doctor` 정식 환경 진단 신설 — gitleaks/git 존재, python3 버전 플로어(3.9+), 훅 실행권한(`+x`), adapter 존재 여부를 한 번에 점검 | P0-10의 확장(임시 stderr 경고 → 정식 서브커맨드) | `bash setup.sh --doctor` 실행 시 각 항목 OK/WARN/FAIL 출력, 누락 시나리오 픽스처로 검증 — ✅ 실측(2026-07-05, `bb393d8`): 이 머신에서 `doctor: 9 pass, 0 warn, 0 fail`, 픽스처 3종(클린 레포/gitleaks 부재/훅 실행권한 결여) 전부 통과 | S–M |
| P1-8 ✅ 2026-07-10 (risk_areas.secrets.paths) | hook-config.yml 실배선 — `risk_areas:`/`resources:`를 런타임에 실제로 읽게 만들거나(최소한 `templates/hook-config.yml.template`에 `hook_config.py`가 실제 소비하는 `secret_patterns`/`exempt_paths`/`credential_key_names` 스키마를 포함시켜), 문서상 선언과 실제 로더 사이 간극을 좁힌다 | 격차 #9 | 스키마 출하+소비 증명 ✅ 2026-07-05(`2ab9428`). **risk_areas.secrets.paths 런타임 배선 ✅ 2026-07-10**: `hook_config.load_risk_area_secret_paths`(glob→literal prefix 축소, 메타문자 거부=주입불가, ≤50 bound) + pre-tool-guard 가드 11b(프로젝트 선언 시크릿 경로 read/copy/exfil deny, 빌트인 secrets/ 우선·불약화). `risk-area-wiring-test.sh` 12체크(배선 실증+로더 안전경계). **사용자 스코프 확정=risk_areas만**; `resources:`/`hardcoding:` 및 tdd-guard risk_areas override는 미배선(아래 신설 backlog) | M–L |

### 4.3 P2 — 자율 개선 루프 (v0.3.x, §5 설계의 구현)

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P2-1 | `skills/harness-loop/SKILL.md` 작성 — §5의 루프 규정(program.md 상당, 인간만 편집) | §5 | 스킬 로드 후 드라이런 1회에서 §5 절차 9단계가 순서대로 로그에 남음 | M |
| P2-2 | `core/tests/grade.sh` 작성 — GATE(기존 테스트 4종+gitleaks) + 벤치마크 리플레이 → `harness_score: X.Y` 단일 라인 출력 | 루프 요소②⑤ | 현행 코드로 실행 시 `harness_score: 8.0` 재현(기준선), GATE 실패 시 0.0 | M |
| P2-3 | 결과 원장 + 브랜치 규약 — `.agent/loop/results.tsv`(untracked, 5열: commit/harness_score/duration_s/status/description≤80자), 브랜치 `harness-loop/<tag>` | 루프 요소⑥ | 드라이런 후 results.tsv에 keep/discard 행 기록 확인 | S |
| P2-4 | 예산·타임아웃 연동 — `supervisor-goal.sh init` 재사용(세션당 시도 N=5), 런당 10분 타임아웃 kill→`timeout`·discard, GATE 연속 2회 실패 시 circuit-breaker 중단 | 루프 요소④ | 강제 실패 시나리오에서 5회 후 정지 + 원장에 기록 | S |
| P2-5 | 파일럿 3회 + 회고 — 기본 미션(리뷰어 프롬프트 쌍)으로 3세션 실행, keep율·비용·오탐 회고를 `docs/benchmark/`에 추가 | 검증 계층 | 회고 문서 존재 + results.tsv ≥3 세션분 | M |

---

### 4.4 H 시리즈 — 외부 벤치마크(팀 아키텍처 팩토리) 발굴 항목 (2026-07-04 추가)

출처: revfactory/harness (Apache-2.0, §8). 6종 팀 아키텍처 패턴(Pipeline / Fan-out–Fan-in / Expert Pool / Producer-Reviewer / Supervisor / Hierarchical Delegation), "하네스 구성해줘" 메타 스킬(도메인 분석 → 팀 설계 → 에이전트·스킬 생성; "점검/감사/현황/동기화" 요청용 Phase 0 감사 분기 포함), with-skill vs baseline 병렬 비교 + assertion 정량 채점의 스킬 검증 방법론, A/B 증거 문화(n=15, +60% — 항상 한계 고지와 함께 인용)를 차용한다.

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| H-1 | `docs/concepts/team-patterns.md` 신설 — 6 패턴 정의 + `/supervise` wave 구성과의 매핑표. `skills/supervise/SKILL.md` 1단계(플랜 읽기)에 "패턴 선택" 절 추가 | 패턴 어휘 부재로 wave 설계가 매번 즉흥 | 문서 존재 + 6 패턴 각각에 wave 매핑 행 + SKILL.md가 문서 참조 | S–M |
| H-2 ✅ 2026-07-10 | 하네스 점검·감사 모드 — P1-1 doc-reality 게이트·registry drift·훅 수·sanitize-audit를 묶어 실행하고 보고서를 내는 유지보수 스킬. P1-1은 기계 게이트(CI), H-2는 그 소비자(에이전트 주도 감사) — 중복이 아닌 계층 관계 | 기둥④ 재니터의 실행 진입점 부재 | ✅ 실측(2026-07-10): 읽기전용 스킬 `skills/harness-audit/SKILL.md`(spec SKILL.md 프론트매터·섹션 미러; `verify-all.sh` 1회 드라이런 → 검사 항목별 PASS/FAIL/SKIP 표 + **P1-1 doc-reality 결과 명시 인용** + 비-PASS별 목적·근본원인·수정·백로그 후속 → 종합 건강도). 게이트 재구현 아님(소비자 계층). **부수 리팩터**: CI validate-plugin 인라인 4체크를 `core/tests/registry-drift.sh`(+`registry-drift-test.sh` 픽스처 11체크, 4드리프트 클래스별 비-vacuous 검증)로 추출 → verify-all 자동 편입(machine 체크 공백 폐색). supply-chain-scan·sanitize·doc-reality 통과, verify-all 22체크 green. **같은-PR 보강(2026-07-10 총점검)**: SKILL에 런타임 층 step 2 추가(`setup.sh --doctor` + `telemetry-digest.sh` DEAD/FATIGUE — 미측정 층은 미측정으로 보고) + description negative-trigger(T-3 선행 적용) + **doctor 체크 12 신설**(런타임 commands/*.md 팬텀-스크립트 참조 스캔, WARN-only 관측자, `AGENT_COMMANDS_DIR` seam, 상대참조=런타임루트 기준 해석·미확장 $VAR skip, 출력 제어문자 새니타이즈 — 보안 리뷰 PLAUSIBLE 1건 즉시 하드닝) + `setup-doctor-test.sh` 픽스처 7체크(팬텀→WARN·WARN≠fail·해석가능→PASS·$VAR skip·제어문자 무해화 2·dir부재 skip) 25/25 | M (P1-1 이후) |
| H-3 데이터셋시드 ✅ 2026-07-11 | 스킬 A/B 테스트 하네스 — 출하 스킬 5종 대상 with-skill vs baseline 병렬 비교 + assertion 채점 + description 트리거 검증. P2-2 grade.sh(측정 대상=에이전트)와 채점 규약(GATE+단일 스칼라)만 공유하는 별도 항목 | 스킬 설명·트리거 효과가 미검증 | 스킬당 assertion ≥3, 리포트에 n·한계 고지 필수 기재. ✅ 시드분 실측(2026-07-11): `evals/datasets/skill-ab.jsonl`(**35케이스/출하 스킬 5종** — 스킬당 assertion 3 + trigger-pos 2 + trigger-neg 2, 각 rationale는 스킬 자체 description 인용=grounded) + `evals/baseline-skill-ab.json`(fail-closed: min_cases·min_assertions_per_skill=3·shipped-skill 리스트) + `core/tests/skill-ab-dataset-test.sh`(21체크: 파싱·kind별 필수필드·유니크 slug·미지 스킬 거부·assertion≥3 floor·스킬당 trigger 양방향·**shipped SKILL.md 실재 grounding** + 7 RED 픽스처 mutation) + evals/README.md "Skill A/B track" 섹션(**n·한계 고지 필수** 이행: n=35·미실행 계약·라벨 드리프트·CI-safe). trigger-neg에 크로스스킬 판별자 포함("execute approved plan"→supervise≠spec 등). **A/B 러너(with-skill vs baseline 실행·채점)=H-3 본체(B8) 잔여** | L (본체는 B8) |
| H-4 | `/project-init` 메타 팩토리 라이트 — 대상 프로젝트 도메인 분석 → `hook-config.yml risk_areas` 초안 + `.agent/` 특화 파일 제안 자동 생성 | 신규 프로젝트마다 risk_areas 수작업 | 샘플 프로젝트 실행 시 risk_areas 5키 초안 + 특화 제안 ≥1 생성, sanitize-audit PASS 유지 | M |

### 4.5 W 시리즈 — 개인 워크플로우 통합 항목 (2026-07-04 추가)

출처: 개인 지식 볼트 워크플로우 분석(2026-07-04, 실측 페인 기록 기반). **배치 원칙**: 이 레포는 공개·도메인 중립(sanitize 게이트 상시)이므로 개인 경로·볼트명은 하드코딩 금지 — repo에는 **설정 주도 제네릭 구현**만 싣고, 개인 경로 와이어링은 글로벌 레이어(사용자 홈 AI 런타임 설정)에서 한다. 개인 볼트는 프로젝트 훅이 없는 드라이브 루트에 있으므로 W-1·W-6류는 글로벌 훅으로만 발화 가능. **에스컬레이션 원칙**: secrets를 제외한 모든 가드는 deny가 아니라 ask까지만(가시성 우선 원칙).

| ID | 작업 | 근거(실측 페인) | 완료 조건 (기계 검증) | 규모 | 배치 |
|---|---|---|---|---|---|
| W-7 ✅ 2026-07-10 | 가드 오탐 2건 수정 — ① `git commit -m` 메시지 본문을 파괴적 명령 스캔에서 제외 ② pipefail 하 `grep \| wc` 0-매치 false-abort 수정 | 정상 커밋·집계 명령이 가드에 차단된 실사례 | ✅ 실측(2026-07-10): ① `pre-tool-guard.sh`에 SCAN_CMD 메시지-스트립 전처리(파괴 가드 1–4만 소비; `-m '…'`/`-m "…"($·백틱 무함유)`/`-m "$(cat <<EOF…)"` 3형만 스트립 — 실행 가능 페이로드·시크릿 가드는 전체 명령 유지) + 픽스처 10종(멘션 4형 allow·`&&` 후행/`$()` 치환/시크릿 치환 deny). ② 출하 스크립트 실측 결과 라이브 미가드 건 0(auto-ship.sh 기가드) → 회귀 게이트 `core/tests/pipefail-idiom-scan.sh` 신설(strict-mode 런타임 스크립트 28개 스캔, bad/good 픽스처 자가검증=비-vacuous) + AGENTS.md 안전 관용구 명문화 | S | repo |
| W-3 ✅ 2026-07-10 | 시크릿 게이트 잔여분 — `.git/config` 원격 URL 토큰 스캔(pre-push) + `/wrap`에 합성 키 소화(fire-test) 단계(가짜 키 플랜트 → gitleaks 검출 확인 → 제거). ※ nvapi- 룰은 2026-07-04 출하 완료 | 리모트 URL 토큰은 파일 스캔 사각지대 | ✅ 실측(2026-07-10): `core/git-hooks/scan-remote-url.py`(http(s) userinfo 비밀번호/토큰-shape 탐지, ssh·clean·bare-username 무오탐, redaction) → pre-push 스텝0 + /wrap 프리플라이트 배선. `core/infra/gitleaks-fire-test.sh`(레포 자체 nvapi- 룰 합성키 플랜트→검출 단언, PASS=게이트 live·FAIL=allowlist 오설정·exit2=gitleaks 부재 loud SKIP — 실측서 generic AWS키는 placeholder allowlist가 삼켜 레포 자체룰로 전환). `remote-url-scan-test.sh` 13체크 | S–M | repo |
| W-4 | `/verify-claims` 스킬 — writer/reviewer/verifier 3-레인 "진실 방화벽". 이력서·블로그·포트폴리오류 공개물의 미검증 주장을 출판 전 게이트(ask) | 특정 프로젝트에서 검증 레인 효과 기입증 → 이식 | 미검증 주장 포함 픽스처 문서 → 주장 목록 + ask 발동 | M | repo |
| W-1 | freshness-watchdog — SessionStart 글로벌 훅(제네릭): 설정 파일에 등록된 감시 대상(잡 하트비트·필수 경로)의 신선도/실존 검사, 실패 시 경고(ask 이하) | 개인 동기화 크론 무음 사망 ×3, 드라이브 재구성 3회의 사경로 잔존 | 합성 stale 하트비트 → 경고 발화; 설정 부재 시 no-op | M | 혼합(훅=repo, 감시 목록=개인) |
| W-2 | `/reorg-sync` 스킬 — 이전/신규 경로 접두어를 인자로 받아 고아 참조 일괄 스윕(앵커·crontab·셔뱅·worktree gitfile·네이티브 메모리 키) | 드라이브 재구성마다 수작업 스윕 반복 | 픽스처 트리에서 5종 참조 전부 검출·치환 리포트 | M–L | repo(제네릭; 경로는 인자) |
| W-8 | plan-gate 소스 우선 검증 — 메모리 파편은 트리거로만, 플랜의 사실 주장은 라이브 소스 재확인 요구 | 낡은 메모리 인용이 플랜에 그대로 유입 | 메모리-인용만 있는 합성 플랜 → 소스 재확인 요구(ask) | M | repo |
| W-6 | 세션 종료 품질 게이트 일반화 — hook-config `session.close_checks`(임의 명령 리스트, 실패 시 ask)를 Stop 훅에 추가; 볼트 린트·통계 정합 명령은 개인 레이어에서 등록 | 수동 세션 마감 리추얼의 자동화 요구 | close_checks 실패 픽스처 → Stop에서 ask; 미설정 시 무동작 | M | 혼합 |
| W-5 | 증류 리추얼 자율 루프 — `/supervise --goal-mode` 재사용: 원시 수집 → 월간 다이제스트 → 린트 0 → 승인 게이트 | 수집만 쌓이고 증류가 밀리는 만성 적체 | (개인 레이어) 1주기 실행 로그 + 승인 게이트 통과 기록 | L | 개인 레이어(repo 밖; repo는 goal-mode 그대로 제공) |
| W-9 신설 | 웹 성능 완주 루프 — Lighthouse 4카테고리(Performance/Accessibility/Best Practices/SEO) 90+ 목표, 분리된 외부 그레이더(Lighthouse CI)로 채점, `/supervise --goal-mode` 재사용 | 개인 웹 프로젝트의 성능 회귀가 방치되는 패턴(실측 페인) | Lighthouse CI 실행 → 4카테고리 스코어 리포트 생성, 목표 미달 시 goal-mode 재시도 기록 | L | 개인(웹 프로젝트) |
| W-10 신설 2026-07-15 | **서드파티 플러그인 주입-텍스트 오염 스캔** — 설치 플러그인이 세션에 주입하는 블록(MCP tool description·훅 additionalContext·SessionStart 출력)에서 지시형 문구(톤 강제·타 도구 사용 강제·"forbidden_actions"류)를 검출하는 관측자(리포트-only). 자기 서플라이체인 스캔(P3-4)의 거울상 — 그쪽은 "우리가 주입하는가", 이쪽은 "남이 우리 세션에 주입하는가" | **실측(2026-07-14 landscape 재점검)**: context-mode 플러그인의 `<context_window_protection>` 주입이 세션 전역 지시처럼 작동(caveman 톤 강제·타 도구 금지 목록 포함), 독립 조사 서브에이전트 2개가 각자 "출처 불명 삽입 지시"로 감지·불복 — 문구가 별개 플러그인 Caveman(89k★)의 카피와 판박이. 플러그인 설명 필드 = 미검증 프롬프트 유입 경로라는 실증 | 픽스처: 지시형 문구 포함 합성 플러그인 매니페스트/툴 설명 → 검출 리포트(어느 플러그인·어느 필드·어느 문구); 클린 플러그인 → 무보고; 스캔 자체는 항상 exit 0(관측자) | M | repo(스캐너)+개인(판정) |

### 4.6 A/G 시리즈 — 에이전트 재설계·글로벌 통합 (2026-07-04 감사)

출처: 2026-07-04 에이전트/스킬 트림 감사(A) + 글로벌 훅 레이어 통합 결정(G). A는 축소 방향 결정, G는 배치 결정 — 신규 작업 항목이 아니라 **결정 기록**이므로 완료 조건 대신 근거·상태를 기재한다.

| ID | 항목 | 근거 | 상태 / 완료 조건 | 규모 |
|---|---|---|---|---|
| A-0 ✅ 2026-07-04 | 에이전트 5→2(`code-reviewer`/`security-reviewer`), 스킬 4→2(`supervise`/`wrap`), codex-skills 은퇴(→`legacy/`) | 7주 세션 텔레메트리 감사 결과 나머지 3 에이전트·2 스킬 디스패치 0건 | 트림 완료 — 제거 항목은 `legacy/trim-2026-07-04/`에서 복구 가능(`163c73d`·`d847195`·`d6b45a9`) | S |
| A-1 보류 | `doc-writer`/`verifier` 등 신규 에이전트 추가 | 수요 미검증 — A-0과 반대 방향(확장) 결정이라 별도 증거 기준 필요 | 착수하지 않음. 재상정 조건: 실사용 요청이 누적되면 재검토 | — |
| G-1 결정 기록 | 글로벌 훅 일원화 = **Variant A**(이 플러그인 하네스로 통일, legacy global hook set 제거) | 두 하네스 병존 시 훅 충돌·중복 실행 위험 | 실행은 이 레포 밖 글로벌 레이어(사용자 홈 AI 런타임 설정)에서 진행(2026-07-04) — 레포 자체는 변경 없음, 결정만 기록 | — |
| G-2 결정 기록 2026-07-10 | 글로벌 위생 — 존재하지 않는 감사 엔진 스크립트를 호출하던 orphan 커맨드 파일 은퇴(레거시 미러 잔재, 실오발화 확인) + 글로벌 SessionStart 업데이트체크 주기 강등 검토(실측: 네트워크 호출이 이미 24h 캐시라 변경 불필요 판정) | 2026-07-10 워크플로우 총점검 — 선언 매니페스트↔라이브 설정 드리프트 0 확인, 유일 실질 결함이 orphan 커맨드 | 실행은 글로벌 레이어(사용자 홈 AI 런타임)에서 완료. 레포 반입분 = **doctor 체크 12(팬텀-커맨드 스캔)** — 실패 사례의 규칙화 | — |

### 4.7 P3 시리즈 — 외부 하네스 벤치마크 발굴 항목 (2026-07-06 추가)

출처: 2026-07 GitHub 최상위 개인 하네스 8종(superpowers 247k★ / ECC 226k★ / karpathy-skills 188k★ / gstack 120k★ / revfactory 8.2k★ / showcase 6.0k★ / hooks-mastery 3.8k★ / Chachamaru 2.9k★)과 12차원 기능 분류 체계 비교 감사. 채택 기준은 **스타 수가 아니라 메커니즘의 실증 가치** — 카탈로그 극대화(ECC 277 스킬·gstack 60+)·프롬프트 강제("YOU DO NOT HAVE A CHOICE")·간접주입 영속화(ECC observer-loop 보안 감사 지적)·자기채점 벤치마크·실험 API 의존은 이 레포 설계 원칙(도메인 중립·의존성 플로어 bash+python3·"관측자는 차단하지 않는다" 재니터 계약·증거 기반 트림)과 충돌하므로 의도적으로 배제한다. 아래 5건은 "결정적 게이트로 완료·안전을 강화"하는 우리 노선에 정합하는 것만 선별했다.

| ID | 작업 | 근거 (출처) | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P3-1 ✅ 2026-07-06 | 완료 게이트 테스트 실검증 — `core/hooks/session-quality-gate.py`에 hook-config 주도 테스트 명령(`session.completion_tests`) 실행 추가, 실패 시 `block`(Stop 훅은 `ask` 불가 — 기존 게이트와 동일하게 `decision:block` + exit 0). 미설정 시 no-op | Stop 게이트가 스타일/하드코딩/console.log만 검사하고 테스트 통과는 미검증 — hooks-mastery(Stop 훅이 필수파일·export·테스트통과 검사 후 완료 허용)와 ECC(`--no-verify` 결정적 차단)가 독립적으로 같은 패턴 | ✅ `hook_config.load_session_config`(fail-safe·bounded) + `session-quality-gate.py` 실행(per-cmd 타임아웃, 2nd-Stop/advisory 우회, always-exit-0). 테스트 `core/tests/quality-gate-completion-test.sh` 21/21 (실패→block, 통과→no-op, malformed→fail-safe, YAML 경로, 비숫자 타임아웃, 프로세스그룹 격리, 타임아웃→block, 로더 상한 — 적대적 리뷰 하드닝 포함) | S–M |
| P3-2 ✅ 2026-07-07 | 상류 계획 규율 스킬 `/spec` — brainstorm→spec→plan 산출 후 `plan-gate.py`가 승인 게이트. superpowers 워크플로 **내용만** 차용하되 프롬프트 강제가 아닌 도구경계 게이트로 강제 | `/supervise`가 프롬프트→디스패치로 직행, spec/plan 규율 부재로 디스패치 신호 품질 저하. superpowers 방법론이 생태계 최고 호평(비판은 비용뿐) | ✅ `skills/spec/SKILL.md`(brainstorm→`.agent/plans/<slug>/spec.md`+`plan.md`→ExitPlanMode 승인) + **소비자 훅 `core/hooks/spec-gate.py`**(PreToolUse Write/Edit; `tdd-guard.py` 미러 — `AGENT_SPEC_GATE_MODE` off/dryrun/**block**, 기본 dryrun). 갭 확인: `plan-gate.py`가 `/tmp/agent-plan-approved`를 **쓰지만**(ExitPlanMode/plan-class dispatch) 승인 없을 때 **소비해 차단하는 enforcer 부재** → 이 훅이 채움. 플래그 존재→allow(플래그가 dedup), 미승인+실질 impl코드(scope: src/app/pages/lib/server/components)+비면제→block은 `ask`(가역 규율 게이트라 deny 아닌 ask; 이스케이프=ExitPlanMode 승인 or mode=off), dryrun은 advisory. fail-open. hooks.json Write\|Edit\|MultiEdit 체인 편입(tdd-guard 뒤·supervisor 앞). 픽스처 `spec-gate-test.sh` **42/42**. 13-에이전트 적대 리뷰(refute-by-default)가 6 CONFIRMED(1 MAJOR 미앵커 skip·scope 협소·절대경로·case-sensitive ext·flag override 편측결합·+x) 적발→전부 수정 | M |
| P3-3 ✅ 2026-07-06 | `--no-verify`·린터 설정 변조 차단 — `core/hooks/pre-tool-guard.sh`에 `git commit --no-verify`/`git push --no-verify`(+ `git commit -n`) + 린터 설정 파일 수정 감지 추가 → `ask` | 현 가드는 삭제/force-push/.env만 차단, 검증 우회 커밋·린터 무력화는 사각지대. ECC가 린터 설정 수정 대신 코드 수정을 강제 — 우리 "도구경계=물리차단" 강점의 직접 확장 | ✅ no-verify 커밋/푸시 픽스처 `ask`(되돌릴 수 있는 게이트 우회 = 에스컬레이션 원칙상 ask); `git push -n`(dry-run)·정상 커밋 통과(오탐 0); 린터 설정 Bash 변조 픽스처 `ask`, 읽기는 통과. 신규 테스트 `core/tests/pre-tool-guard-test.sh` 28/28(기존 규칙 회귀 + 적대적 리뷰 하드닝: 번들 단축플래그 `-nm`·`git -c`·`core.hooksPath=`·메시지 오탐·리다이렉트 오탐 — 이 훅 최초 테스트) | S |
| P3-4 ✅ 2026-07-06 | 자기 하네스 서플라이체인 스캔 — 출하 스킬·훅·에이전트 파일의 주입성 지시(자동 실행 지시·"확인 요청 금지" 문구·백그라운드 서브프로세스 기동) 정적 스캔 테스트. `core/tests/`에 추가 | 대규모 하네스의 자동 로드 지시 파일이 간접 주입 벡터가 된 실사례(ECC 공개 감사, 당시 213k★·현재 226k★: 513 자동 로드 지시 파일, 64 에이전트 중 49에 Bash, observer-loop 무인 영속화). 우리 도메인 중립 sanitize 게이트와 시너지 | ✅ `core/tests/supply-chain-scan.sh`(4클래스: prompt-injection override·observer-loop 영속화·no-confirm 강제 [prose] + daemon spawn nohup/setsid/disown/crontab [hooks]). 스코프=auto-loaded 지시 파일 `*.md`+`*.template`(소비자에 그대로 복사되는 스캐폴딩)+`*.json`(에이전트 레지스트리) & auto-fired `core/hooks`의 **모든 파일**(확장자 없는 훅 포함); 명시호출 infra/git-hooks는 sanctioned async로 제외·문서화. prose 3클래스는 line-by-line **및 whitespace-flatten** 사본 양쪽 매칭(줄바꿈으로 감싼 주입 회피 차단), 자기참조 예외는 **정확경로 앵커**(basename 우회 차단). 픽스처 테스트 `supply-chain-scan-test.sh` **20/20**(4클래스 검출 + template·확장자없는훅·wrapped·JSON레지스트리·4 daemon토큰 + 클린통과 + FP가드: phantom-라우팅·start_new_session·infra-scope·path-anchored 예외). **CI 신규 잡 편입**(4번째). 13-에이전트 refute-by-default 적대 리뷰로 검출 갭 4건 폐쇄. 패턴은 클린 트리 0-hit 보정 | M |
| P3-5 ✅ 2026-07-06 | 완료주장 독립 검증자 — wave/작업 완료 시 별개 컨텍스트 검증자가 완료주장(파일 존재·테스트 통과·주장↔산출물 정합)을 재검토. H-3 스킬 A/B 채점 규약과 LLM-judge 채점 계층 공유 | hooks-mastery builder-validator 패턴(빌더와 별개 context가 재검토). "테스트 통과 ≠ 실제 동작" 전훈의 구조화 + LLM 출력 품질 평가 하네스의 씨앗 | ✅ Layer1 `core/infra/completion-verify.py`(결정적: 파일존재+substring·테스트 exit0·assertion → 공유 verdict JSON, refute-by-default, fail-safe·bounded, start_new_session+timeout가드) + Layer2 스킬 `skills/verify-completion/SKILL.md`(독립컨텍스트 의미 judge) + 공유규약 `docs/scoring-convention.md`(supervisor-goal-audit 25점과 조화). 테스트 `core/tests/completion-verify-test.sh` 25/25(허위주장→REFUTED·정합→CONFIRMED·malformed/비-list섹션 fail-safe·YAML·프로세스그룹 격리·over-cap·DEVNULL/bounded-read OOM 방어 — 적대적 리뷰 11에이전트 하드닝 포함) | M–L |

출처 URL: superpowers(github.com/obra/superpowers), ECC 및 보안 감사(github.com/affaan-m/everything-claude-code, dev.to/joergmichno "We Audited the Viral 213k-Star ECC Repo"), hooks-mastery(github.com/disler/claude-code-hooks-mastery), Chachamaru Go-네이티브 게이트(github.com/Chachamaru127/claude-code-harness). skip 결정 및 커리어 연계 상세는 개인 볼트 감사 리포트에 별도 기록(공개 레포 반입 제외).

### 4.8 T/E 시리즈 — 자유도/강제 캘리브레이션 감사 발굴 항목 (2026-07-07 추가)

출처: `docs/freedom-enforcement-calibration-2026-07.md` (3축 감사: 레포 인벤토리 + 선행 감사·벤치마크 증류 + 2026 외부 하네스 엔지니어링 동향). 판정 요지: 현 강제 지형은 외부 컨센서스와 정합 — 잔여 리스크는 "기록만 하고 강제 안 함" 3곳(P1-8 잔여 / P3-2 / T-2가 각각 폐쇄)이며, 게이트 강도 조정은 게이트별 발화 데이터(T-2) 없이 하지 않는다. 기각 결정(전역 TDD block 승격, deny 티어 확대, 프롬프트 강제 문구 추가)은 캘리브레이션 문서 §3 참조.

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| T-1 ✅ 2026-07-10 | **teaching gates** — 모든 deny/ask/block 결정 메시지에 근거(WHY: 어느 규칙·왜)와 수정 단계(FIX: 구체 대안 명령/경로)를 포함. 대상: `pre-tool-guard.sh`·`secret-content-scan.py`·`check-hardcoding.py`·`session-quality-gate.py` | 게이트 거부 메시지가 곧 에이전트 교정 지시 — route-around·인간 인터럽트를 줄이는 최저비용 개선 (캘리브레이션 §2) | ✅ 실측(2026-07-10): 4훅 전 deny/ask/block reason에 `WHY:`/`FIX:` 고정 태그(사용자 규격 확정). 기계 체크 = pre-tool-guard-test(전 비-allow 픽스처 자동 태그 단언)·hook-config-test(deny 태그 단언)·quality-gate-completion-test(block reason 태그)·`check-hardcoding-test.sh` 신설(14체크 — 훅 최초 전용 배터리, 픽스처는 런타임 `${Z}` 분절 조립으로 자기차단 회피) | S–M |
| T-2 ✅ 2026-07-10 | **게이트 레지스트리 + fire-rate + 만료일** — 게이트별 "가정하는 모델 약점 + 검토 예정일" 메타데이터 문서(`docs/gate-registry.md`) + `telemetry-digest.sh` 확장: 기존 jsonl 싱크(security-violations·quality-gate-violations·tdd-guard-dryrun·supervisor)에서 게이트별 발화율/자동통과율 산출 → DEAD(발화 0)·FATIGUE(고빈도 ask) 후보 리포트. (스코프 주: 외부 하네스들의 "텔레메트리 대시보드"류는 이 레지스트리+digest의 consumer일 뿐 — 별도 항목으로 만들지 않음, 2026-07-08 landscape 조사) | 게이트 만료 원칙("가정은 만료된다") + permission 승인율 93% 고무도장 실측 — 계측 없이는 dead/fatigue 판정 불가. 모든 강도 조정의 선행 조건 | ✅ 실측(2026-07-10): `docs/gate-registry.md` 13게이트 machine-block(id·hook·decision·sink·match·last_reviewed·assumption) + `telemetry-digest.sh --gates` 모드(레지스트리↔런타임 로그 대조 → DEAD/FATIGUE/STALE/UNINSTRUMENTED, `reproduce_test:true` 제외로 배터리 오염 차단, 만료일 기본 90일=사용자 확정, always-exit-0 관측자). telemetry-digest-test에 합성 레지스트리 배터리(4클래스+reproduce제외+missing-registry fail-safe) 8케이스 | M |
| T-3 ✅ 2026-07-10 | **스킬 부정 예제** — 출하 스킬 description에 negative-trigger("이럴 땐 발동하지 않음") 예제 추가 | 부정 예제 추가로 스킬 라우팅 정확도 73%→85% 보고(developers.openai.com/blog/skills-shell-tips) | ✅ 실측(2026-07-10): 출하 스킬 5종 전부 description에 `NOT ` 부정 예제 ≥1 (harness-audit는 H-2 선행 적용, 나머지 4종 이번 추가). 상시 강제 = registry-drift 체크 7 신설(`skills/*/SKILL.md` description `NOT ` 부재 시 FAIL) + 픽스처 3종(무NOT FAIL·有NOT PASS·무frontmatter FAIL) | S |
| T-4 신설 2026-07-10 | **hook-config 잔여 배선** — P1-8이 `risk_areas.secrets.paths`만 런타임 배선. 나머지 aspirational 필드 완결: ① tdd-guard.py의 위험영역 whitelist를 hook-config `risk_areas`로 override 가능화(현재 GUARD_PATTERNS 하드코딩, 주석은 이미 정정) ② `risk_areas.data/deploy/payment` 패턴을 pre-tool-guard/pre-push 런타임에 실제 소비 ③ `resources:` 필드 실사용처 설계 또는 스키마 제거(격차 #9 원안) | B2 P1-3서 tdd-guard 주석-현실 불일치(config override 주장하나 미배선) 실측 발견 — S급 주석정정은 즉시, 전체 배선은 M+라 이월(사용자 규모별 분기 결정) | tdd-guard 픽스처: hook-config `risk_areas` override가 실제 whitelist 변경; `resources:`는 소비증명 또는 스키마 삭제 | M |
| E-1 부분 진행 2026-07-09 | **eval 하네스 공개 승격** — P3-5(`completion-verify.py`)+H-3(스킬 A/B)를 공개 `evals/` 디렉터리로 승격: 라벨 테스트셋 + LLM-judge 채점(`docs/scoring-convention.md` 재사용) + **Pass^3**(독립 3회 전부 성공) + CI 회귀 게이트 | 2026 수렴 관행(경량 CI eval 게이트 + 회귀 추적, Pass^k 엄밀성 기준선) — 벤치마크 감사(2026-07-06)가 지목한 최대 갭이자 world-class 구분 신호. 2026-07-08 landscape 조사(`docs/benchmark/landscape.md`)에서도 인기 하네스들의 공통 최강 투자처 = eval로 재확인 — 최우선 유지 | `evals/` 존재 + 라벨셋 ≥10케이스 + CI 잡에서 Pass^3 리포트 생성 + 기준선 대비 회귀 시 FAIL. **배치1 ✅ 결정층(2026-07-09): `evals/run-evals.py`(라벨셋 채점 + Pass^3 + baseline 회귀게이트) · `evals/datasets/completion-verify.jsonl`(라벨 12케이스, CONFIRMED/REFUTED) · `evals/baseline.json` · `evals/README.md` + `core/tests/evals-test.sh`(28체크) + ci.yml 6번째 잡. 잔여: LLM-judge 의미층 + H-3 스킬 A/B 데이터셋(후속 증분).** **배치2 ✅ 의미층 결정플로어(2026-07-09): green-by-construction 테스트(통과하지만 아무것도 단언 안 함) 검출 judge — `evals/judges/reference-judge.py`(claim `test_sources`별 파일을 real-vs-trivial 라인 휴리스틱으로 판정, 실제·비상수 assertion ≥1이면 meaningful; 공유 verdict 스키마, refute-by-default, bounded read, 루트 밖 경로 거부·leak-safe, false-CONFIRMED보다 false-REFUTED 편향) · `evals/datasets/semantic-judge.jsonl`(라벨 17케이스 8C/9R) · `evals/baseline-semantic.json` · ci.yml `evals` 잡에 의미층 run 스텝 추가(Pass^3+회귀게이트) + `core/tests/reference-judge-test.sh`(52체크). **정직한 천장**: 구문적 triviality(무-assertion/특정 상수-assertion 관용구)만 잡고 임의 always-true 식(불리언 조합·컨테이너 리터럴 비교)·의미적 triviality(변경 코드경로 미실행하는 그럴듯한 assertion)는 못 잡음 — 후자는 실모델 필요, `skills/verify-completion` 의미패스 또는 pluggable real `--verifier`로 실행(CI 밖). 잔여: LLM-judge 의미층 + H-3.** **배치3 ✅ 실LLM judge 어댑터(2026-07-10): reference-judge의 정직한 천장이 못 잡는 *의미적* triviality(변경 코드경로 미실행하는 그럴듯한 assertion)를 실모델로 판정 — `evals/judges/llm-judge.py`(동일 verifier 인터페이스 `--root <root> <claim.json>`→공유 verdict JSON; cited test_sources·claimed files를 bounded·루트포함해 읽어 delimited DATA로 프롬프트에 임베드→서브프로세스 CLI[`LLM_JUDGE_CMD` 기본 `claude -p`, `LLM_JUDGE_MODEL`/`LLM_JUDGE_TIMEOUT` env]에 질의→`{meaningful,reason,confidence}` strict JSON 파싱[단일 펜스 스트립+방어적]→verdict 매핑; refute-by-default[미파싱·키누락·오타입·빈 test_sources·escape경로·저신뢰<0.6→REFUTED], **인프라 fail-closed**[CLI 부재·타임아웃·비영-exit·strict-int 타임아웃 위반→stderr+비영 exit, stdout에 verdict 미방출=러너가 crash로 인지], realpath 봉쇄·bounded read·minimal env·프롬프트 injection 봉쇄[DATA 격리 + **per-call 논스 마커**(콘텐츠가 종료 마커 위조 불가) + **defang**(콘텐츠 내 마커꼴 문자열 무력화) → delimiter-injection 봉쇄, 데이터블록 내 적대 산문은 잔여위험으로 명시]) · 라벨 데이터셋 `evals/datasets/llm-judge.jsonl`(10케이스 5C/5R, **구문만으로 판정 불가**=결정층이 10개 전부 CONFIRM해 5/10 실측) · `evals/baseline-llm.json`(min_cases=10, **로컬 강제·CI 밖**) · mock-CLI 배터리 `core/tests/llm-judge-test.sh`(34체크: happy C/R·refute-by-default·펜스파싱·저신뢰·부재/타임아웃/비영-exit/**빈-stdout** fail-closed·strict-int·심링크 봉쇄·**injection 봉쇄 mutation검증**[종료마커 임베드→defang·논스 확인]·증거 forward) + `evals/README.md` "Real-LLM track" 섹션. **CI 미편입**(실모델 호출 없음 — evals CI 잡 무변경, 배터리만 verify-all 자동 편입 24→25 로컬체크). **--repeat 1 근거**: 비결정 judge를 Pass^k 동일-verdict 규칙으로 채점하면 부정직(flakiness는 은폐 아닌 관측 대상) — Pass^3는 결정층 유지. **적대 리뷰 3 CONFIRMED 수정**(injection delimiter-breakout·빈-stdout verdict오염·SSOT 카운트). 잔여: H-3 스킬 A/B.** **설계 입력(2026-07-14 landscape 재점검)**: karpathy/llm-council의 3단 패턴(개별응답 → **익명** 교차평가/랭킹 → Chairman 합성) — 실LLM judge 트랙이 현재 단일심사인 데 대한 익명-동료평가 확장 옵션. 익명화가 모델-정체성 편향(자기 출력 선호)을 차단하는 게 핵심 아이디어. 코드 이식 아님(저장소는 저자 명언 "vibe coded" 토이·8개월 정체) — 패턴만. 채택 시 --repeat 근거와 동일하게 비결정성은 관측 대상으로 유지 | L |

### 4.9 O/L/I 시리즈 — 오케스트레이션·루프 승격 + 인프라 (2026-07-08 추가)

출처: 2026-07-08 레이어 통합 감사(3축: 로컬 레이어 인벤토리 · 사용 텔레메트리 · 외부 오케스트레이션/루프 동향). 외부 근거 요지 — **오케스트레이션**: orchestrator-worker(map-reduce-and-manage)가 정착 컨센서스이고 피어 스웜은 배제, write는 single-threaded, 실무 fan-out 3–5, 멀티에이전트는 토큰 ~15×라 고가치·병렬화 가능·read-heavy 작업 한정, **위임 계약 4요소(목표/출력형식/도구·범위/경계)가 품질 최대 레버**, 서브에이전트는 리드 대화 히스토리를 상속하지 않으므로 스폰 프롬프트가 컨텍스트를 전부 운반해야 함. **루프**: fresh-context·반복당 정확히 1 task·진행상태는 파일+git이 레퍼런스 패턴; 그레이더는 단일 스칼라 대신 실패모드 체크리스트(벤치마크 "최적화"의 73.8%가 실효익 0인 proxy-hacking 실측 — openreview.net/forum?id=ikrQWGgxYg; 테스트 덮어쓰기·채점 함수 변조 등 verifier 게이밍 문서화 — arxiv.org/pdf/2606.07379). 개인 규모에선 오케스트레이션 프레임워크 불채택이 컨센서스(핸드롤 유지). 로컬 레이어 위생: eager-load 표면은 스폰마다 배수 증식 — 전문 지시는 on-demand 스킬로.

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| O-1 ✅ 2026-07-10 | **supervise 오케스트레이션 계약 개정** — ⓐ위임 계약 템플릿 `skills/supervise/templates/delegation-contract.md`(목표/출력형식/도구·범위/경계 4요소 + **`model` 필드** — 실행 wave는 티어표 기본값(구현=워크호스·기계적=LOW)을 명시, 판단 작업은 무핀 inherit만 허용; 2026-07-08 판단/손발 감사 편입) ⓑwave당 fan-out 캡 3–5(초과 시 wave 분할) ⓒwrite single-threading(파일셋별 writer 1명 — 스킬 규율; 리뷰·검증 에이전트의 read-only **도구셋**이 유일한 기계 강제 지점) ⓓ적대 검증 레인 컨텍스트 격리(verifier는 fresh spawn, 저자 컨텍스트·자기평가 미전달, end-state만 채점). H-1 team-patterns 문서와 연계 | 위임 계약이 멀티에이전트 품질의 최대 레버(2026 컨센서스); write 경합은 문서화된 실패 모드. model 필드 근거: 실행을 세션 최상위 모델로 인라인 수행하는 것이 기본값이 되는 고비용 실패 모드(2026-07-08 실측) | 템플릿 파일 존재 + **템플릿에 model 필드 존재** + SKILL.md가 4요소·캡·single-writer·검증 격리 4규칙과 **execution-dispatch 티어 규칙**을 참조 + 픽스처 플랜에서 wave 분할 데모 + **리뷰·검증 에이전트 read-only 도구셋을 CI agent-frontmatter 검증이 가드**(기존 validate 잡 확장 — 규율 문서만으로 "기계화"를 주장하지 않기 위한 최소 기계 검증). ✅ 실측(2026-07-10 워크플로우 총점검 후속): `skills/supervise/templates/delegation-contract.md`(4요소+`**model**:` 필드+외부 미니멀 하네스 흡수 3섹션 Self-contained/Constraints 재주입/Executable AC+fan-out 캡 wave 분할 데모) · supervise SKILL.md Step 2b에 계약+4규칙 배선, Model policy 표 enforcement 셀 정직화(가드 가능 반쪽=CI, call-time 오버라이드=관례 명시) · spec SKILL.md Step 3에 실행가능 verify 기본 1문장 · `registry-drift.sh` 체크 5(reviewer/verifier read-only 도구셋 — 미허용 도구·allowlist 부재 양쪽 FAIL)+체크 6(supervise 존재 시 템플릿+model 필드 필수, 무-skills 픽스처 면제) + `registry-drift-test.sh` 7케이스 확장(멀티라인 tools 블록 파싱 — read-only 통과·write 밀수 FAIL 포함) 24/24 | M |
| O-2 | **`skills/loop` 범용 반복 실행 스킬** — 반복마다 fresh context, 반복당 정확히 1 task, 진행상태는 파일+git(컨텍스트 비의존 — 재시작 시 이어가기), 하드 예산·시도 캡(`supervisor-goal.sh` 재사용), 머지는 인간 승인. §5 harness-loop의 실행체 겸용(미션이 하네스 자신일 때 = P2, 임의 목표일 때 = 범용) | 루프 레퍼런스 패턴(fresh-context/1-task/파일 상태) + 기존 goal-mode 인프라 재사용 | 픽스처 미션 1회: 상태 파일 생성 → 세션 재시작 → 이어가기 성공 + 캡 도달 시 정지 기록 | M |
| L-1 문서분 ✅ 2026-07-11 | **P2-2 grader 재설계 amendment** — 단일 스칼라 `harness_score` 채점을 실패모드 체크리스트 채점으로 교체: `evals/failure-modes.yaml`(명명된 실패모드 — 적대 리뷰 실적발 건: 조용한 드롭, glob 누락, 우회 플래그, false-CONFIRMED 등)에 대해 모드별 boolean+근거 인용. §5.1 대응표의 해당 행 수정. **E-1(evals/)이 선행 — 역순 금지(grader 없는 루프 = 지표 게이밍 확정)** | "채점 기준이 실패모드를 명시하지 않으면 검증 강화로는 게이밍을 못 막는다"(arxiv.org/pdf/2604.15149) — proxy-hacking 73.8% 실측(openreview.net/forum?id=ikrQWGgxYg) | §5 문서 수정 + `failure-modes.yaml` 초안 ≥8모드 + grade 출력이 모드별 verdict 나열. ✅ 문서분 실측(2026-07-11): `evals/failure-modes.yaml`(schema_version + **12모드** 5필드 완비 — 캠페인 적대 리뷰 실적발 증류, 각 모드에 `caught_in` PR 인용·`detection_signal`·`grader_check` 보울린 질문) + §5.1 `val_bpb` 행을 체크리스트 채점으로 개정(모드별 `mode:<id> PASS\|FAIL — 근거` + 롤업 harness_score 유지로 results.tsv/grep 소비자 계약 무파손) + 배터리 `core/tests/failure-modes-test.sh` **25체크**(파싱·schema_version·≥8모드 floor·유니크 kebab id·전 필드 non-empty + 12모드 존재 대조 + 6 RED 픽스처 mutation검증: too-few/missing/blank/dup/non-kebab/unparseable 전부 거부). **구현분(grade.sh 모드별 verdict 방출)=B4 잔여** | S(문서 ✅) + M(구현, B4) |
| L-2 | **grader/tests write-ban + append-only 원장** — 루프 실행 중 개선 에이전트의 `evals/`·`core/tests/` Write/Edit에 `ask`(**deny 아님 — secrets 외 ask-까지 에스컬레이션 원칙 유지**, 캘리브레이션 문서 §3a), results 원장은 append-only(truncate/rewrite에 `ask`) | verifier 게이밍 문서화(테스트 덮어쓰기·채점 함수 변조·감시 코드 사보타주 12% — arxiv.org/pdf/2606.07379) — "TARGET-외 diff discard"의 사전 보강 | 픽스처: 루프 세션 마커 하에서 `evals/` Write → `ask` 발동; 원장 append 외 변조 → `ask`; 정상 append·비루프 세션 → 통과(오탐 0) | S–M |
| I-1 ✅ 2026-07-08 | **secret-content-scan 매처 통합** — `hooks/hooks.json`의 동일 훅 **7개** 매처 등록을 통합(동작 동일, PreToolUse 등록 표면 축소) | 훅 이벤트당 중복 주입은 순수 오버헤드 — 레이어 감사에서 전 이벤트 최다 혼잡 지점이 PreToolUse로 실측 | ✅ 7→**2**로 통합: 비편집 싱크 6블록(supabase·firecrawl·WebFetch·notion·gdrive·stitch)을 유니온 매처 1개로, 편집 체인(Write\|Edit\|MultiEdit) 내 1개는 유지 — 체인 순서(hardcoding→secret→mutex→tdd→spec→supervisor) 보존이 1개 초과 절감보다 우선(매처 통합은 등록 표면 정리이지 이벤트당 실행 수는 동일). 커버 도구 19종 동일 검증 + `adapter-parity.sh` 6/6·`hook-config-test.sh` 10/10 green | S |
| I-2 ✅ 2026-07-08 | **doctor 확장: 캐시·매니페스트 드리프트 검사** — ⓐ플러그인 설치 캐시에 다중 버전 공존 시 WARN(스테일 캐시가 트림된 에이전트/스킬을 계속 노출하는 드리프트의 근원 — 0.2.0/0.2.1 공존이 은퇴 에이전트 3종을 재노출한 실사례) ⓑ선언된 글로벌 훅 목록(사용자 매니페스트 파일, 경로는 env로) vs 실제 런타임 설정 대조 | 선언 상태의 기록·대조 부재가 통합 결정의 이틀 내 무음 드리프트를 허용한 실사례 | ✅ `setup.sh --doctor` 체크 10(캐시: `AGENT_PLUGIN_CACHE_ROOT`, 다중 버전 WARN·단일 PASS·부재 PASS)·체크 11(매니페스트: `AGENT_HOOK_MANIFEST`(기본 `~/.claude/LOCAL-LAYER.hooks`)·`AGENT_GLOBAL_SETTINGS`, 양방향 대조 declared-but-not-live/live-but-undeclared, **WARN only — 관측자는 차단하지 않음**, 부재 시 skip). 픽스처 `setup-doctor-test.sh` **15/15**(신규 8케이스: 이중캐시 WARN·단일 PASS·정합 PASS·양방향 드리프트 WARN+exit 0·**구조적 malformed settings → 클린 WARN·no-traceback**(적대 리뷰 MODERATE 반영)·**BOM 매니페스트 정합**(utf-8-sig, 리뷰 MINOR)·부재 skip) | S–M |

### 4.10 M 시리즈 — 크로스런타임 모델 티어링 (2026-07-08 추가)

출처: 2026-07-08 모델 티어링 감사(3축: 레포 라우팅 표면 · 로컬 런타임 설정 · 2026-07 모델 티어 지형). 판정 요지 — 기존 모델 정책(계획=무핀 inherit, 전문가=frontmatter 핀, CI 드리프트 가드)은 **Claude 전용**이었고 Codex/Gemini 런타임엔 티어 개념이 전무(어댑터=이벤트 번역기, 템플릿에 model 라인 0). 외부 수렴 관행 = 3단 사다리(LOW 기계적/MID 워크호스/TOP 추론) + 직교 effort 다이얼("단 올리기 전 단 내 effort부터"), 팬아웃 워커 티어가 최대 비용 레버(멀티에이전트 ~15×). 기각: 런타임 모델 스위칭 훅(프롬프트 분류기 부활), 자동 티어 에스컬레이션, 저티어 전용 에이전트 신설(로스터 큐레이션 역행), 가격 상수 레포 반입.

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| M-1 ✅ 2026-07-08 | **`docs/model-routing.md` 신설** — 작업 클래스→티어 크로스런타임 정본(3단 사다리+effort 다이얼, 팬아웃=LOW 기본, enforcement map, 비채택 결정 4건 명기). supervise Model policy 표를 "Claude 강제 인스턴스"로 상호 링크 | 티어 정책이 supervise SKILL.md에만 있어 타 런타임으로 번역 불가였음 | ✅ 문서 존재 + supervise SKILL.md가 링크 참조 + 티어표에 3 런타임 열 전부 존재 | S |
| M-2 ✅ 2026-07-08 | **verify-judge 티어 floor** — `/verify-completion` Layer 2 semantic judge에 워크호스(MID) 미만 금지 명문화: 저티어 세션이면 judge dispatch에 명시 `model` 오버라이드 | refute-by-default judge가 저티어에서 그럴듯한 false CONFIRMED를 내면 완료 게이트가 무음 무력화 — 게이트 중 유일하게 모델 품질에 판정이 직결 | ✅ verify-completion SKILL.md에 floor 문단 + model-routing.md Floors 절 | S |
| M-3 ✅ 2026-07-08 | **어댑터 템플릿 티어 배선** — codex `quick.config.toml.template`(LOW)·`deep.config.toml.template`(TOP) 별도 프로파일 파일(최신 CLI가 인라인 `[profiles.*]`를 legacy로 거부 — 라이브 CLI 실증) + effort-before-tier-up 주석, gemini 템플릿에 기본 모델=워크호스 + caller `-m` 에스컬레이션 주석 (모델 ID는 2026-07 스냅샷 예시로 명기) | 하네스 모델 정책이 두 런타임으로 전혀 번역 안 되던 갭의 최소 배선 — 설정 파일이 유일한 티어 운반체(런타임 스위칭 훅은 기각) | ✅ 프로파일 템플릿 2파일 존재 + gemini 템플릿 model 블록 + model-routing.md enforcement map과 상호 참조 | S |
| M-4 ✅ 2026-07-10 | **doctor 확장: 티어 프로파일 존재 검사** — `setup.sh --doctor`에 로컬 codex config의 quick/deep 프로파일 부재 시 INFO/WARN(템플릿 미적용 감지). I-2 매니페스트 검사와 동일한 WARN-only 관측자 원칙 | 템플릿은 복사 시점 이후 드리프트 감지 수단이 없음 — I-2와 같은 "선언 vs 실제" 대조 계열 | ✅ 실측(2026-07-10): doctor 체크 13 신설 — `${CODEX_CONFIG:-~/.codex/config.toml}` 곁의 quick/deep.config.toml 존재 검사(WARN-only, config 부재 시 skip PASS, seam=CODEX_CONFIG) + setup-doctor-test 픽스처 4체크(有 PASS/無 WARN/WARN≠fail/부재 skip) 29/29 | S |
| M-5 ✅ 2026-07-10 | **clean-install CI smoke** — bare checkout→scratch config home 설치→`setup.sh --doctor` 0 fail을 단언하는 CI job. 2026-07-08 landscape 조사 편입 | 조사상 배포·설치 정합성은 상위 프로젝트 공통 투자처 — marketplace는 비채택(Non-goals)이어도 cold-install 검증은 별개인데 당시 수동뿐(`docs/benchmark/landscape.md`) | ✅ ci.yml 8번째 잡 `clean-install`: scratch `$HOME`+`AGENT_SETUP_YES=1` 비대화 설치(`--all` 3런타임) → **anti-vacuous 단언 5종**(3런타임 설정 실생성 + `{{FRAMEWORK_ROOT}}` 치환 실검증 — 적대 리뷰가 실측한 "doctor는 빈 home에 무반응(install-blind)" 갭을 이 단언 스텝이 캐리) → doctor 0 fail(env·repo 층) → **인잡 뮤테이션 프로브**(훅 실행비트 제거→doctor red 아니면 잡 fail — 일회성 뮤턴트 커밋 대신 상시 내장). 로컬 시뮬레이션 전 스텝 실측 통과 | S–M |

### 4.11 F 시리즈 — 워크플로우 총점검 발굴 항목 (2026-07-10 추가)

출처: 2026-07-10 에이전트 워크플로우 총점검(3축 병렬 감사: 글로벌 레이어 인벤토리 · 이 레포 라이프사이클 매핑 · 외부 미니멀 하네스 1종 정밀 비교). 판정 요지 — 라이프사이클 골격(계획→실행→검증→커밋)은 건재하고, 잔여 갭은 루프 양 끝(상류 딥 인터뷰 · 레포-네이티브 실행 기록). 외부 비교 대상의 선별 흡수 강점(step 자기완결성·제약 재주입·실행가능 AC)은 별도 항목이 아니라 **O-1 위임 계약 템플릿의 섹션**으로 편입한다. 기각 결정 3건: executor 에이전트 신설(A-1 보류 원칙·supervise Model policy와 충돌 — O-1 CI 가드가 올바른 폐쇄), 글로벌 기록 보장-캡처 훅(리마인더 3단+상시 자동캡처 이중화로 충분, 훅 직접 요약 생성은 저품질 bulk), 외부 하네스의 감사 실패 자동 재시도 루프(supervise "failed audit는 자동 재시도 금지" 하드룰과 정면 충돌).

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| F-1 ✅ 2026-07-10 | **/spec 딥 인터뷰 서브모드(옵트인 `--interview`)** — 미지수 표(각 항목 "설계 결정을 바꾸는가 Y/N") → Y 항목만 배치 질문(라운드당 ≤4문항) → 답변 반영 재채점(신규 미지수는 표에 추가 = 결정트리 가지치기) → 종료 조건 2개(결정-변경 미지수 0 또는 3라운드 도달, 잔여는 spec.md `## Open questions` 이월) + spec.md `## Interview log` 섹션. **기본 동작 무변경**(단일 패스 유지 — 강제의 정본은 spec-gate 도구경계, 생태계 인터뷰형 선례도 전부 명시 호출형) | Brainstorm이 단일 패스라 모호한 요청에서 잘못된 spec에 커밋할 위험(2026-07-10 총점검 갭) | SKILL.md에 종료 조건 2개·라운드 캡·문항 캡 grep 가능 + 템플릿에 Interview log/Open questions 섹션 + supply-chain·sanitize·doc-reality green + **spec-gate 로직 무변경**(인터뷰가 게이트 우회 경로를 만들지 않음이 리뷰 요건). ✅ 실측(2026-07-10): `skills/spec/SKILL.md` Step 1에 `--interview` 서브모드 — 미지수 표(decision-changing Y/N)→Y만 배치 질문(**at most 4 questions per round**)→재채점(신규 미지수 표 편입=가지치기)→종료 조건 2개(**zero open decision-changing unknowns** 또는 **3 rounds**)→잔여 `## Open questions` 이월+`## Interview log` Q/A 트레일(single-pass 스펙은 두 섹션 생략 명시); when_to_use에 플래그 발견성 추가; `core/hooks/spec-gate.py` 무변경(diff 0) | S–M |
| F-2 ✅ 2026-07-10 | **레포-네이티브 실행 기록** — `/supervise` 완료 리포트를 `.agent/plans/<slug>/RECORD.md`(waves·PR·audit verdict·이월 항목의 기계적 실행 원장)로도 기록 + `core/infra/supervisor-goal.sh` complete 시 스텁 자동 생성(goal-mode=결정적 보장층, 비goal-mode=스킬 규율). 세션-서사 기록(글로벌 레이어 소관)과 역할 분리 — 중복 아님 | 비-Claude 런타임(codex/gemini 어댑터) 환경에선 글로벌 기록 스킬이 없어 실행 기록 공백(2026-07-10 총점검 갭) | goal-mode 픽스처 complete 후 RECORD.md 존재 + 4필드(waves/PR/verdict/이월) grep + 기존 supervisor 스위트 회귀 0. ✅ 실측(2026-07-10): `supervisor-goal.sh complete`에 `write_record_stub`(기존 RECORD.md 무클로버·실패해도 완료 비차단 fail-safe·`AGENT_PLANS_DIR` seam·waves는 DB 라이브값) + supervise SKILL Step 5에 원장 규율(goal-mode=결정층/비goal=스킬 규율, 세션 서사와 역할분리 명시) + 신규 배터리 `core/tests/supervisor-goal-record-test.sh` 10체크(4필드·status JSON 소비자 계약·무클로버·fail-safe·seam; mktemp git 레포 격리). **동반 버그픽스**: `cmd_init`의 `local objective="${4:-${slug}}"` 동일-줄 참조가 bash 3.2+set-u에서 objective 생략 시 unbound 크래시(잠복 — 4-인자 호출만 통했음, 이 배터리가 최초 노출) → local 분리. **리뷰 하드닝**: slug 경로탈출(`../` 슬러그가 plans root 밖에 원장 생성) → 구분자·`..` 거부 fail-safe skip + 픽스처 (f) 2체크(총 12). 동일 프리-기존 패턴이 `_emit_graceful_wrap`에도 있음 — 후속 정리 후보로 기록 | S–M |

### 4.12 LE 시리즈 — Loop Engineering 감사 발굴 항목 (2026-07-11 추가)

출처: 2026-07-11 loop-engineering 감사(`docs/loop-engineering-audit-2026-07.md` — 기준: `docs/concepts/loop-engineering.md` 15항목 체크리스트, 외부 원천 Osmani 에세이 + cobusgreyling repo). 판정 요지 — 척추(maker/checker·bounded iteration·durable state·런 로그)는 정합, 최대 갭은 신뢰의 단위(세션-전역 env-var → per-project trust tier로 착수). 동반 PR에서 구현하는 것은 trust-tier 1건뿐이고 나머지는 등재만.

| ID | 작업 | 근거 | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| LE-1 | **plan-scope-allow 커버리지 확장 검토 — Bash/NotebookEdit/MCP** — 현재 Write\|Edit\|MultiEdit만 auto-allow라 supervise 웨이브의 테스트/git 명령은 여전히 프롬프트. 명령 문자열에서 대상 경로 파싱이 필요한데 약화 훅에서 파싱 오판 = false-allow이므로 별도 설계 문서 선행(안전 서브셋 allowlist 방식 등) | 감사 #8/#11 partial — 완전 위임의 실효를 막는 최대 마찰 지점 | 설계 문서 + (채택 시) 훅 확장 + RED 픽스처(경로 파싱 우회 시도 전부 silent) | M |
| LE-2 | **auto-ship/supervise의 trust-tier 소비** — collab 티어에서 `--auto-merge` 차단(ask), personal에서도 경로 allowlist 밖 auto-merge 금지 | 감사 #9 partial — "allowlist 없는 auto-merge 금지" 기준 | auto-ship.sh가 tier 조회 + collab 픽스처에서 차단 + allowlist 픽스처 | S–M |
| LE-3 | **전역 비용 상한 + kill switch** — goal-mode 밖에서도 세션/루프 토큰 예산과 즉시 정지 스위치 | 감사 #13 partial — Token Burn 실패 모드 | 예산 초과 픽스처에서 정지 기록 | M |
| LE-4 | **텔레메트리 기반 L-레벨 래칫** — plan-scope-allow.jsonl 등 발화 데이터로 프로젝트별 L1→L2→L3 승급/강등을 증거 기반으로 제안(자동 승급 아님 — 제안만, T-2 계측 계열) | 감사 #11 — 승급 게이트는 낙관이 아니라 증거 | digest가 프로젝트별 allow/deny 통계 + 승급 제안 출력 | M |
| LE-5 | **supervise 중 플랜 플래그 갱신** — 승인 플래그가 세션 시작 시 클리어되므로 재개된 supervise 세션은 재승인 전까지 auto-allow 없음. supervise가 approved plan 존재를 검증하고 플래그를 재수립하는 명시 경로 검토 | plan-scope-allow ↔ supervise 상호 참조 0 실측(2026-07-11) | supervise 재개 픽스처에서 플래그 재수립 + 위조 플랜 거부 | S–M |
| LE-6 | **anti-flake 규율** — completion_tests 실패의 flake 분류/격리(quarantine): 같은 테스트의 비결정 실패는 코드 "수정"이 아니라 격리 대상으로 라우팅 | 감사 #14 missing — "flake를 코드로 고치기" 안티패턴 | flake 픽스처(2회 중 1회 실패)가 quarantine 기록으로 라우팅 | M |
| LE-7 | **human synthesis cadence** — 루프/supervise가 쉬핑한 diff의 주기 다이제스트(읽을거리 1페이지) + "결정 필요할 때만 알림" 규율 명문화 | 감사 #7/#15 — comprehension debt·notification fatigue 무방비 | digest 스크립트 존재 + 주기 실행 문서화 | S–M |
| LE-8 | **런당 턴/디스패치 상한** — goal-mode에 토큰 예산과 별개의 디스패치 횟수 상한(SDK `max_turns` 아날로그): 초과 시 abort가 아니라 사용자 핸드오프 | 감사 §4 (2026-07-18 SDK 크로스체크) — Infinite Fix Loop의 SDK측 대응물이 하네스에 부재 | goal-state에 dispatch 카운터 + 상한 초과 픽스처에서 핸드오프 기록 | S–M |
| LE-9 | **fable-5 디스패치 프롬프트 감사 레인** — `concepts/fable-5-prompting.md` 규칙 2–4(anti-wrap-up·근거 인용·경계 명시)를 manager-audit의 검사 레인으로 승격(현재 advisory) | 같은 크로스체크 — 프롬프트 규율이 문서 관례로만 존재 | manager-audit.sh 신규 레인 + RED/GREEN 픽스처 | M |

---

## 5. Part 3 — `/harness-loop` 자율 개선 루프 설계 (단일 권고안)

autoresearch 패턴을 이 레포 자신에게 적용한다: **에이전트가 밤새 하네스(우선 리뷰어 프롬프트)를 실험적으로 개선하고, 분리된 그레이더가 채점하고, 사람은 PR만 리뷰한다.**

### 5.1 대응표

| autoresearch | harness-loop 대응물 | 설계 근거 |
|---|---|---|
| `program.md` (인간 편집 규정) | `skills/harness-loop/SKILL.md` — **인간만 편집**, 루프 규칙·금지사항 수록, 경량 유지 | 스킬이 이 레포의 관례적 "프로그램" 단위 |
| `train.py` (에이전트 편집 표면) | **미션당 TARGET 1개 선언.** 기본 미션: 리뷰어 프롬프트 쌍(`agents/code-reviewer.md` + `agents/security-reviewer.md`). 훅 표면 미션은 해당 per-hook 테스트(P1-3) 존재 시에만 허용 | 그레이더(벤치마크)가 정확히 리뷰어를 측정하므로 신호 직결. **TARGET 밖 diff는 그레이더가 자동 discard**(git diff 검사) = 물리적 경계(기둥③) |
| 고정 5분 예산 → 비교 가능성 | **고정 결함 세트**(`docs/benchmark/ground-truth.md` 8건) + 고정 입력 diff | 시간이 아니라 입력 고정으로 런 간 비교성 확보 |
| `val_bpb` (단일 스칼라) | `core/tests/grade.sh` 출력 = **실패모드 체크리스트**(단일 스칼라 아님, L-1). **두 경로 모두 마지막 줄에 `harness_score:` 방출**(§5.2 step5 grep 소비자 계약·§5.1 results.tsv status enum 유지 — 빈 grep=crash 오분류 방지): ⓐGATE(sanitize-audit·adapter-parity·hook-config-test·post-commit-autosync·gitleaks) 미통과 시 모드 체크 스킵 + **`harness_score: 0`** 방출 = `status=discard`. ⓑGATE 통과 시 `evals/failure-modes.yaml`의 명명된 실패모드마다 **`mode:<id> PASS\|FAIL — <근거 인용>`** 한 줄씩(모드별 verdict 나열 — 후보가 그 홀을 재도입했는지 적대적으로 판정) + 롤업 스칼라 **`harness_score: X.Y`**(= PASS 모드수 − 0.5×오탐수) 마지막 줄. *(체크리스트 정본 = `evals/failure-modes.yaml`, ≥8모드; grade.sh 구현 = B4 L-1 구현분)* | 단일 스칼라는 **어느** 실패모드가 재발했는지 은폐 → "검증 강화"로는 게이밍을 못 막음(arxiv.org/pdf/2604.15149, proxy-hacking 73.8% openreview ikrQWGgxYg). 모드별 boolean+근거 인용이 그레이더를 인간 적대 리뷰처럼 만듦. 모드 목록 = 이 캠페인 적대 리뷰 실적발(조용한 드롭·glob 누락·우회 플래그·false-CONFIRMED·infra-as-verdict 등)의 증류 = SSOT `evals/failure-modes.yaml`. 회귀 바닥(GATE=harness_score 0 방출로 discard)과 개선 신호(체크리스트) 분리 = 계층 검증 유지 |
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
P0-1 ~ P0-11 (최초 7건 반나절 + 훅 감사 배치 4건 2026-07-04)  → v0.2.1 태그
  └→ P1-1 doc-reality 게이트 · P1-2 verify-all   (P0 완료가 PASS 전제)
       └→ P1-3 per-hook 테스트 · P1-4 dispatch-not-advise · P1-5 텔레메트리 · P1-6 parity · P1-7 doctor · P1-8 hook-config 실배선 → v0.3.0
            └→ P2-1 ~ P2-5 (§5 조립)             → v0.3.x
```

- 각 마일스톤 커밋은 conventional commit(`docs:`/`fix:`/`feat:`/`test:`) + CHANGELOG 갱신.
- P2 착수 전 게이트: `bash core/tests/verify-all.sh` green + doc-reality green.
- **H/W 시리즈 편입 (2026-07-04)**: W-7(가드 오탐, S)은 P0급 위생으로 즉시 착수 가능. H-1·W-3·W-4는 P1과 병행(v0.3.0 트랙). H-2는 P1-1 완료 후, H-3은 P2-2와 채점 규약 공유(v0.3.x). H-4·W-1·W-2·W-6·W-8·W-9는 v0.3.x. W-5는 개인 레이어에서 진행(repo 마일스톤 밖).
- **2026-07-04 감사 배치**: P0 시리즈 전체(P0-1~P0-11) 완료 — 훅 배선 버그 3건(P0-8/9/11) + 환경 경고 1건(P0-10) 포함.
- **2026-07-05 P1 배치**: P1-4(dispatch-not-advise) · P1-5(telemetry-digest 재니터) · P1-7(--doctor) 출하, P1-8(hook-config 실로더 스키마) 부분 출하(스키마+소비 증명 테스트, 런타임 배선은 잔여).
- **T/E 시리즈 편입 (2026-07-07 캘리브레이션 감사)**: T-1(teaching gates)·T-3(부정 예제)은 S급으로 W-7과 함께 즉시 착수 가능. T-2(게이트 레지스트리+계측)는 P1-5 telemetry-digest의 직접 확장이며 **모든 게이트 강도 조정(완화·강화)의 선행 조건**. E-1(eval 승격)은 P3-5·H-3·P2-2 채점 규약을 공유하는 v0.3.x 병행 트랙.
- **O/L/I 시리즈 편입 (2026-07-08 레이어 통합 감사)**: I-1(매처 통합)·I-2(doctor 캐시/매니페스트 검사)는 S급 선행. O-1(supervise 계약 개정)이 오케스트레이션 트랙의 관문, O-2(`skills/loop`)가 그 위에서 §5 P2 루프의 실행체. L-1/L-2는 P2-2 착수 전 반영 필수(순서: E-1 → L-1/L-2 → P2). 상세 판정과 로컬 레이어 결정(레포 밖)은 별도 감사 기록 참조.
- **M 시리즈 편입 (2026-07-08 모델 티어링 감사)**: M-1~M-3(정본 문서·judge floor·템플릿 배선)은 S급 일괄 출하 — v0.2.4. M-4(doctor 프로파일 검사)는 I-2와 같은 관측자 계열로 백로그 적재.

## 7. 이 문서 자체의 검증

커밋 전 수행(전부 레포 루트 기준):

1. **산출물 카운트(SSOT — `doc-reality.sh`의 (C) 체크가 라이브 대조):** `ls core/hooks/*.py core/hooks/*.sh | wc -l` = **25**(`core/hooks`의 .py+.sh 파일; `hook_config.py`·`trust_tier.py` 공용 모듈, `agent-inventory.py` 리컨사일러, `brain-capture.py` 세션 캡처 훅 포함), `ls core/tests/*.sh | wc -l` = **56**, `ls agents/*.md | wc -l` = **3**, `ls skills/*/SKILL.md | wc -l` = **9**(brain-ingest·harness-audit·harness-help·manager-audit·persona-review·spec·supervise·verify-completion·wrap). §3.3 표의 훅·테스트 수치는 2026-07-04 스냅샷이며, 이후 증가분은 이 줄이 정본이다.
2. `bash core/tests/sanitize-audit.sh` — **PASS가 정상.** (P0-7 완료 이후로는 클린 워킹 트리에서 항상 PASS — 과거의 "FAIL이 정상" 예외는 P0-7 해소로 소멸)
3. `gitleaks detect --no-git --source docs/ --config gitleaks.toml`.
4. 백로그 항목 수 검증(2026-07-07 캘리브레이션 배치 갱신, 실측): `grep -cE '^\| P[0-3]-[0-9]+' docs/harness-improvement-plan.md` = **29** (P0 11 + P1 8 + P2 5 + P3 5), 각 행에 완료 조건 존재. H/W 시리즈: `grep -cE '^\| [HW]-[0-9]+' docs/harness-improvement-plan.md` = **14** (H 4 + W 10). T/E 시리즈: `grep -cE '^\| [TE]-[0-9]+' docs/harness-improvement-plan.md` = **5** (T 4 + E 1 — §4.8). O/L/I 시리즈: `grep -cE '^\| [OLI]-[0-9]+' docs/harness-improvement-plan.md` = **6** (O 2 + L 2 + I 2 — §4.9). M 시리즈: `grep -cE '^\| M-[0-9]+' docs/harness-improvement-plan.md` = **5** (M-1~M-3 ✅ + M-4·M-5 — §4.10). A/G 시리즈: `grep -cE '^\| [AG]-[0-9]+' docs/harness-improvement-plan.md` = **4** (A 2 + G 2; 완료 조건 대신 근거·상태 기재 — §4.6 참고). F 시리즈: `grep -cE '^\| F-[0-9]+' docs/harness-improvement-plan.md` = **2** (F-1·F-2 — §4.11).
5. 스코어카드(§3.1·§3.2)의 격차 행 ↔ 백로그 ID 상호 링크 고아 0건 (모든 "부분/미비" 행에 P* 링크 존재). `docs/benchmark/landscape.md`의 Gap→backlog 매핑표 ID도 본 문서에 전부 실존해야 함(고아 0).
6. AGENTS.md 규약 준수 — 도메인 중립 언어, 커밋 메시지 `docs(plan): add harness improvement plan`.

## 8. 참고 자료

| 자료 | 위치 |
|---|---|
| 영상: "프롬프트 엔지니어링은 끝났습니다: 이제 '하네스'의 시대입니다" (실밸개발자) | youtu.be/6gvnDSAcZww |
| 영상: "루프 엔지니어링 — '프롬프트하는 나'를 시스템으로 대체하는 법" (실밸개발자) | youtu.be/A7gwGNsL6y4 |
| 노션: 하네스 엔지니어링 완벽 가이드 (4기둥·의사코드 보충자료) | raspy-roll-970.notion.site/AI-333f7725c9d98147957afad16db3b655 |
| karpathy/autoresearch (README + program.md) | github.com/karpathy/autoresearch — 로컬 참조 클론: 드라이브 `_repos/reference/autoresearch` (`repos.yaml`의 `repoId: karpathy/autoresearch`, 클론 확인 2026-07-04) |
| revfactory/harness — 팀 아키텍처 팩토리(Apache-2.0): 6 팀 패턴, 메타 스킬 6-phase 워크플로우, with/without-skill A/B 검증 방법론 | github.com/revfactory/harness |
| 하네스 벤치마크 감사(2026-07-06) — 7종 개인 하네스 12차원 비교(§4.7 P3 시리즈 출처): 완료 게이트·상류 계획·서플라이체인·독립 검증자 | github.com/obra/superpowers · github.com/affaan-m/everything-claude-code · github.com/disler/claude-code-hooks-mastery · github.com/Chachamaru127/claude-code-harness · dev.to/joergmichno (ECC 213k★ 보안 감사) |
