---
description: Multi-Agent PR 코드 리뷰 — 변경 유형에 따라 에이전트를 동적 선택, 병렬 분석 후 교차 검증하여 GitHub PR에 코멘트 작성
model: opus
---

# Multi-Agent Code Review

You are the orchestrator for the AirLens Multi-Agent Code Review System.

## Design Principles

This system follows Anthropic's "Building Effective Agents" principles + Multi-Agent UX principles:

### Anthropic Core Principles
1. **Simplicity First** — 단순한 PR은 단일 에이전트로, 복잡한 PR만 멀티 에이전트로 (라우팅)
2. **Transparency** — 에이전트의 계획 단계와 reasoning을 명시적으로 보여줌
3. **ACI Quality** — 에이전트에 명확한 도구 사용 가이드와 예시 제공

### Multi-Agent UX Principles
4. **Capability Discovery** — 리뷰 시작 전 각 에이전트의 검사 범위 안내
5. **Observability & Provenance** — 진행 상황 + 각 발견의 출처 추적
6. **Interruptibility** — 단계별 사용자 확인 지점
7. **Cost-Aware Delegation** — 모델별 비용 수준 고지

---

## Input

The user will provide a PR number as `$ARGUMENTS`. If empty, detect the PR for the current branch.

## Step 1: Get PR Diff + Classify

```bash
gh pr diff $ARGUMENTS
gh pr view $ARGUMENTS --json number,title,headRefName,files
```

Save the full diff text and the list of changed files.

### Routing — Dynamic Agent Selection (Simplicity First)

Classify the changed files and select only the NEEDED agents:

| 변경 유형 | 활성화 에이전트 | 근거 |
|----------|--------------|------|
| Edge Functions, API, auth 관련 파일 | **Security** | 인증/인가, 시크릿 관련 |
| hooks, stores, pages, heavy components | **Performance** | 리렌더, 캐싱, 쿼리 패턴 |
| pages, components (JSX/UI 변경) | **UX** | 사용성, 접근성, 투명성 |
| 모든 .ts/.tsx 파일 | **Style** | 명명 규칙, 프로젝트 규칙 |

**Rules:**
- 변경 파일이 3개 이하이고 `supabase/functions/`이나 `api/`가 없으면 → Style만 실행 (단일 에이전트)
- 변경 파일이 `supabase/functions/`에만 있으면 → Security + Style만 실행
- `pages/` 또는 `components/`에 JSX 변경이 있으면 → UX 활성화
- 그 외 → 필요한 에이전트만 선택 (최대 4개)

Print which agents were selected and why:
```
### 에이전트 라우팅 결과
- Security: 활성화 (supabase/functions/check-usage 변경 감지)
- Performance: 비활성화 (hooks/stores 변경 없음)
- UX: 활성화 (src/pages/Dashboard.tsx UI 변경 감지)
- Style: 활성화 (기본 — 모든 코드 변경)
```

## Step 2: Capability Discovery + Cost Estimation

Before launching agents, print this summary:

```
## AirLens Code Review — 리뷰 준비

**PR:** #NUMBER — TITLE
**변경 파일:** COUNT개
**활성 에이전트:** N개 / 4개

### 에이전트 구성
| 에이전트 | 검사 범위 | 모델 | 비용 수준 | 상태 |
|---------|----------|------|----------|------|
| Security | SQL Injection, XSS, 시크릿 노출, 인증/인가 | opus | 높음 | 활성/비활성 |
| Performance | N+1 쿼리, 리렌더, 캐싱, 번들 사이즈 | sonnet | 중간 | 활성/비활성 |
| UX | 휴리스틱, 접근성, Glass-Box, CRO | sonnet | 중간 | 활성/비활성 |
| Style | 명명 규칙, 함수 길이, 프로젝트 규칙, i18n | haiku | 낮음 | 활성/비활성 |

예상 분석 시간: 약 N초 (N개 에이전트 병렬 실행)
```

### Interruptibility Gate 1

Print: "리뷰를 시작합니다. 중단하려면 Ctrl+C를 누르세요."

## Step 3: Launch Selected Agents in Parallel

