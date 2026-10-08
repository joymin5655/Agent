# Remote branch cleanup candidates (2026-10)

Generated 2026-10-08 from `git fetch origin --prune`, `git branch -r --merged origin/main`,
`gh pr list --state all` and `git worktree list`. **Nothing was deleted.** This is a list for
the maintainer to review; deletion timing is the maintainer's call.

**Executed 2026-10-08 on the maintainer's go-ahead:** the 14 section-1 branches and the five
section-5 branches (#155–#159, worktrees removed first) were deleted after re-checking that each
tip still equalled its merged PR head. Section 3 branches were kept.

A branch counts as merged when `git branch -r --merged origin/main` lists it, or its PR is
MERGED (squash merges leave the branch tip outside main's history, so `--merged` alone misses
them). A PR-merged branch is a candidate only when its tip equals the PR's `headRefOid`
(AGENTS.md, squash-aware rule); otherwise it goes to section 2. Only `origin/main` itself
appeared in the `--merged` list.

## 1. Merged, no live worktree: deletion candidates (14)

| Branch | Last commit | PR | Tip == PR head | Evidence |
|---|---|---|---|---|
| `chore/release-0.5.14` | 2026-10-07 | #145 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `chore/release-0.5.15` | 2026-10-07 | #147 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/brain-capture-dedupe` | 2026-10-06 | #142 MERGED | yes | PR merged 2026-10-06; not in `--merged origin/main` (squash) |
| `claude/codex-model-resolver` | 2026-10-07 | #146 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/p1-9-risk-area-fail-closed` | 2026-10-07 | #144 MERGED | yes | PR merged 2026-10-06; not in `--merged origin/main` (squash) |
| `claude/public-reference-positioning` | 2026-10-07 | #143 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/realign-w1-purpose` | 2026-10-07 | #148 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/realign-w2-evidence` | 2026-10-07 | #149 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/realign-w3-gate` | 2026-10-07 | #150 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/realign-w4-profile` | 2026-10-07 | #151 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/realign-w5-observe` | 2026-10-07 | #152 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `claude/release-0.5.16` | 2026-10-07 | #153 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |
| `docs/backlog-fail-closed-lane-mapping` | 2026-09-01 | #119 MERGED | yes | PR merged 2026-10-06; not in `--merged origin/main` (squash) |
| `fix/call-worker-test-log-isolation` | 2026-10-07 | #154 MERGED | yes | PR merged 2026-10-07; not in `--merged origin/main` (squash) |

`docs/backlog-fail-closed-lane-mapping` is outside the usual `claude|feat|codex|fix|chore`
prefixes; it is listed because its PR (#119) is merged.

Command the maintainer would run after review (not executed; shown commented):

```bash
# git push origin --delete \
#   chore/release-0.5.14 \
#   chore/release-0.5.15 \
#   claude/brain-capture-dedupe \
#   claude/codex-model-resolver \
#   claude/p1-9-risk-area-fail-closed \
#   claude/public-reference-positioning \
#   claude/realign-w1-purpose \
#   claude/realign-w2-evidence \
#   claude/realign-w3-gate \
#   claude/realign-w4-profile \
#   claude/realign-w5-observe \
#   claude/release-0.5.16 \
#   docs/backlog-fail-closed-lane-mapping \
#   fix/call-worker-test-log-isolation
```

## 2. Needs check: commits after the PR head

None. `git rev-parse origin/<branch>` equalled `gh pr view <n> --json headRefOid` for all 14
candidates when this was generated (2026-10-08), so no branch carries commits added after its
PR head. Re-run the comparison before deleting; a branch pushed to after merge would show up here.

## 3. Closed, unmerged PRs (keep or decide)

| Branch | Last commit | PR | Evidence |
|---|---|---|---|
| `claude/w2-reorg-sync` | 2026-08-13 | #53 CLOSED | Superseded by #156 (`claude/reorg-sync-rebased`, merged). **Maintainer asked to KEEP.** |
| `codex/instruction-unification-20260926` | 2026-10-04 | #141 CLOSED | Live worktree `.worktrees/codex-instruction-unification-20260926`; keep. |

## 4. Unmerged without a PR

None. Every remote branch other than `main` has a PR.

## 5. Excluded

| Branch | Reason |
|---|---|
| `main` | default branch |
| `claude/backlog-w1-gate` (#157 merged) | live worktree `.worktrees/claude-backlog-w1` |
| `claude/backlog-w2-lanes` (#155 merged) | live worktree `.worktrees/claude-backlog-w2` |
| `claude/reorg-sync-rebased` (#156 merged) | live worktree `.worktrees/claude-backlog-w4` |
| `claude/backlog-w3-effort` | live worktree `.worktrees/claude-backlog-w3`; no remote branch |
| `claude/backlog-w5-docs` | live worktree `.worktrees/claude-backlog-w5`; no remote branch |

Merged branches with live worktrees become candidates once the worktree is removed
(`git worktree remove`, without `--force`). Branches of open PRs: none at generation time.
Local branches were not examined.
