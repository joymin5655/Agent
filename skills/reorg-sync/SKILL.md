---
name: reorg-sync
description: Sweep orphaned absolute-path references after a directory move — given an old and a new path prefix, find and optionally rewrite the five reference classes that silently break on a reorg (shebangs, git worktree pointers, crontab commands, doc anchors, and the path-keyed native-memory dir). Dry-run by default. NOT for renaming files on disk (that is `mv`/`git mv` — this fixes references that POINT at a moved path), and NOT for find-and-replace of arbitrary text (it targets path-prefix references specifically, driven by `core/infra/reorg-sync.sh`).
when_to_use: After moving a project tree to a new location (drive reorg, folder rename) when config/metadata still points at the old path — "sync references after the move", "fix the broken paths from the reorg", or `/reorg-sync <old> <new>`.
tools: Bash, Read, Grep, Glob
---

# /reorg-sync

## Goal

After a tree moves, absolute-path references left behind break silently. This skill
sweeps them in one pass, reporting first and rewriting only on explicit confirmation.

## What it sweeps (5 classes)

| Class | Example that breaks |
|---|---|
| `shebang` | `#!<old>/bin/python3` — a dead interpreter path |
| `worktree-gitfile` | `gitdir: <old>/repo/.git/worktrees/x` in a worktree's `.git` file |
| `crontab` | `0 3 * * * <old>/scripts/backup.sh` — a cron job running a gone path |
| `anchor` | a doc/config that references `<old>/...` |
| `native-memory-key` | `~/.claude/projects/<encoded>/` where the key encodes the path (`/ . _` → `-`) — orphaned when the source path moves |

## Steps

### 1. Report (dry-run — always first)

```bash
bash "${CLAUDE_PLUGIN_ROOT:-.}/core/infra/reorg-sync.sh" \
  --old <old-prefix> --new <new-prefix> --root <tree>
```

Read the `CLASS  file:line  <text>` rows and the per-class summary with the user.
The tool refuses a bare `/` or empty `--old` (that would match everything).

### 2. Confirm, then apply

Only after the user confirms the reported set, rewrite in place:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-.}/core/infra/reorg-sync.sh" \
  --old <old-prefix> --new <new-prefix> --root <tree> --apply
```

Replacement is a safe literal substitution (no regex/sed hazards); binary files and
the `.git` object store are skipped. The native-memory key is rewritten with the
harness's `/ . _` → `-` encoding, so the moved project's memory dir reference tracks
its new path.

### 3. Out-of-tree targets (report, don't auto-touch)

The path-keyed native-memory dir itself lives under `~/.claude/projects/` (outside
the swept tree) and the live user crontab is a system resource — this skill rewrites
*references* to them inside the tree, but does not mutate `~/.claude` or run
`crontab` for you. Surface those as follow-ups for the user to apply deliberately.

## Notes

- Idempotent: a second `--apply` run with the same prefixes finds nothing to change.
- Scope is `--root`; run once per tree that may hold references (repo, dotfiles, notes).
