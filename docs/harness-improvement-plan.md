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

- **현황**: v0.2.0. 4계층 구조(L1 `core/hooks/` 정본 → L2 `adapters/` → L3 `templates/` → L4 프로젝트), 실행 훅 17개 + 공용 모듈 1개(`hook_config.py`), 에이전트 2종(`code-reviewer`/`security-reviewer`), 스킬 2종(`supervise`/`wrap`), 리뷰어 벤치마크 8/8 검출·오탐 0(`docs/benchmark/results.md`). **2026-07-04 트림**: 에이전트 5→2·스킬 4→2(제거분은 `legacy/trim-2026-07-04/`에 보존), codex-skills는 legacy로 은퇴 — 근거·상세는 §4.6 A-0.
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
| 4 | **축소 이력 미기록** — `CHANGELOG.md:40-42`(0.1.0)는 에이전트 10종·스킬 16종·codex-skills를 나열하나 현재 2종/2종. 0.2.0에 Removed 기록 없음 **✅ P0-4로 해소(기존 커밋, 2026-07-04 표기 갱신)** | `ls agents/*.md \| wc -l` → 2, `ls -d skills/*/ \| wc -l` → 2; CHANGELOG Removed 섹션에 10→5(0.2.0)·5→2/4→2(2026-07-04) 트림 이력 존재 |
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
| P1-1 | **doc-reality 게이트** `core/tests/doc-reality-test.sh` 신설 — 문서 내 참조 경로 실존 검증 + 수치 클레임(훅/에이전트/스킬 수) 실측 대조. `ci.yml`에 잡 추가. 격차 #1·#3·#4 재발 방지의 규칙화(기둥②의 자기 적용) | 기둥② | P0 이전 README에 FAIL, P0 이후 PASS 데모; CI 등록 | M |
| P1-2 | `core/tests/verify-all.sh` 실구현 — 실존 테스트 4종 + doc-reality + gitleaks 묶음 러너(README Quick commands 약속 이행) | 격차 #1 | `bash core/tests/verify-all.sh` exit 0, 하위 테스트별 pass/fail 라인 출력 | S–M |
| P1-3 부분 진행 2026-07-06 | per-hook 단위 테스트 ≥4개(`pre-tool-guard`, `secret-content-scan`, `plan-gate`, `tdd-guard` 우선) — synthetic event JSON → decision JSON 픽스처. **P2 그레이더 확장의 선행 조건** | 루프 요소⑤ | `core/tests/<hook>-test.sh` ≥4개 존재, verify-all에 포함. 진행: `pre-tool-guard-test.sh`(16체크, P3-3) + `quality-gate-completion-test.sh`(11체크, P3-1) 신설, `secret-content-scan`은 `hook-config-test.sh`가 커버 — `plan-gate`·`tdd-guard` 전용 테스트 + verify-all 묶음(P1-2)이 잔여 | M–L |
| P1-4 ✅ 2026-07-05 (재정의 2026-07-04) | **dispatch, not advise** — `supervisor.py`가 권고 힌트(`systemMessage`)가 아니라 라우팅 결정을 내리게 한다: master-registry `matches.keywords` 매칭 후 specialist 미지정 feature급 의도엔 `ask`. 근거: advisory 힌트는 세션 로그 218건 감사에서 무시율 ~98%(관측) — 프롬프트는 부탁이지 강제가 아니므로 결정 자체를 훅이 내려야 함(기둥③ 자기 적용) | 격차 #5 + 훅 감사(advisory 무시율 ~98%, n=218) | synthetic prompt 이벤트 테스트 통과, `supervisor.jsonl`에 매칭 기록 + `ask` 발동(힌트가 아니라 결정) 확인 — ✅ 실측(2026-07-05): synthetic 이벤트 스위트 30/30 pass, `supervisor.jsonl`에 match/ask-intent/dispatched/ghost 기록 확인, `ask`는 힌트가 아니라 PreToolUse 결정 JSON으로 반환 (`f9af460` red 테스트 + `8d1a789` 구현) | M |
| P1-5 ✅ 2026-07-05 | 텔레메트리 소비(기둥④ 1단계 재니터) — `core/infra/telemetry-digest.sh`: `supervisor.jsonl` deny/ask 통계 → 규칙 후보 리포트 | 기둥④ | 샘플 로그 입력 → 요약 출력 검증 — ✅ 실측(2026-07-05, 리스펙 반영 재구현): action별 카운트 + specialist 퍼널(match→ask→dispatched, 전환율) + 상위 keyword + `NO-ACCEPT`(반복 ask에도 미배차)·`GHOST`(고스트 스페셜리스트)·`OVER-GENERAL`(단일 keyword가 전체 match의 >70%) 3종 규칙후보, `--window`(기본 30일)·`--json` 지원, 의존성 bash+python3만(jq 없음 — 1차 초안이 썼던 jq는 `setup.sh --doctor`의 jq WARN-tier 판정과 모순이라 리스펙에서 구조적으로 제거). 픽스처 스위트 21/21 pass(레거시 v0.1 레코드 degrade 3체크 포함). 커밋: red 테스트 2회(`32495e6`→`1914987`) + 구현 재작성(jq 기반 `9d9c4ad`/`79e3452`를 bash+python3 전용으로 교체). 1차 라운드는 `agent-harness:code-reviewer` 리뷰(needs-changes → 반영·재검증) 거침 | M |
| P1-6 | `cross-ai-parity.sh` 실구현 — `adapter-parity.sh` 확장: 동일 논리 이벤트 → 3 adapter → 동일 decision | 격차 #1 | README Verification 절 명령이 실제 통과 | M |
| P1-7 ✅ 2026-07-05 (신설) | `setup.sh --doctor` 정식 환경 진단 신설 — gitleaks/git 존재, python3 버전 플로어(3.9+), 훅 실행권한(`+x`), adapter 존재 여부를 한 번에 점검 | P0-10의 확장(임시 stderr 경고 → 정식 서브커맨드) | `bash setup.sh --doctor` 실행 시 각 항목 OK/WARN/FAIL 출력, 누락 시나리오 픽스처로 검증 — ✅ 실측(2026-07-05, `bb393d8`): 이 머신에서 `doctor: 9 pass, 0 warn, 0 fail`, 픽스처 3종(클린 레포/gitleaks 부재/훅 실행권한 결여) 전부 통과 | S–M |
| P1-8 부분 완료 2026-07-05 (신설) | hook-config.yml 실배선 — `risk_areas:`/`resources:`를 런타임에 실제로 읽게 만들거나(최소한 `templates/hook-config.yml.template`에 `hook_config.py`가 실제 소비하는 `secret_patterns`/`exempt_paths`/`credential_key_names` 스키마를 포함시켜), 문서상 선언과 실제 로더 사이 간극을 좁힌다 | 격차 #9 | 템플릿의 키가 통합 테스트에서 실제로 소비됨을 증명(예: `core/tests/hook-config-test.sh` 확장) — 스키마 출하+소비 증명 테스트 ✅ 2026-07-05(`2ab9428`, 템플릿에 `LIVE-SCHEMA-EXAMPLE` 블록 + `hook-config-test.sh` case h 드리프트 가드); `risk_areas:`/`resources:`/`hardcoding:`를 실제 훅 런타임에 배선하는 잔여 작업은 미완료 | M–L |

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
| H-2 | 하네스 점검·감사 모드 — P1-1 doc-reality 게이트·registry drift·훅 수·sanitize-audit를 묶어 실행하고 보고서를 내는 유지보수 스킬. P1-1은 기계 게이트(CI), H-2는 그 소비자(에이전트 주도 감사) — 중복이 아닌 계층 관계 | 기둥④ 재니터의 실행 진입점 부재 | 드라이런 1회에 검사 항목별 pass/fail 표 출력 + P1-1 결과 인용 | M (P1-1 이후) |
| H-3 | 스킬 A/B 테스트 하네스 — 출하 스킬 4종 대상 with-skill vs baseline 병렬 비교 + assertion 채점 + description 트리거 검증. P2-2 grade.sh(측정 대상=에이전트)와 채점 규약(GATE+단일 스칼라)만 공유하는 별도 항목 | 스킬 설명·트리거 효과가 미검증 | 스킬당 assertion ≥3, 리포트에 n·한계 고지 필수 기재 | L (P2-2와 병행) |
| H-4 | `/project-init` 메타 팩토리 라이트 — 대상 프로젝트 도메인 분석 → `hook-config.yml risk_areas` 초안 + `.agent/` 특화 파일 제안 자동 생성 | 신규 프로젝트마다 risk_areas 수작업 | 샘플 프로젝트 실행 시 risk_areas 5키 초안 + 특화 제안 ≥1 생성, sanitize-audit PASS 유지 | M |

