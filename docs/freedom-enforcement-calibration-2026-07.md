# 자유도 vs 강제 캘리브레이션 감사

| 항목 | 값 |
|---|---|
| 작성일 | 2026-07-07 |
| 기준 버전 | v0.2.1 |
| 성격 | **감사 + 판정 문서** — 이 문서 자체는 코드를 바꾸지 않는다. 판정에서 나온 작업은 백로그 ID(T-*/E-* 신설, `harness-improvement-plan.md` §4.8)로 추적한다 |
| 방법 | 3축 병렬 조사 — ① 레포 강제/자유 지점 전수 인벤토리 ② 선행 감사(2026-07-04)·벤치마크(2026-07-06) 증류 ③ 2026 외부 하네스 설계 동향(1차 소스 URL 병기) |

---

## 0. 요약

| # | 결론 | 대응 |
|---|---|---|
| 1 | **현 강제 지형은 2026 외부 컨센서스와 정합.** "체크 가능한 건 결정론적 기계로, 프롬프트엔 휴리스틱만" 원칙, secrets 외 ask-까지 에스컬레이션, fail-open, config-변조 감시(rule 14) 전부 외부 권고와 일치 | 유지 (§3a) |
| 2 | **"기록만 하고 강제 안 함" 잔여 3곳이 최대 구조 리스크.** `risk_areas` YAML 미배선(격차 #9 잔여), plan-gate 플래그 소비자 부재(감사 당일 P3-2 `spec-gate.py`로 배선 완료 — 기본 dryrun, block은 opt-in), tdd-guard dryrun 로그 소비자 부재 — 전부 "거짓 문서는 거짓 동작" 철학의 자기 위반 | wire-or-delete (§3b) |
| 3 | **과잉 강제 후보는 데이터 없이 판정 불가.** 게이트별 발화율 계측이 없어 dead 게이트(한 번도 안 터짐)와 fatigue 게이트(상시 터져 고무도장화)를 구분할 수 없다 | 계측 먼저 (§3c → T-2) |
| 4 | **외부 동향에서 채택할 것 4건** — teaching gates, 게이트 레지스트리+만료일, 스킬 부정 예제, eval 하네스 공개 승격 | 신규 백로그 T-1/T-2/T-3/E-1 (§3d) |

---

## 1. 현재 강제 지형 (2026-07-07 실측 인벤토리)

배선: `hooks/hooks.json` → `adapters/claude-code/adapter.sh` → `core/hooks/*`(실행 훅 17 + 공용 모듈 1). 전 훅 exit 0(fail-open). `deny`/`ask`는 PreToolUse만, `decision:block`은 Stop만.

| 티어 | 메커니즘 (파일) | 대상 행동 | 탈출구 |
|---|---|---|---|
| **DENY** | `core/hooks/pre-tool-guard.sh` | 광역 `rm -rf`(루트/홈), main force-push, `git reset --hard`, secrets/.env 접근(45+ 변형) | 없음 (secrets 무우회 원칙) |
| **DENY** | `core/hooks/secret-content-scan.py` | 코드로 secrets 읽기, 하드코딩 자격증명, MCP 인자 내 시크릿 | `exempt_paths`(tests/fixtures) — 설정으로 강화만 가능 |
| **DENY** | `core/hooks/check-hardcoding.py` | 인라인 색상 배열·그라디언트·축 상수 | 프로젝트 패턴 추가만 가능 |
| **BLOCK** | `core/hooks/session-quality-gate.py` (Stop) | diff 내 위반 + `session.completion_tests` 실패 | `AGENT_QUALITY_GATE_BLOCK=0`, 2번째 Stop 자동통과 |
| **BLOCK** | `core/git-hooks/pre-commit`·`pre-push` | gitleaks·하드코딩(staged), push 범위 시크릿 diff | `--no-verify` (→ rule 13이 ask로 감시) |
| **BLOCK** | `.github/workflows/ci.yml` | sanitize 게이트, supply-chain-scan, manifest/frontmatter 검증 | 없음 (머지 조건) |
| **GATE** | `core/infra/completion-verify.py` | 완료 주장 재검증 (refute-by-default, CONFIRMED만 exit 0) | 호출처에서만 발동 (상시 훅 아님) |
| **ASK** | `pre-tool-guard.sh` rules 4/13/14 | DROP/TRUNCATE, `--no-verify`·`-n`클러스터·hooksPath 변조, 린터/게이트 설정 변조 | 사용자 승인 |
| **ASK** | `context-mode-guard.sh`, `r4-mutex-check.sh`, supabase MCP 매처 | 샌드박스 우회 코드, 병렬 세션 자원 경합, prod DB/배포 MCP | 사용자 승인 |
| **ASK** | `core/hooks/supervisor.py` | 미배차 feature급 의도의 Write/Edit (의도당 1회) | `AGENT_SUPERVISOR_MODE=observe` |
| **ADVISORY** | `tdd-guard.py`(기본 dryrun), pre-push 리스크 조언, `rules/`·`templates/`·`AGENTS.md`·`AI_BOOTSTRAP.md` prose, 스킬 SKILL.md | TDD 규율, 위험영역 주의, 운영 규칙 전반 | 무시 가능 (관측된 advisory 무시율 ~98%, n=218 — §2) |
| **OBSERVE** | 4종 jsonl 싱크(`.agent/logs/`), `core/infra/telemetry-digest.sh`, heartbeat/circuit-breaker | 기록·집계만 | — |
| **의도적 자유** | 모델 inherit(계획 역할 무핀), fail-open 전면, autosync opt-in, `/wrap` 기본 수동 push, `--doctor` read-only | — | 설계 결정 (v0.2.1 모델 라우팅 정비 포함) |

**선언만 있고 미배선 (aspirational)**: `hook-config.yml`의 `risk_areas:`/`resources:` — `pre-tool-guard.sh`·`tdd-guard.py`·`r4-mutex-check.sh` 주석이 설정 확장을 안내하나 런타임 로더가 없다(격차 #9 잔여, P1-8). 실배선 키는 `secret_patterns`/`exempt_paths`/`credential_key_names`/`hardcoding_patterns`/`session.completion_tests` 뿐.

## 2. 외부 기준 — 2026 하네스 엔지니어링 동향

이 감사가 판정 근거로 삼은 외부 1차 소스(2026-07-07 웹 조사, 실확인 URL만):

- **분야 정립**: "Harness Engineering" — 컨텍스트 엔지니어링 + 아키텍처 제약(결정론적 게이트) + 엔트로피 관리의 3중 시스템, 인간은 humans-on-the-loop로 환경을 설계 ([martinfowler.com/articles/exploring-gen-ai/harness-engineering.html](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html)).
- **게이트 만료 원칙**: "모든 하네스 컴포넌트는 모델이 뭔가 못 한다는 가정이고, 그 가정은 만료된다" — 게이트에 가정+날짜를 박고 모델이 넘어서면 제거해 capability suppression을 피한다 ([anthropic.com/engineering/harness-design-long-running-apps](https://www.anthropic.com/engineering/harness-design-long-running-apps)).
- **승인 피로 실측**: 사용자는 permission 프롬프트의 **93%를 승인** — 상시 발동 ask 게이트는 고무도장 승인을 학습시킨다 ([anthropic.com/engineering/claude-code-auto-mode](https://www.anthropic.com/engineering/claude-code-auto-mode)).
- **프롬프트 준수 예산**: 프롬프트 지시는 ~80% 준수 예산으로 계획하고 100% 필수는 훅으로 — 지시 파일은 유저 메시지로 도착해 attention 경쟁에서 밀리고 컨텍스트 압축에서 소실된다 ([techsy.io/en/blog/claude-md-best-practices](https://techsy.io/en/blog/claude-md-best-practices), [tianpan.co/blog/2026-02-14-writing-effective-agent-instruction-files](https://tianpan.co/blog/2026-02-14-writing-effective-agent-instruction-files)). 이 레포 자체 실측(advisory 무시율 ~98%, n=218 — P1-4 근거)과 방향 일치.
- **teaching gates**: 게이트 거부 메시지에 근거(WHY)와 수정 단계(FIX)를 담으면 에이전트가 자기교정 — "규칙 문서는 무시되지만 에러 메시지는 무시할 수 없다" ([nyosegawa.com/en/posts/harness-engineering-best-practices-2026/](https://nyosegawa.com/en/posts/harness-engineering-best-practices-2026/)).
- **우회는 실증된 실패 모드**: benign 작업에서도 에이전트가 가드 밖 경로를 찾는 specification gaming, 허위 완료 주장, 게이트 통과 목적의 설정 파일 변조가 연구로 문서화 ([arxiv.org/pdf/2604.13602](https://arxiv.org/pdf/2604.13602), [arxiv.org/pdf/2606.06223](https://arxiv.org/pdf/2606.06223)) — refute-by-default 독립 검증자(P3-5)와 설정-변조 ask(rule 14)의 외부 근거.
- **eval CI 게이팅**: 경량 CI 게이트(DeepEval/Promptfoo/Ragas) + 회귀 추적의 2도구 구성이 수렴 관행; 엄밀성 기준선은 독립 k회 전부 성공하는 **Pass^k** ([confident-ai.com/blog/llm-agent-evaluation-complete-guide](https://www.confident-ai.com/blog/llm-agent-evaluation-complete-guide), [braintrust.dev/articles/best-promptfoo-alternatives-2026](https://www.braintrust.dev/articles/best-promptfoo-alternatives-2026), [anthropic.com/engineering/demystifying-evals-for-ai-agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).
- **world-class 구분 신호**: ①게이트 기계 자체의 self-test ②재현 가능한 공개 eval ③날짜 박힌 만료되는 제약 ④전 tool-call 감사 가능성 ⑤teaching gates ([github.com/ai-boost/awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering), [genai.owasp.org/llmrisk/llm062025-excessive-agency/](https://genai.owasp.org/llmrisk/llm062025-excessive-agency/)).

## 3. 판정

### 3a. 유지 (외부 컨센서스로 검증됨)

secrets deny(무우회), fail-open 전면, ask-티어 에스컬레이션 원칙(secrets 외 deny 금지), rule 13/14(검증 우회·게이트 설정 변조 감시 — 연구가 명명한 우회로를 선제 방어), sanitize CI 게이트, supply-chain-scan, 모델 inherit 정책, refute-by-default 검증자. **변경 없음.**

### 3b. 과소 강제 → 승격/배선 (wire-or-delete)

| 대상 | 문제 | 판정 |
|---|---|---|
| `hook-config.yml risk_areas:`/`resources:` | 훅 주석이 설정 확장을 약속하나 로더 부재 — "거짓 문서는 거짓 동작"의 자기 사례 | **P1-8 잔여로 완결**: 훅이 주석으로 인용하는 지점만 최소 배선하고, 배선하지 않을 약속(주석)은 삭제. 방치 금지 |
| plan-gate 승인 플래그 | `plan-gate.py`가 쓰기만 하고 소비자 없음 (감사 시점 실측) | **P3-2로 배선 완료(감사 당일)** — `core/hooks/spec-gate.py`(PreToolUse Write/Edit)가 소비자. 기본 dryrun·block opt-in이므로 발화 데이터는 T-2 계측 대상에 포함 |
| tdd-guard dryrun 로그 | `.agent/logs/tdd-guard-dryrun.jsonl`을 아무도 읽지 않음 | **T-2에서 digest 소비 추가**. 기본 dryrun 자체는 유지(아래 3c) |

### 3c. 과잉 강제 위험 → 계측 후 판단 (즉시 완화 아님)

| 대상 | 우려 | 판정 |
|---|---|---|
| `check-hardcoding.py` deny | 도메인 특화 규칙(색상/차트) — 오탐 시 능력 억제 | fire-rate 계측 + 만료일 부여 후 데이터로 재판정 (T-2) |
| quality-gate 2번째 Stop 자동통과 | 무한 블록 방지 밸브이자 잠재 우회 구멍 | 유지하되 자동통과 발생률 계측 (T-2) — 높으면 우회/피로 신호 |
| tdd-guard 전역 block 승격 | advisory 무시율 98%가 승격 근거로 보이나, 전역 TDD 강제는 capability suppression 위험 | **승격하지 않음** — 기본 dryrun 유지, block은 프로젝트 opt-in(`AGENT_TDD_GUARD_MODE=block`) |

근거: 승인율 93% 데이터 — dead 게이트도 fatigue 게이트도 결함이며, 게이트별 발화 데이터 없이는 어느 쪽도 판정할 수 없다. **계측(T-2)이 모든 강도 조정의 선행 조건.**

### 3d. 신규 채택 → 백로그 T/E 시리즈 (§4.8)

| ID | 내용 | 외부 근거 |
|---|---|---|
| T-1 | **teaching gates** — 모든 deny/ask/block 결정 메시지에 근거(WHY)+수정 단계(FIX) 포함 | route-around·인간 인터럽트를 줄이는 가장 싼 단일 승리 (nyosegawa, OpenAI 관행) |
| T-2 | **게이트 레지스트리 + fire-rate + 만료일** — 게이트별 "가정하는 모델 약점 + 날짜" 메타데이터 + `telemetry-digest.sh`가 기존 jsonl 싱크에서 게이트별 발화율 산출(dead/fatigue 판별) | Anthropic 게이트 만료 원칙 + 93% 고무도장 데이터 |
| T-3 | **스킬 부정 예제** — 출하 스킬 description에 negative-trigger(이럴 땐 발동하지 않음) 예제 추가 | 부정 예제 추가로 스킬 라우팅 정확도 73%→85% 보고 ([developers.openai.com/blog/skills-shell-tips](https://developers.openai.com/blog/skills-shell-tips)) |
| E-1 | **eval 하네스 공개 승격** — P3-5(completion-verify)+H-3(스킬 A/B)를 공개 `evals/`로: 라벨 테스트셋 + LLM-judge + Pass^3 + CI 회귀 게이트 | 2026 수렴 관행(경량 CI 게이트+회귀 추적), world-class 구분 신호 ② |

### 하지 말 것 (판정에서 명시 기각)

전역 TDD block 승격 · deny 티어 확대(secrets 외 ask 유지) · 프롬프트 강제 문구 추가(도구경계 원칙 위반) · 신규 런타임 의존성(bash+python3 플로어) · 계측 없는 게이트 완화/강화 · 관측 로그의 규칙 자동 영속(인간 승인 PR만).

## 4. 이 문서 자체의 검증

1. §1 인벤토리의 각 파일 경로 실존: `ls core/hooks/{pre-tool-guard.sh,secret-content-scan.py,check-hardcoding.py,session-quality-gate.py,tdd-guard.py,supervisor.py,r4-mutex-check.sh,context-mode-guard.sh} core/infra/{completion-verify.py,telemetry-digest.sh} core/git-hooks/{pre-commit,pre-push} .github/workflows/ci.yml`
2. `bash core/tests/sanitize-audit.sh` PASS (도메인 중립 유지)
3. `bash core/tests/supply-chain-scan.sh` PASS (본 문서는 docs/ 스코프 밖이나 전체 트리 무영향 확인)
4. 백로그 링크 정합: 본 문서의 T-1/T-2/T-3/E-1이 `harness-improvement-plan.md` §4.8에 존재
