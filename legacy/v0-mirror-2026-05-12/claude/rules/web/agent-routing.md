# Agent Routing & Self-Improvement (AirLens-web)

3개 원본 룰을 통합 (agent-knowledge-base + agent-auto-dispatch + agent-self-improvement).
원본 백업: `_backup-local/agent-env-snapshot-2026-04-28/rules-original/`

---

## 1. Skills 디렉토리 참조 표

복잡한 작업 시작 전 해당 분야 핵심 자료를 직접 Read하여 판단에 반영.

### Frontend / UI

| 작업 | 핵심 자료 |
|------|----------|
| 컴포넌트 패턴 | `Skills/react-bits/README.md` |
| Globe 아키텍처 | `Skills/cambecc-earth/README.md` |
| Globe Canvas/D3 | `Skills/cambecc-earth/src/` |
| Wind 시각화 | `Skills/wind-js/` |
| Earth 텍스처/3D | `Skills/Earth3D/` |
| UI 디자인 디렉션 | `Obsidian-airlens/wiki/architecture/agent/ui-ux-pro-max-skill.md` |
| UI 스타일 카탈로그 | `Skills/ui-ux-pro-max-skill/README.md` |
| 애니메이션 | `Skills/motion/README.md` |
| 디자인 시스템 | `Skills/awesome-design-md/README.md` |

### Engineering / ML

| 작업 | 핵심 자료 |
|------|----------|
| 시스템 설계 | `Obsidian-airlens/wiki/concepts/system-design-principles.md` + `Skills/system-design-primer/README.md` |
| 실험 설계 | `Skills/autoresearch/program.md` |
| RAG 파이프라인 | `Skills/RAG-Anything/README.md` |
| 웹 데이터 수집 | `Skills/firecrawl/README.md` |
| CI/CD | `Skills/codex/README.md` |
| 프롬프트 패턴 | `Skills/fabric/`, `Skills/prompt-engineering-skills/skills/` |

### Operations / Docs

| 작업 | 핵심 자료 |
|------|----------|
| 에이전트 오케스트레이션 | `Skills/hermes-agent/AGENTS.md` |
| OMC 패턴 | `Skills/oh-my-claudecode/CLAUDE.md` |
| 위키 규칙 | `Obsidian-airlens/CLAUDE.md` |
| 문서 변환 | `Skills/markitdown/README.md` |
| Antigravity 카탈로그 (1,410개) | `Skills/antigravity-awesome-skills/skills/` |

### Reference 자료 (분석/이론)

| 작업 | 핵심 자료 |
|------|----------|
| 시스템 설계 / 스케일링 / API 디자인 / 보안 패턴 | `Obsidian-airlens/wiki/references/system-design-fundamentals.md` |
| Spline → R3F 마이그레이션 / 3D 디자인 영감 | `Obsidian-airlens/wiki/references/spline-and-3d-design.md` |
| 글로벌 OSS 에이전트 룰 사례 (227 repos) | `Obsidian-airlens/wiki/references/consolidated-agent-raw.md` (frozen, 936KB) |
| 통합 references 가이드 | `Obsidian-airlens/wiki/references/_README.md` |

검색: `ls Skills/antigravity-awesome-skills/skills/ | grep -i "키워드"` → 해당 `SKILL.md` Read.

---

## 2. 자동 디스패치 — 활성 훅

`.claude/settings.local.json` 등록:

| 훅 | 타이밍 | 역할 |
|----|--------|------|
| `supervisor.py` | UserPromptSubmit | 입력 분석 → 의도 분류 + 에이전트/워크플로우 매칭 + 구조화 로그 |
| `supervisor.py` | PreToolUse (Write/Edit/MultiEdit) | HIGH-risk 또는 MULTI_DEPT 작업의 Plan/specialist 디스패치 검증 |
| `supervisor.py` | PostToolUse (Agent) | dispatched-agents flag 호환성 유지 |
| `plan-gate.py` | PostToolUse (Agent/ExitPlanMode) | Plan 완료 확인 |
| `post-edit-quality-check.py` | PostToolUse (Write/Edit) | 편집 후 품질 검사 |
| `check-cross-store.sh` | PostToolUse (Write/Edit) | Store 간 직접 호출 감지 |
| `record-agent-routing.py` | PostToolUse (Agent) | 에이전트 호출 기록 + supervisor 분석 메타 보존 |

