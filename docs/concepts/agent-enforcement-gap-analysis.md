---
title: 에이전트 시스템 적용 실패 분석 및 방지 계획
type: concept
created: 2026-04-20
updated: 2026-04-20
sources: [supervisor.md, registry-tier1.json, style-reviewer.md, fe-architect.md, agent-harness.md]
tags: [agent-system, harness, quality, meta]
audience: ai
priority: medium
---

# 에이전트 시스템 적용 실패 분석 및 방지 계획

## 1. 현상: 무엇이 안 되고 있나?

| 구성 요소 | 설계 의도 | 실제 상태 | 영향 |
|----------|----------|----------|------|
| **Supervisor 훅** | 매 메시지마다 의도 분류 → 부서 라우팅 → 하네스 제안 | `systemMessage`가 주입되지만 **Claude가 무시** | 모든 작업이 unrouted 직접 실행 |
| **PGE 하네스** | FEATURE 의도 시 Plan→Generate→Evaluate 루프 | **한 번도 호출되지 않음** | 품질 게이트 없이 코드 생성 |
| **style-reviewer** | 코드 변경 후 스타일/규칙 검사 | **호출되지 않음** | 타입 인라인, 하드코딩 미검출 |
| **fe-architect** | 새 페이지/레이아웃 변경 시 구조 설계 | **호출되지 않음** | PolicyProof가 PublicLayout에 배치 |
| **Design tokens** | `index.css` 토큰 + Tailwind 테마 일관성 | 참조되지 않음 | 디자인 불일치 |
| **registry-tier1.json** | 키워드 기반 부서 라우팅 | supervisor 훅이 라우팅하지만 **Claude가 라우팅 결과를 따르지 않음** | 전문 에이전트 미활용 |

---

## 2. 근본 원인 분석

### 원인 1: `systemMessage` ≠ 강제력

```
UserPromptSubmit 훅 → systemMessage 주입
  → Claude 컨텍스트에 추가됨
  → BUT: "프로토콜을 따라라"는 지시일 뿐, 도구 호출을 강제하지 않음
  → Claude는 "직접 하는 것이 더 빠르다" 판단 → 에이전트 스킵
```

**핵심**: `systemMessage`는 **제안**이지 **강제**가 아님. Claude의 자체 판단이 우선하며, 특히 Superpowers 스킬의 "even 1% chance → invoke skill" 규칙과 충돌 시 Superpowers가 이김.

### 원인 2: 프로젝트 에이전트 vs 글로벌 에이전트 충돌

```
글로벌 ECC 에이전트 (58개) — ~/.claude/agents/
  ↕ 충돌
AirLens 프로젝트 에이전트 (25개) — .claude/agents/
```

- Claude는 `Agent` 도구 호출 시 **글로벌 에이전트 타입** (code-reviewer, architect, planner 등)을 우선 사용
- 프로젝트 에이전트(fe-architect, style-reviewer 등)는 **Claude가 자발적으로 선택해야만** 사용됨
- 자발적 선택을 위한 트리거가 부족 — description의 example만으로는 매칭 확률이 낮음

### 원인 3: 하네스 호출 메커니즘 부재

```
PGE 하네스 = .claude/commands/agent-harness.md
  → 사용자가 명시적으로 /agent-harness 호출해야 실행
  → 자동 실행 경로 없음
```

- Supervisor 훅이 "하네스 제안"은 하지만, **실제로 하네스를 호출하는 자동화가 없음**
- `PreToolUse` 훅으로 Write/Edit 전에 하네스를 강제할 수 있지만 미구현

### 원인 4: 피드백 루프 단절

```
style-reviewer가 발견할 문제 → 발견 안 됨 (호출 안 되니까)
  → 문제가 코드에 남음
  → 다음 세션에서도 같은 패턴 반복
  → 학습 루프 없음
```

- `PostToolUse` 훅에 style-reviewer 호출이 없음
- `Stop` 훅에 품질 검증이 없음

---

## 3. 각 구성 요소별 실패 경로

### Supervisor 훅
```
✅ 훅 등록: settings.json UserPromptSubmit에 있음
✅ 스크립트 실행: supervisor-auto-route.py 정상 동작
✅ systemMessage 주입: 의도/부서/매니저 정보 전달
❌ Claude 이행: systemMessage를 읽지만 프로토콜을 따르지 않음
```
**→ 실패 지점: systemMessage → Claude 행동 변환**

### PGE 하네스
```
✅ 하네스 정의: .claude/commands/agent-harness.md
✅ PGE 워크플로: Plan → Generate → Evaluate 잘 설계됨
❌ 자동 트리거: FEATURE 의도 시 자동 호출 경로 없음
❌ 사용자 호출: /agent-harness를 직접 치지 않으면 미실행
```
**→ 실패 지점: 의도 감지 → 하네스 자동 호출**

### Style Reviewer
```
✅ 에이전트 정의: .claude/agents/style-reviewer.md (매우 상세)
✅ AirLens 규칙 포함: types.ts, APP_CONFIG, i18n, Glass-Box 검증
❌ 자동 호출: PostToolUse 훅에 등록 안 됨
❌ Agent 도구로 호출: Claude가 자발적으로 선택하지 않음
```
**→ 실패 지점: 코드 변경 후 자동 검증 트리거**

### fe-architect
```
✅ 에이전트 정의: Layout 시스템 지식 포함 (PublicLayout vs AppShell)
❌ 호출 시점: 새 페이지 추가/라우트 변경 시 참조되지 않음
```
**→ 실패 지점: 구조적 변경 시 아키텍처 검증 트리거**

