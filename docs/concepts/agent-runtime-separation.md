---
title: "Claude/Codex 에이전트 런타임 분리"
type: concept
created: 2026-04-27
updated: 2026-04-29
sources: [AirLens-web/.claude/settings.local.json, AirLens-web/.claude/agents, AirLens-web/.codex/skills, _backup-local/claude-config/hooks/hooks.json]
tags: [agent, claude, codex, hooks, skills, obsidian]
---

# Claude/Codex 에이전트 런타임 분리

AirLens는 Claude Code와 Codex를 함께 쓰지만 두 런타임을 섞지 않는다. Claude agent는 Claude Code의 agent/hook/command 체계로 실행되고, Codex agent는 Codex skill 체계로 실행된다.

## 정본 위치

| 구분 | 위치 | 역할 |
|------|------|------|
| Claude agents | `AirLens-web/.claude/agents/**` | Claude Code 전용 subagent 정의와 레지스트리 |
| Claude rules | `AirLens-web/.claude/rules/**` | Claude Code 런타임 규칙 |
| Claude hooks | `AirLens-web/.claude/settings.local.json`, `AirLens-web/.claude/scripts/hooks/**`, `scripts/hooks/**` | Claude Code hook 등록과 실행 스크립트 |
| Codex skills | `AirLens-web/.codex/skills/**`, `/Users/joymin/.codex/skills/**` | Codex 전용 skill 지침 |
| 공통 문서 | `Obsidian-airlens/wiki/**` | 설명, 인벤토리, 이관 기록, 운영 결정 |
| 공통 하네스 | `scripts/harness-audit.js`, `scripts/agent-catalog.js`, `scripts/orchestration-status.js`, `scripts/orchestrate-worktrees.js` | Claude와 Codex가 함께 쓰는 감사, 카탈로그, 상태 조회, dry-run worktree 계획 |

## 현재 검증 결과

- Codex project-local skill은 13개이며, `airlens-design-director`가 Claude `ui-ux-director`의 Codex 대응 런타임으로 추가되었다.
- `AirLens-web/.codex/skills`와 `/Users/joymin/.codex/skills`에서 Claude 전용 실행 호출 형태(`subagent_type:`, `Agent(`, `Task(`, `/Users/joymin/.claude`)는 발견되지 않았다.
- `AirLens-web/.claude/settings.local.json`에는 2026-04-27 기준 staged hook 세트가 등록되어 있다.
- Staged hook은 라우팅 힌트와 기록, 품질 경고 중심이다. Write/Edit 차단형 supervisor/dispatch hook은 기본 활성화하지 않는다.

## 운영 규칙

- Claude agent 원본을 Codex skill에 그대로 복사하지 않는다.
- Codex skill에는 Claude-only API, hook lifecycle, `subagent_type` 실행 전제를 넣지 않는다.
- Claude hook이 실제 활성이라고 말하려면 해당 `settings*.json`에 등록되어 있어야 한다.
- 긴 정책과 이관 기록은 Obsidian에 두고, 런타임 파일에는 실행에 필요한 최소 지침만 둔다.
- 공동 작업은 [[Claude/Codex 공동 작업 하네스|claude-codex-collaboration-harness.md]]에 정의된 공통 스크립트와 handoff 규칙을 따른다.

## 2026-04-27 활성화한 Claude hook 세트

| id | event | 역할 |
|----|-------|------|
| `airlens:supervisor-auto-route` | UserPromptSubmit | 의도 분류와 전문 에이전트 라우팅 힌트 출력 |
| `pre:bash:block-no-verify` | PreToolUse/Bash | `--no-verify` 차단 |
| `airlens:pre-tool-guard` | PreToolUse/Bash | 위험 Bash, force push, DB drop, secrets 접근 차단 |
| `pre:bash:commit-quality` | PreToolUse/Bash | git commit 전 staged 파일/커밋 메시지 검사 |
| `pre:write:doc-file-warning` | PreToolUse/Write | 구조 밖 ad-hoc 문서 생성 경고 |
| `pre:config-protection` | PreToolUse/Write/Edit/MultiEdit | linter/formatter config 약화 방지 |
| `airlens:circuit-breaker` | PostToolUse/Bash | 반복 실패 경고 |
| `airlens:plan-gate` | PostToolUse/Agent, ExitPlanMode | Plan 완료 플래그 기록 |
| `airlens:record-agent-routing` | PostToolUse/Agent | 에이전트 라우팅 기록과 디스패치 플래그 기록 |
| `airlens:post-edit-quality` | PostToolUse/Edit/Write | AirLens UI/i18n/design-token 품질 경고 |
| `airlens:cross-store-check` | PostToolUse/Edit/Write | Zustand store 간 직접 import 경고 |
| `post:quality-gate` | PostToolUse/Edit/Write/MultiEdit | 로컬 formatter 기반 가벼운 품질 검사 |
| `post:edit:design-quality-check` | PostToolUse/Edit/Write/MultiEdit | 일반적인 템플릿형 UI drift 경고 |

## 보류한 hook

- 자동 tmux/dev-server: 실행 환경 부작용이 커서 보류.
- continuous learning, cost tracker, desktop notify, MCP health: 글로벌 `~/.claude` 플러그인 상태에 의존하므로 보류.
- supervisor/agent-dispatch 차단 계열: `supervisor-enforcer.py`, `agent-dispatch-enforcer.py`, `check-hardcoding.py`, `route-change-guard.py`는 `/tmp/airlens-*` 플래그로 Write/Edit를 막을 수 있어 strict harness 전용으로 보류.
- chat/session 자동 기록: Obsidian에 프롬프트와 작업을 자동 저장하므로 개인정보와 민감 명령 로그 정책 확정 후 활성화.
- hook audit: `scripts/harness-audit.js`는 활성 hook ID와 hook command script 존재 여부, 라우팅 문서의 agent ID 유효성을 검증한다.

## 관련 문서

- [[에이전트 디스패치 시스템|agent-dispatch-system.md]]
- [[설정 계층 구조|configuration-hierarchy.md]]
- [[Claude/Codex 공동 작업 하네스|claude-codex-collaboration-harness.md]]
- [[Codex Skill Registry|../references/codex-skill-registry.md]]
