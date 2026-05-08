# Matt Pocock Skills 도입 정책

## 목적

`mattpocock/skills` (MIT, commit `b843cb5e`, 2026-05-05) 에서 6 skill 을 AirLens `.claude/skills/` 로 선별 이식. 이 룰은 도입 범위·네이밍 충돌 회피·라이선스 의무·운영 한계를 정한다.

## 도입 범위

### 도입 (6)

| Skill | 카테고리 (Matt) | 도입 사유 |
|---|---|---|
| `grill-with-docs` | engineering | 도메인 용어·문서·ADR 정합 검증 (AirLens `wiki-auto-index.py` 는 인덱싱만, 변경 영향 분석 부재) |
| `grill-me` | productivity | 순수 grilling. `grill-with-docs` 보다 가벼운 sanity check 용 |
| `tdd` | engineering | RGR 사이클 명시. 기존 `scripts/hooks/tdd-guard.sh` (test 파일 존재만) 의 약점을 대화형으로 보강 |
| `diagnose` | engineering | 6-step debug framework. gstack `/investigate` 와 직교 |
| `improve-codebase-architecture` | engineering | 모듈 깊이화·아키텍처 리팩토링 후보 식별. `feedback_monorepo_extraction_policy` 와 정합 |
| `caveman` | productivity | 토큰 ~75% 절감. opt-in 슬래시만 (영구 활성 X) |

### 제외 (2)

| Skill | 제외 사유 |
|---|---|
| `git-guardrails-claude-code` | gitleaks 3층 방어 (`gitleaks.toml` + `scripts/git-hooks/check-staged.py` + `.github/workflows/secret-scan.yml`) 로 완전 커버. 중복 유지보수 회피 |
| `setup-matt-pocock-skills` | AirLens 는 `Obsidian-airlens/raw/docs/` LLM Wiki 정본 체계 이미 구축 (정본 9+1+3+Agent Harness = 13 체계). 자동 setup 불필요 |

기타 (`to-issues`, `to-prd`, `triage`, `zoom-out`, `write-a-skill`, `migrate-to-shoehorn`, `scaffold-exercises`, `setup-pre-commit`) 는 본 라운드 범위 밖. 향후 별 plan.

## 네이밍 충돌 회피

### `/tdd` skill ↔ `scripts/hooks/tdd-guard.sh` hook
- hook = PreToolUse Write 자동 차단 (test 파일 존재 검증)
- skill = 사용자 invoke 대화형 (RGR 사이클 안내)
- **공존**: hook 우선, skill 은 결과 해석·다음 사이클 안내
- 충돌 없음 — hook 은 자동 가드, skill 은 prompt-pattern

### `/diagnose` skill ↔ gstack `/investigate`
- `/investigate` = 4-phase root cause (Investigate → Analyze → Hypothesize → Implement)
- `/diagnose` = 6-step feedback-loop framework
- **라우팅**:
  - 단일 stack trace + 빠른 fix → `/investigate`
  - 재현 어려움 + feedback loop 미구축 + 성능 회귀 → `/diagnose`

### `/grill-with-docs` ↔ `/grill-me`
- `/grill-with-docs` = grilling + PRD §Glossary / ADR 갱신
- `/grill-me` = 순수 grilling (문서 갱신 없음, 가벼운 sanity check)

## 라이선스

MIT. 원본 LICENSE + commit hash + 도입 일자 = `.claude/skills/.matt-pocock-license`.
원본 SKILL.md 본문 수정 시 본 파일 §History 누적 기록.

```
Source: github.com/mattpocock/skills
Commit: b843cb5ea74b1fe5e58a0fc23cddef9e66076fb8
Adopted: 2026-05-05
```

## 한국어 / 정본 정합 강제

- 모든 SKILL.md 본문은 영어 그대로 두되 첫 머리에 "_AirLens 정본 매핑_" 블록 + "응답은 **한국어**" 1줄 추가.
- `CONTEXT.md` 참조 → 영역별 `Obsidian-airlens/raw/docs/{platform,web,app,ml,db}/PRD.md`.
- `docs/adr/<n>-*.md` → `Obsidian-airlens/raw/docs/architecture/<topic>-YYYY-MM-DD.md` (date prefix 패턴 기존 사용 중).
- supersede 마커 누적 — `wiki-auto-index.py` 가 자동 카테고리화.

## `/caveman` 적용 한계 (CRITICAL)

본 § 5 항목은 *caveman brevity 예외* — 자동화 5 가드 영역 (`security-guards.md`) 과 부분 overlap (특히 §3 Destructive 확인 = 자동화 가드 §1 production migration). scope 다름 (brevity vs 자동화 회피) 이라 독립 § 유지.

활성 시에도 다음 영역은 **풀 문장 유지** (CLAUDE.md Glass-box 원칙 우선):

1. ML/예측 출력의 **불확실성** (p10-p90, DQSS 배지) — 단정 금지
2. **보안 경고** (secret 접근, RLS 위반)
3. **Destructive 확인** (production migration, force-push, DROP TABLE)
4. **Multi-step 순서** (rebase·deploy 절차)
5. **사용자 재질문** 시 한 번 물어본 걸 다시 물으면 caveman 일시 해제

기본 비활성, opt-in 슬래시 (`/caveman`) 만 활성. "stop caveman" / "normal mode" 로 해제.

## 운영 — 1개월 spot check

- T+7d: 6 skill 각각 1회 invoke 후 한국어 흐름 자연스러운지 spot check. 어색하면 본문 일부 번역 (별 plan).
- T+14d: `/diagnose` vs `/investigate` 사용 빈도 추적. 한쪽 사용 0 이면 alias 처리 검토.
- T+30d: `Obsidian-airlens/raw/docs/architecture/` 신규 ADR 누적 확인. 30일에 5건 초과면 wiki size 정책 검토.

## History

- 2026-05-05 — 초기 도입. 6 skill + license + 본 룰 + CLAUDE.md/AGENT_HARNESS.md 갱신.
- 2026-05-06 — codex 외부 강연 audit 3종 (Advanced Context Engineering · AI Agent Workflow · AI Automation Founder) 흡수 시 `/grill-me` · `/tdd` · `/improve-codebase-architecture` 패턴 재확인 (alignment-first / RGR / deep modules). [[Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md]] §15.2 Workflow Discipline 에서 cross-ref. 원본 synthesis = `Obsidian-airlens/wiki/synthesis/codex-2026-05-06/`. T+30d in-place 5 skill 복원 결정과 별개 — 강연 audit 가 plug-in 버전의 Quality 를 외부 검증.