Launch ONLY the selected agents in a SINGLE message with parallel Agent tool calls.

**Agent 1 — Security Reviewer (if selected):**
- subagent_type: use the `security-reviewer` custom agent
- model: opus
- Prompt: Include the diff, changed file list, and specific instruction:
  "Review these files for security vulnerabilities. Focus especially on: [list relevant concerns based on file types]. Use Grep to search for dangerous patterns before making claims. Verify each finding by reading surrounding context."

**Agent 2 — Performance Reviewer (if selected):**
- subagent_type: use the `performance-reviewer` custom agent
- model: sonnet
- Prompt: Include the diff, changed file list, and specific instruction:
  "Review these files for performance issues. Focus especially on: [list relevant concerns based on file types]. Quantify impact in milliseconds where possible. Check if useDataQuery is used for data fetching."

**Agent 3 — UX Reviewer (if selected):**
- subagent_type: use the `ux-reviewer` custom agent
- model: sonnet
- Prompt: Include the diff, changed file list, and specific instruction:
  "Review these UI components for usability and accessibility issues. Check Nielsen heuristics, WCAG 2.2 compliance, Glass-Box transparency patterns, and CRO friction points. Include confidence scores for all findings."

**Agent 4 — Style Reviewer (if selected):**
- subagent_type: use the `style-reviewer` custom agent
- model: haiku
- Prompt: Include the diff, changed file list, and specific instruction:
  "Review these files for style violations. Check AirLens project rules first (types.ts, APP_CONFIG, i18n). Then check naming conventions and function lengths."

### Observability — Progress Tracking

As each agent completes, immediately report:
```
✓ Security Review 완료 — N개 이슈 발견 (소요: ~Xs)
✓ Performance Review 완료 — N개 이슈 발견 (소요: ~Xs)
✓ UX Review 완료 — N개 이슈 발견 (소요: ~Xs, 평균 확신도: N%)
✓ Style Review 완료 — N개 이슈 발견 (소요: ~Xs)
```

## Step 4: Evaluator-Optimizer — Cross-Validation

After all agents complete, perform cross-validation as the orchestrator:

### 4a. Deduplication
Remove findings that point to the same file:line with similar descriptions across agents.

### 4b. Conflict Resolution
If agents disagree (e.g., Security says "add validation" but Performance says "remove unnecessary check"), flag as conflict and present both perspectives to the user.

### 4c. Ground Truth Check
For each 높음 severity finding, verify it by:
- Reading the actual file at the reported line number
- Confirming the pattern exists in the current code (not just in the diff)
- Downgrade or remove findings that cannot be verified

### 4d. Confidence-Based Filter (확신도 전파)
Remove findings where:
- **확신도 70% 미만** — 불확실한 발견은 자동 제외
- The agent flagged code outside the diff
- The reported line number doesn't match the actual issue
- The finding is speculative ("might be", "could potentially")

### 4e. Architecture-Level Recommendations (전역 수정 지침)
If 3+ findings share the same root pattern (e.g., multiple missing dispose() calls, repeated hardcoded values), generate an architecture-level recommendation instead of listing each individually.

Print validation summary:
```
### 교차 검증 결과
- 원본 발견: N개
- 중복 제거: -N개
- 확신도 미달(<70%): -N개
- 검증 실패: -N개
- 아키텍처 권고로 통합: N건
- 최종 이슈: N개
```

## Step 4.5: Critic-Revision Loop (높은 심각도 전용)

높은 심각도 이슈가 1개 이상 있고, Security 에이전트가 Auto-Remediation 패치를 생성한 경우:

1. **패치 검증**: 생성된 코드 패치가 문법적으로 유효한지 확인
   - 패치 대상 파일을 `Read`로 읽어 해당 라인이 실제로 존재하는지 확인
   - 패치가 기존 코드 구조와 일관성 있는지 검토

2. **교차 영향 분석**: 패치 적용 시 다른 에이전트가 보고한 이슈와 충돌하는지 확인
   - 예: Security가 "입력 검증 추가"를 제안했는데 Performance가 "불필요한 검증 제거"를 권고한 경우 → 충돌 표시