---

## 4. 방지 계획: 훅 기반 강제 실행

### 4-1. PostToolUse: 코드 변경 후 자동 검증

`settings.json`에 추가할 훅:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "command": "python3 scripts/hooks/post-edit-quality-check.py",
        "timeout": 3
      }
    ]
  }
}
```

`post-edit-quality-check.py` 역할:
1. 변경된 파일이 `src/pages/*.tsx`인 경우 → **fe-architect 호출 제안** (레이아웃 검증)
2. 변경된 파일이 `src/components/**/*.tsx`인 경우 → **style-reviewer 호출 제안**
3. `App.tsx`의 Route 변경 감지 → **레이아웃 일관성 경고**

### 4-2. PreToolUse: Route 변경 시 아키텍처 검증

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit",
        "command": "python3 scripts/hooks/route-change-guard.py",
        "timeout": 3
      }
    ]
  }
}
```

`route-change-guard.py` 역할:
- `App.tsx`에서 `<Route` 추가/이동 감지
- **PublicLayout ↔ AppShell 간 이동 시 경고**: "이 페이지가 올바른 레이아웃에 있는지 확인하세요"
- 새 Route 추가 시 → "fe-architect 에이전트로 레이아웃 적합성을 검증하세요"

### 4-3. Stop: 세션 종료 시 품질 게이트

```json
{
  "hooks": {
    "Stop": [
      {
        "command": "python3 scripts/hooks/session-quality-gate.py",
        "timeout": 5
      }
    ]
  }
}
```

`session-quality-gate.py` 역할:
1. 이번 세션에서 변경된 파일 목록 수집 (`git diff --name-only`)
2. 주요 위반 패턴 자동 검사:
   - `src/pages/*.tsx`에 인라인 타입 정의가 있는지
   - `App.tsx`에서 라우트 레이아웃 일관성
   - 번역 키 누락 (`t()` 없는 하드코딩 문자열)
3. 위반 발견 시 경고 메시지 출력

### 4-4. UserPromptSubmit: Supervisor 강제력 강화

현재 `supervisor-auto-route.py`의 `systemMessage`를 개선:

```python
# 현재: "프로토콜을 따라라" (제안)
# 개선: 구체적 행동 지시 + 에이전트 호출 명령

if intent == "FEATURE":
    message += (
        "\n\n**필수 행동**: 코딩 시작 전 다음을 수행하세요:\n"
        "1. `Agent(subagent_type='plan', ...)` 으로 설계\n"
        "2. 코딩 완료 후 `Agent(description='style review', ...)` 으로 검증\n"
        "3. 페이지/라우트 변경 시 `fe-architect` 레이아웃 검증 필수\n"
    )
```

---

## 5. 학습 루프 설계

### 5-1. 위반 → 감지 → 기록 → 방지

```
[코드 변경]
  → PostToolUse 훅: 패턴 검사
  → 위반 감지 시:
    1. 경고 메시지 (즉시)
    2. memory/에 위반 패턴 기록 (누적)
    3. 다음 세션에서 동일 패턴 선제 경고
```

### 5-2. 세션 종료 시 자동 학습

```
[Stop 훅]
  → session-quality-gate.py
  → 위반이 있었다면:
    1. 위반 유형 집계
    2. memory/feedback_*.md에 자동 기록
    3. "이번 세션에서 X건의 레이아웃 불일치가 있었습니다"
```

### 5-3. 크로스-세션 패턴 축적

memory 파일 구조:
```
memory/
├── feedback_layout_consistency.md    # 레이아웃 위반 누적
├── feedback_type_inline.md          # 인라인 타입 위반 누적
├── feedback_i18n_missing.md         # 번역 키 누락 누적
└── feedback_agent_skipped.md        # 에이전트 미호출 누적
```

각 파일에 위반 횟수 + 최근 사례를 기록하면, 다음 세션에서 Claude가 메모리를 읽고 **같은 실수를 반복하지 않도록** 선제적으로 대응.

---

## 6. 즉시 실행 항목 (이번 세션)

| # | 작업 | 효과 |
|---|------|------|
| 1 | `post-edit-quality-check.py` 작성 + 훅 등록 | 코드 변경 후 자동 검증 |
| 2 | `route-change-guard.py` 작성 + 훅 등록 | 라우트 변경 시 레이아웃 경고 |
| 3 | `session-quality-gate.py` 작성 + 훅 등록 | 세션 종료 시 품질 요약 |
| 4 | `supervisor-auto-route.py` 개선 | 구체적 행동 지시로 강제력 강화 |
| 5 | 페이지 가이드 문서를 rules로 등록 | 에이전트가 참조할 수 있도록 |

## 7. 핵심 교훈

> **systemMessage는 제안이지 강제가 아니다.**
> 에이전트 시스템이 실제로 동작하려면 **훅에서 도구 호출을 직접 차단/강제**해야 한다.
> "프로토콜을 따라라"는 지시는 Claude가 더 효율적이라 판단하면 무시된다.
> 진짜 강제력은 `PreToolUse`에서 Edit를 **블록**하거나, `PostToolUse`에서 **경고를 주입**하는 것이다.

## 관련 문서

- [[에이전트 시스템 설계]] — 2-Tier 라우팅, 5부서 25에이전트
- [[하네스 엔지니어링]] — 4기둥, PGE 루프, 서킷 브레이커
- [[AirLens 웹 페이지별 가이드]] — 14개 라우트 목적, 레이아웃 가이드
