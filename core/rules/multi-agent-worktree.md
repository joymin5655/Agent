# Multi-Agent Worktree Coordination

Use this rule when more than one AI or human may touch the same repository.

## Rules

1. Keep the main checkout as a read-only baseline and merge target.
2. Create one worktree per session at `.worktrees/<agent>-<task-slug>/`.
3. Use branch names `<agent>/<task-slug>`.
4. Register sessions in `.claude/locks/active-sessions.json` with `scripts/infra/agent-session.sh start <task-slug>`.
5. Heartbeat active sessions every five minutes.
6. Claim shared production resources before use:
   - `production-db`
   - `edge-function-deploy`
   - `production-deploy`
   - live billing or other live external environments
7. Push and open PRs only from your own branch. Main merges are serialized by a human.
8. Do not push, force-push, delete, or rewrite another agent's branch prefix without explicit user approval.

## Standard Start

```bash
AGENT=codex scripts/infra/agent-session.sh start feature-slug
cd .worktrees/codex-feature-slug
```

## Standard Stop

```bash
AGENT=codex scripts/infra/agent-session.sh stop
git worktree remove .worktrees/codex-feature-slug
```