### 4.5 W 시리즈 — 개인 워크플로우 통합 항목 (2026-07-04 추가)

출처: 개인 지식 볼트 워크플로우 분석(2026-07-04, 실측 페인 기록 기반). **배치 원칙**: 이 레포는 공개·도메인 중립(sanitize 게이트 상시)이므로 개인 경로·볼트명은 하드코딩 금지 — repo에는 **설정 주도 제네릭 구현**만 싣고, 개인 경로 와이어링은 글로벌 레이어(사용자 홈 AI 런타임 설정)에서 한다. 개인 볼트는 프로젝트 훅이 없는 드라이브 루트에 있으므로 W-1·W-6류는 글로벌 훅으로만 발화 가능. **에스컬레이션 원칙**: secrets를 제외한 모든 가드는 deny가 아니라 ask까지만(가시성 우선 원칙).

| ID | 작업 | 근거(실측 페인) | 완료 조건 (기계 검증) | 규모 | 배치 |
|---|---|---|---|---|---|
| W-7 | 가드 오탐 2건 수정 — ① `git commit -m` 메시지 본문을 파괴적 명령 스캔에서 제외 ② pipefail 하 `grep \| wc` 0-매치 false-abort 수정 | 정상 커밋·집계 명령이 가드에 차단된 실사례 | 픽스처: 파괴 명령을 "언급만" 하는 커밋 메시지 통과 + 0-매치 파이프 비중단 | S | repo |
| W-3 | 시크릿 게이트 잔여분 — `.git/config` 원격 URL 토큰 스캔(pre-push) + `/wrap`에 합성 키 소화(fire-test) 단계(가짜 키 플랜트 → gitleaks 검출 확인 → 제거). ※ nvapi- 룰은 2026-07-04 출하 완료 | 리모트 URL 토큰은 파일 스캔 사각지대 | 토큰 포함 URL push 차단; fire-test는 합성 키 미검출 시 FAIL | S–M | repo |
| W-4 | `/verify-claims` 스킬 — writer/reviewer/verifier 3-레인 "진실 방화벽". 이력서·블로그·포트폴리오류 공개물의 미검증 주장을 출판 전 게이트(ask) | 특정 프로젝트에서 검증 레인 효과 기입증 → 이식 | 미검증 주장 포함 픽스처 문서 → 주장 목록 + ask 발동 | M | repo |
| W-1 | freshness-watchdog — SessionStart 글로벌 훅(제네릭): 설정 파일에 등록된 감시 대상(잡 하트비트·필수 경로)의 신선도/실존 검사, 실패 시 경고(ask 이하) | 개인 동기화 크론 무음 사망 ×3, 드라이브 재구성 3회의 사경로 잔존 | 합성 stale 하트비트 → 경고 발화; 설정 부재 시 no-op | M | 혼합(훅=repo, 감시 목록=개인) |
| W-2 | `/reorg-sync` 스킬 — 이전/신규 경로 접두어를 인자로 받아 고아 참조 일괄 스윕(앵커·crontab·셔뱅·worktree gitfile·네이티브 메모리 키) | 드라이브 재구성마다 수작업 스윕 반복 | 픽스처 트리에서 5종 참조 전부 검출·치환 리포트 | M–L | repo(제네릭; 경로는 인자) |
| W-8 | plan-gate 소스 우선 검증 — 메모리 파편은 트리거로만, 플랜의 사실 주장은 라이브 소스 재확인 요구 | 낡은 메모리 인용이 플랜에 그대로 유입 | 메모리-인용만 있는 합성 플랜 → 소스 재확인 요구(ask) | M | repo |
| W-6 | 세션 종료 품질 게이트 일반화 — hook-config `session.close_checks`(임의 명령 리스트, 실패 시 ask)를 Stop 훅에 추가; 볼트 린트·통계 정합 명령은 개인 레이어에서 등록 | 수동 세션 마감 리추얼의 자동화 요구 | close_checks 실패 픽스처 → Stop에서 ask; 미설정 시 무동작 | M | 혼합 |
| W-5 | 증류 리추얼 자율 루프 — `/supervise --goal-mode` 재사용: 원시 수집 → 월간 다이제스트 → 린트 0 → 승인 게이트 | 수집만 쌓이고 증류가 밀리는 만성 적체 | (개인 레이어) 1주기 실행 로그 + 승인 게이트 통과 기록 | L | 개인 레이어(repo 밖; repo는 goal-mode 그대로 제공) |
| W-9 신설 | 웹 성능 완주 루프 — Lighthouse 4카테고리(Performance/Accessibility/Best Practices/SEO) 90+ 목표, 분리된 외부 그레이더(Lighthouse CI)로 채점, `/supervise --goal-mode` 재사용 | 개인 웹 프로젝트의 성능 회귀가 방치되는 패턴(실측 페인) | Lighthouse CI 실행 → 4카테고리 스코어 리포트 생성, 목표 미달 시 goal-mode 재시도 기록 | L | 개인(웹 프로젝트) |

