# 동명 Skill 우선순위 표 (다중 source disambiguation)

같은 이름의 skill 이 여러 source 에 존재할 때 (Matt Pocock skill / context-mode plug-in / superpowers / hook / addyosmani-agent-skills) 적용 우선순위.

**근거**: `.claude/rules/policy/matt-pocock-skills.md` §"네이밍 충돌 회피" + `.claude/rules/policy/addyosmani-agent-skills.md` §"네이밍 충돌 회피" + `.claude/rules/external-plugin-policy.md §3 B §3 I`.

## 우선순위 매트릭스

| skill | 1차 (auto, 차단/실행) | 2차 (사용자 invoke 시) | SKIP |
|---|---|---|---|
| `/tdd` | `scripts/hooks/tdd-guard.sh` (PreToolUse Write\|Edit 자동 차단) | Matt Pocock `tdd` (RGR 안내) | superpowers `test-driven-development` (글로벌 — 의미 동일, 중복 호출 회피) · addyosmani `test-driven-development` (in-place 이식 회피 — 3중 활성으로 충분, T+30d 후 Matt Pocock 폐기 시 채택 검토) |
| `/diagnose` | — | Matt Pocock `diagnose` (재현 어려움 + feedback loop 부재) **또는** gstack `/investigate` (단일 stack trace + 빠른 fix) | context-mode `/diagnose` (의미 미정의 — T+30d 데이터 측정 후 결정) · addyosmani `debugging-and-error-recovery` (in-place 이식 회피 — 2 skill 충분) |
| `/grill-with-docs` | — | Matt Pocock `grill-with-docs` (PRD/ADR 갱신 동반) | context-mode `/grill-with-docs` (frontmatter 동일 — 중복) |
| `/grill-me` | — | Matt Pocock `grill-me` (sanity check 가벼운 grilling) | context-mode `/grill-me` (frontmatter 동일) |
| `/improve-codebase-architecture` | — | Matt Pocock 버전 (도메인 PRD §Glossary + monorepo extraction policy 결합) | context-mode 버전 (의미 미정의) · addyosmani `code-simplification` (hybrid T+7d deferral — Chesterton's Fence + Rule of 500 패턴 별 plan) |
| `/caveman` | — | Matt Pocock `caveman` (opt-in 토글, 5 가드 영역 — Glass-box / 보안 / destructive / multi-step / 사용자 재질문 — 풀 문장 유지) | context-mode `/caveman` (frontmatter 동일) |
| `/review` | gstack `/review` (PR 분석 — SQL safety / LLM trust boundary / side effect) | gstack `/review` 동일 | addyosmani `code-review-and-quality` (in-place 이식 회피 — gstack 우월. T+7d hybrid: Five-axis severity 라벨 Nit/Optional/FYI 패턴 흡수 별 plan) |
| `/ship` | gstack `/ship` (자동 머지 + canary 모니터링) | gstack `/ship` 동일 | addyosmani `shipping-and-launch` (in-place 이식 회피 — gstack 우월 + 5 가드 ⚠️ deploy 자동화 회피. T+30d 후 7-slash 통합 별 plan 트리거) |

## T+30d 결정 (2026-06-05)

invoke 빈도 데이터 (`.claude/logs/agent-routing.jsonl`) 기반 다음 3 옵션 중 택1:
1. in-place 5 skill 복원
2. context-mode 비활성
3. 현 상태 유지

절차 = `external-plugin-policy.md §5` T+30d sport check.

## History

- 2026-05-12 — 초기 분리. root `CLAUDE.md §Skill routing` 의 동명 skill 우선순위 표 (20줄) 를 본 file 로 추출. 정합 cross-ref 만 root 에 잔류.
