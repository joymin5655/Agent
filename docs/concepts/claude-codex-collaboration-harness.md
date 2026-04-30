---
title: "Claude/Codex 공동 작업 하네스"
type: concept
created: 2026-04-27
updated: 2026-04-29
sources: [scripts/harness-audit.js, scripts/agent-catalog.js, scripts/orchestration-status.js, scripts/orchestrate-worktrees.js, AirLens-web/.claude/commands/harness-audit.md]
tags: [agent, claude, codex, harness, collaboration, obsidian]
---

# Claude/Codex 공동 작업 하네스

Claude와 Codex는 완전히 따로 일하지 않는다. 런타임은 분리하고, 작업 기준과 산출물은 공유한다.

## 기본 구조

| 계층 | Claude | Codex | 공유면 |
|------|--------|-------|--------|
| 실행 지침 | `.claude/agents`, `.claude/rules`, `.claude/commands` | `.codex/skills`, `~/.codex/skills` | `AGENTS.md`, `CLAUDE.md` |
| 자동화 | Claude hooks | Codex tools/subagents | `scripts/harness-*`, `scripts/orchestration-*` |
| 기록 | Claude handoff, hook 결과 | Codex 변경/검증 요약 | `Obsidian-airlens/wiki/**` |
| 검증 | `/harness-audit`, hooks | `node scripts/harness-audit.js` | build/test/lint/audit |

핵심 원칙은 [[Claude/Codex 에이전트 런타임 분리|agent-runtime-separation.md]]를 따른다.

## 공통 스크립트

| 스크립트 | 역할 | 부작용 |
|----------|------|--------|
| `scripts/harness-audit.js` | Claude/Codex/Obsidian/검증 표면 감사 | 없음 |
| `scripts/agent-catalog.js` | Claude agents와 Codex skills 목록 요약 | 없음 |
| `scripts/orchestration-status.js` | worktree/tmux coordination 상태 조회 | 없음 |
| `scripts/orchestrate-worktrees.js` | 병렬 worktree 계획 dry-run 및 선택 실행 | 기본 없음, `--execute` 시 worktree 생성 |

`scripts/harness-audit.js hooks`는 Supervisor v6 기준으로 root `.claude/settings.local.json`의 22개 활성 hook command와 `supervisor.py`의 `UserPromptSubmit` / `PreToolUse` / `PostToolUse` 등록을 검사한다. Web-local hook ID 목록은 legacy surface로만 유지하고, v6 정합성의 기준은 root settings다.

## Handoff 규칙

공동 작업은 다음 정보를 Obsidian에 남긴다.

- 작업 목표
- 담당 런타임: Claude, Codex, both
- 관련 파일
- 실행한 검증 명령
- 남은 리스크
- 다음 작업자에게 필요한 맥락

권장 위치:

- 당일 작업 로그: `Obsidian-airlens/wiki/log/agent-handoff-YYYY-MM-DD.md`
- 장기 정책/구조: `Obsidian-airlens/wiki/concepts/**`
- 도구 레지스트리: `Obsidian-airlens/wiki/references/**`

## 실행 패턴

### 단일 런타임 작업

작업이 Claude hook/agent 또는 Codex skill 하나로 충분하면 해당 런타임에서 끝낸다. 결과만 Obsidian에 기록한다.

### 공동 작업

1. 한 런타임이 계획과 관련 파일을 Obsidian에 기록한다.
2. 다른 런타임이 같은 문서와 repo diff를 읽고 이어서 구현/검증한다.
3. 최종 검증은 공통 스크립트와 repo test/build 명령으로 한다.

### 병렬 worktree 작업

먼저 dry-run으로 계획을 확인한다.

```bash
node scripts/orchestrate-worktrees.js plan.json --dry-run
```

실제 worktree 생성은 명시적 승인 후에만 실행한다.

```bash
node scripts/orchestrate-worktrees.js plan.json --execute
```

운영 기준:

- Session name: `area-purpose-date` 형식의 kebab-case. 예: `harness-vnext-2026-04-29`.
- Owner: 각 worker task에 담당 런타임과 책임 파일 범위를 적는다.
- Seed paths: worker가 읽거나 이어받아야 하는 최소 파일만 `seedPaths`에 둔다.
- Branch name: script가 생성하는 `orchestrator-{session}-{worker}` 형식을 유지한다.
- Merge strategy: worker handoff와 diff를 root workspace에서 리뷰한 뒤 필요한 변경만 통합한다.
- Cleanup policy: merge 또는 폐기 후 `git worktree remove`와 coordination dir archive 여부를 handoff에 기록한다.

handoff 문서에 붙일 상태 요약:

```bash
node scripts/orchestration-status.js plan.json --format handoff
```

## 현재 보류 항목

- Claude supervisor/agent-dispatch 차단 훅
- 자동 tmux/dev-server 시작
- 모든 프롬프트 자동 Obsidian 기록
- cost tracker, desktop notification, continuous learning

이 항목들은 생산성 저하, 개인정보 기록, 외부 상태 의존성이 있어 별도 승인 후 단계적으로 켠다.

## 단계적 hook 활성화

2026-04-29 기준 기본 harness는 관찰, 라우팅 권고, 고위험 검증 중심이다.

- 활성: `supervisor.py`, `classify-prompt.py` dry-run, `plan-gate.py`, `record-agent-routing.py`, Bash guard, post-edit quality, cross-store, quality gate, design quality, session daily summary.
- 보존/deprecated: `_DEPRECATED_supervisor-auto-route.py`, `_DEPRECATED_supervisor-enforcer.py`, `_DEPRECATED_agent-dispatch-enforcer.py`.
- 감사 기준: `scripts/harness-audit.js`는 root 활성 hook command 수, Supervisor v6 event 등록, hook command script 존재, Claude routing 문서의 `registry.json` agent ID 정합성을 검사한다.

## 관련 문서

- [[Claude/Codex 에이전트 런타임 분리|agent-runtime-separation.md]]
- [[Codex Skill Registry|../references/codex-skill-registry.md]]
- [[설정 계층 구조|configuration-hierarchy.md]]