### 4.6 A/G 시리즈 — 에이전트 재설계·글로벌 통합 (2026-07-04 감사)

출처: 2026-07-04 에이전트/스킬 트림 감사(A) + 글로벌 훅 레이어 통합 결정(G). A는 축소 방향 결정, G는 배치 결정 — 신규 작업 항목이 아니라 **결정 기록**이므로 완료 조건 대신 근거·상태를 기재한다.

| ID | 항목 | 근거 | 상태 / 완료 조건 | 규모 |
|---|---|---|---|---|
| A-0 ✅ 2026-07-04 | 에이전트 5→2(`code-reviewer`/`security-reviewer`), 스킬 4→2(`supervise`/`wrap`), codex-skills 은퇴(→`legacy/`) | 7주 세션 텔레메트리 감사 결과 나머지 3 에이전트·2 스킬 디스패치 0건 | 트림 완료 — 제거 항목은 `legacy/trim-2026-07-04/`에서 복구 가능(`163c73d`·`d847195`·`d6b45a9`) | S |
| A-1 보류 | `doc-writer`/`verifier` 등 신규 에이전트 추가 | 수요 미검증 — A-0과 반대 방향(확장) 결정이라 별도 증거 기준 필요 | 착수하지 않음. 재상정 조건: 실사용 요청이 누적되면 재검토 | — |
| G-1 결정 기록 | 글로벌 훅 일원화 = **Variant A**(이 플러그인 하네스로 통일, legacy global hook set 제거) | 두 하네스 병존 시 훅 충돌·중복 실행 위험 | 실행은 이 레포 밖 글로벌 레이어(사용자 홈 AI 런타임 설정)에서 진행(2026-07-04) — 레포 자체는 변경 없음, 결정만 기록 | — |