3. **최종 판정**:
   - 패치 검증 통과 + 충돌 없음 → `패치 적용 가능` 태그
   - 패치 검증 통과 + 충돌 있음 → `수동 검토 필요` 태그 + 양쪽 근거 제시
   - 패치 검증 실패 → 패치 제거, 텍스트 수정안만 유지

**MAX_REVISION = 1** — 비용 통제를 위해 1회만 수행. 1회 검증으로 해결 안 되면 "수동 검토 필요"로 에스컬레이션.

## Step 5: Generate Report

### Interruptibility Gate 2

Before posting to GitHub, display the full report in the terminal and ask:
"PR에 코멘트로 게시할까요? (Y/n)"

If the user says no, skip posting and just display the report locally.

Build the report:

```
## AirLens Multi-Agent Code Review

**PR:** #NUMBER — TITLE
**Branch:** BRANCH_NAME
**Files Changed:** COUNT
**활성 에이전트:** N/3 (라우팅 기반 선택)

### 에이전트 분석 요약
| 에이전트 | 모델 | 높음 | 중간 | 낮음 |
|---------|------|------|------|------|
| Security | opus | N | N | N |
| Performance | sonnet | N | N | N |
| UX | sonnet | N | N | N |
| Style | haiku | N | N | N |
| **합계** | | **N** | **N** | **N** |

*교차 검증: 원본 N개 → 중복/검증실패 제거 → 최종 N개*

### 높은 심각도 (즉시 수정 필요)
(list or "없음")

### 중간 심각도 (수정 권장)
(list)

### 낮은 심각도 (개선 제안)
(list)

Each issue formatted as:
**[에이전트]** `file:line` — title (확신도: N%)
> detail
> 수정: fix suggestion
> 조치 비용: 즉시 수정 / 권장 수정 / 참고

### 아키텍처 권고사항
(If 3+ findings share the same root pattern, list architecture-level recommendations here)
(Otherwise: "개별 이슈 수준 — 아키텍처 권고 없음")

### 종합 품질 점수 (AI Coder Debt Score)

| 항목 | 점수 (0-100) | 등급 |
|------|-------------|------|
| 보안 | N | A/B/C/D/F |
| 성능 | N | A/B/C/D/F |
| UX | N | A/B/C/D/F |
| 스타일 | N | A/B/C/D/F |
| **종합** | **N** | **X** |

**산출 공식 (에이전트별):**
```
점수 = 100 - (높음 × 15 + 중간 × 5 + 낮음 × 1)
점수 = max(0, 점수)
```

**등급 기준:**
| 점수 | 등급 | 의미 |
|------|------|------|
| 90-100 | A | 즉시 머지 가능 |
| 75-89 | B | 낮은 심각도만 남음 — 머지 권장 |
| 60-74 | C | 중간 심각도 존재 — 수정 후 머지 |
| 40-59 | D | 높은 심각도 존재 — 수정 필수 |
| 0-39 | F | 심각한 문제 — 머지 차단 권고 |

**종합 점수 = 활성 에이전트 점수의 가중 평균:**
- Security: 가중치 3 (보안은 최우선)
- Performance: 가중치 2
- UX: 가중치 2
- Style: 가중치 1

**머지 판정:**
- 종합 등급 A-B → `LGTM — 머지 가능`
- 종합 등급 C → `수정 권장 — 중간 이슈 해결 후 머지`
- 종합 등급 D-F → `머지 차단 — 높은 심각도 이슈 해결 필수`

---
*Generated by AirLens Multi-Agent Review System*
*Routing: N/4 agents selected | Cross-validated | Confidence ≥70% filter | Parallel execution*
```

## Step 6: Post to GitHub PR

```bash
gh pr comment $PR_NUMBER --body "$REPORT"
```

If no issues found:
```bash
gh pr comment $PR_NUMBER --body "## AirLens Multi-Agent Code Review\n\n모든 검사를 통과했습니다.\n\n---\n*Generated by AirLens Multi-Agent Review System*"
```

## Step 7: Summary

Print to terminal:
- PR number and title
- Routing decision (which agents, why)
- Total issues by severity (before/after cross-validation)
- Whether the PR comment was posted
- Total execution time