Deprecated 보존: `_DEPRECATED_supervisor-auto-route.py`, `_DEPRECATED_supervisor-enforcer.py`, `_DEPRECATED_agent-dispatch-enforcer.py`. 활성 라우팅은 `supervisor.py` 단일 진입점에서 처리한다.

---

## 3. 에이전트 라우팅 (registry.json 기준)

| 키워드 | subagent_type |
|--------|---------------|
| 랜딩, 히어로, 브랜드, 온보딩, UI 재설계, 기억에 남는 디자인 | `ui-ux-director` |
| 프론트엔드 아키텍처, AppShell, 라우팅, 상태관리 | `fe-architect` |
| Globe, Three.js, Canvas, 파티클 | `globe-specialist` |
| 컴포넌트, UI, 버튼, 모달, 카드 | `component-builder` |
| 접근성, WCAG, 키보드, 스크린리더 | `a11y-auditor` |
| DB, 스키마, RLS, 마이그레이션 | `db-architect` |
| Edge Function, API, Deno, 웹훅, JWT, CORS | `edge-fn-dev` |
| 보안, 취약점, XSS, 인젝션 | `security-reviewer` |
| 테스트, 커버리지, E2E, TDD | `test-engineer` |
| 성능, 번들, LCP, CWV | `performance-reviewer` |
| 코드 리뷰, 변경 검증 | `style-reviewer` |
| 배포, CI/CD, Cloudflare | `deploy-manager` |
| 문서, README, CHANGELOG, API 문서 | `doc-writer` |
| 번역, i18n, 다국어 | `i18n-specialist` |
| 위키, 문서, Obsidian | `wiki-curator` |
| Python, ML, 모델 | `ml-researcher` |
| supervisor, 에이전트 구성, 프롬프트 분석, 라우팅, 하네스 | `supervisor` |

### FEATURE 작업 흐름

```
1. Plan Mode 또는 planner skill → 설계
2. UI/브랜드/랜딩 작업이면 ui-ux-director → 디자인 브리프
3. 전문 에이전트 디스패치
4. 에이전트 결과 기반 구현
5. style-reviewer 또는 관련 reviewer → 검증

`workflows.json`의 `ui-design-dev.triggerKeywords`는 `supervisor.py`가 우선 적용한다. 랜딩/브랜드/히어로/온보딩 요청은 `Plan → ui-ux-director → component-builder → ux-reviewer/style-reviewer` 흐름을 권고한다.
```

### 자동 검증 트리거

- **5개 이상 파일 수정 시**: `Agent(subagent_type='style-reviewer', prompt='변경 검증: [파일 목록]')`
- **Store 변경 시** (`src/store/*.ts`): cross-store 호출 0 / 콜백 즉시 mutation 0 / 비즈니스 로직 0 검증
- **라우트/페이지 변경 시** (`App.tsx`, `src/pages/`): `fe-architect` 우선

호출 불요: 단순 질문, Plan Mode 완료된 작업의 단순 실행, 설정 파일 수정.

---

## 4. PGE 자체 평가 (10점 척도)

FEATURE 작업 완료 후:

```
## 자체 평가
- Build: [0-2] — npm run build 통과
- Lint: [0-2] — npm run lint 통과
- Test: [0-2] — 테스트 + 커버리지
- Code Quality: [0-2] — 하드코딩/인라인타입/중복 없음
- AirLens Rules: [0-2] — i18n, types.ts, config 준수
- Total: [X]/10
```

**7.0 미만 시 자동 개선**: 부족 차원 식별 → 해당 분야 에이전트 호출 (style-reviewer, security-reviewer 등) → 재평가.

---

## 5. 서킷 브레이커

| 실패 횟수 | 대응 |
|-----------|------|
| 1회 | 에러 분석 후 재시도 |
| 2회 | 접근 방식 변경 (다른 에이전트/도구) |
| 3회 | 사용자 에스컬레이션 — "이 부분은 판단이 필요합니다" |

---

## 6. 학습 기록

작업 중 발견한 패턴/실수는 `Obsidian-airlens/wiki/log/learnings-{날짜}.md`에 기록:

```markdown
## HH:MM — [작업 분야]
- 발견: [무엇을]
- 원인: [왜]
- 해결: [어떻게]
- 교훈: [다음 적용 패턴]
```

활성 훅: `supervisor.py`, `record-agent-routing.py`. Claude supervisor와 Codex skill은 별도 실행 체계이며, 이 문서는 Claude `Agent(subagent_type=...)` 라우팅만 다룬다.