### 4.7 P3 시리즈 — 외부 하네스 벤치마크 발굴 항목 (2026-07-06 추가)

출처: 2026-07 GitHub 최상위 개인 하네스 8종(superpowers 247k★ / ECC 226k★ / karpathy-skills 188k★ / gstack 120k★ / revfactory 8.2k★ / showcase 6.0k★ / hooks-mastery 3.8k★ / Chachamaru 2.9k★)과 12차원 기능 분류 체계 비교 감사. 채택 기준은 **스타 수가 아니라 메커니즘의 실증 가치** — 카탈로그 극대화(ECC 277 스킬·gstack 60+)·프롬프트 강제("YOU DO NOT HAVE A CHOICE")·간접주입 영속화(ECC observer-loop 보안 감사 지적)·자기채점 벤치마크·실험 API 의존은 이 레포 설계 원칙(도메인 중립·의존성 플로어 bash+python3·"관측자는 차단하지 않는다" 재니터 계약·증거 기반 트림)과 충돌하므로 의도적으로 배제한다. 아래 5건은 "결정적 게이트로 완료·안전을 강화"하는 우리 노선에 정합하는 것만 선별했다.

| ID | 작업 | 근거 (출처) | 완료 조건 (기계 검증) | 규모 |
|---|---|---|---|---|
| P3-1 ✅ 2026-07-06 | 완료 게이트 테스트 실검증 — `core/hooks/session-quality-gate.py`에 hook-config 주도 테스트 명령(`session.completion_tests`) 실행 추가, 실패 시 `block`(Stop 훅은 `ask` 불가 — 기존 게이트와 동일하게 `decision:block` + exit 0). 미설정 시 no-op | Stop 게이트가 스타일/하드코딩/console.log만 검사하고 테스트 통과는 미검증 — hooks-mastery(Stop 훅이 필수파일·export·테스트통과 검사 후 완료 허용)와 ECC(`--no-verify` 결정적 차단)가 독립적으로 같은 패턴 | ✅ `hook_config.load_session_config`(fail-safe·bounded) + `session-quality-gate.py` 실행(per-cmd 타임아웃, 2nd-Stop/advisory 우회, always-exit-0). 테스트 `core/tests/quality-gate-completion-test.sh` 21/21 (실패→block, 통과→no-op, malformed→fail-safe, YAML 경로, 비숫자 타임아웃, 프로세스그룹 격리, 타임아웃→block, 로더 상한 — 적대적 리뷰 하드닝 포함) | S–M |
| P3-2 | 상류 계획 규율 스킬 `/spec` — brainstorm→spec→plan 산출 후 `plan-gate.py`가 승인 게이트. superpowers 워크플로 **내용만** 차용하되 프롬프트 강제가 아닌 도구경계 게이트로 강제 | `/supervise`가 프롬프트→디스패치로 직행, spec/plan 규율 부재로 디스패치 신호 품질 저하. superpowers 방법론이 생태계 최고 호평(비판은 비용뿐) | `/spec` 실행 → `spec.md`+`plan.md` 생성 + plan-gate 승인 플래그 세트(플래그는 `plan-gate.py`가 쓰고, 미승인 시 디스패치를 막는 것은 PreToolUse enforcer가 소비) | M |
| P3-3 ✅ 2026-07-06 | `--no-verify`·린터 설정 변조 차단 — `core/hooks/pre-tool-guard.sh`에 `git commit --no-verify`/`git push --no-verify`(+ `git commit -n`) + 린터 설정 파일 수정 감지 추가 → `ask` | 현 가드는 삭제/force-push/.env만 차단, 검증 우회 커밋·린터 무력화는 사각지대. ECC가 린터 설정 수정 대신 코드 수정을 강제 — 우리 "도구경계=물리차단" 강점의 직접 확장 | ✅ no-verify 커밋/푸시 픽스처 `ask`(되돌릴 수 있는 게이트 우회 = 에스컬레이션 원칙상 ask); `git push -n`(dry-run)·정상 커밋 통과(오탐 0); 린터 설정 Bash 변조 픽스처 `ask`, 읽기는 통과. 신규 테스트 `core/tests/pre-tool-guard-test.sh` 28/28(기존 규칙 회귀 + 적대적 리뷰 하드닝: 번들 단축플래그 `-nm`·`git -c`·`core.hooksPath=`·메시지 오탐·리다이렉트 오탐 — 이 훅 최초 테스트) | S |
| P3-4 | 자기 하네스 서플라이체인 스캔 — 출하 스킬·훅·에이전트 파일의 주입성 지시(자동 실행 지시·"확인 요청 금지" 문구·백그라운드 서브프로세스 기동) 정적 스캔 테스트. `core/tests/`에 추가 | 대규모 하네스의 자동 로드 지시 파일이 간접 주입 벡터가 된 실사례(ECC 공개 감사, 당시 213k★·현재 226k★: 513 자동 로드 지시 파일, 64 에이전트 중 49에 Bash, observer-loop 무인 영속화). 우리 도메인 중립 sanitize 게이트와 시너지 | observer-loop류 패턴을 심은 픽스처 파일 검출; 클린 트리 통과; CI 편입 | M |
| P3-5 ✅ 2026-07-06 | 완료주장 독립 검증자 — wave/작업 완료 시 별개 컨텍스트 검증자가 완료주장(파일 존재·테스트 통과·주장↔산출물 정합)을 재검토. H-3 스킬 A/B 채점 규약과 LLM-judge 채점 계층 공유 | hooks-mastery builder-validator 패턴(빌더와 별개 context가 재검토). "테스트 통과 ≠ 실제 동작" 전훈의 구조화 + LLM 출력 품질 평가 하네스의 씨앗 | ✅ Layer1 `core/infra/completion-verify.py`(결정적: 파일존재+substring·테스트 exit0·assertion → 공유 verdict JSON, refute-by-default, fail-safe·bounded, start_new_session+timeout가드) + Layer2 스킬 `skills/verify-completion/SKILL.md`(독립컨텍스트 의미 judge) + 공유규약 `docs/scoring-convention.md`(supervisor-goal-audit 25점과 조화). 테스트 `core/tests/completion-verify-test.sh` 15/15(허위주장→REFUTED·정합→CONFIRMED·malformed fail-safe·YAML·프로세스그룹 격리) | M–L |

