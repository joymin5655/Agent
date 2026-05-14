# PR Security And Human Merge Serialization

Agents may prepare branches, commits, pushes, and pull requests. A human owns merge serialization.

## Rules

- Open PRs from the agent's own branch only.
- Do not auto-merge main without explicit user instruction.
- Treat admin merge, force merge, deploy-on-merge, and workflow-dispatch operations as high risk.
- Record evidence for exceptional admin merges using `scripts/hooks/admin-merge-track.py`.
- After a PR merges, rebase active worktrees on `origin/main`.

## GitHub Actions

Workflow files may reference `secrets.NAME`, but secret values must never appear in the repository.