출처 URL: superpowers(github.com/obra/superpowers), ECC 및 보안 감사(github.com/affaan-m/everything-claude-code, dev.to/joergmichno "We Audited the Viral 213k-Star ECC Repo"), hooks-mastery(github.com/disler/claude-code-hooks-mastery), Chachamaru Go-네이티브 게이트(github.com/Chachamaru127/claude-code-harness). skip 결정 및 커리어 연계 상세는 개인 볼트 감사 리포트에 별도 기록(공개 레포 반입 제외).

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

## 7. 이 문서 자체의 검증

커밋 전 수행(전부 레포 루트 기준):

1. §3.3 표의 각 검증 명령을 실행해 실측 결과 열과 대조 — 훅 17, 테스트 4, 에이전트 2, 스킬 2.
2. `bash core/tests/sanitize-audit.sh` — **PASS가 정상.** (P0-7 완료 이후로는 클린 워킹 트리에서 항상 PASS — 과거의 "FAIL이 정상" 예외는 P0-7 해소로 소멸)
3. `gitleaks detect --no-git --source docs/ --config gitleaks.toml`.
4. 백로그 항목 수 검증(2026-07-06 벤치마크 배치 갱신, 실측): `grep -cE '^\| P[0-3]-[0-9]+' docs/harness-improvement-plan.md` = **29** (P0 11 + P1 8 + P2 5 + P3 5), 각 행에 완료 조건 존재. H/W 시리즈: `grep -cE '^\| [HW]-[0-9]+' docs/harness-improvement-plan.md` = **13** (H 4 + W 9). A/G 시리즈: `grep -cE '^\| [AG]-[0-9]+' docs/harness-improvement-plan.md` = **3** (A 2 + G 1; 완료 조건 대신 근거·상태 기재 — §4.6 참고).
5. 스코어카드(§3.1·§3.2)의 격차 행 ↔ 백로그 ID 상호 링크 고아 0건 (모든 "부분/미비" 행에 P* 링크 존재).
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
