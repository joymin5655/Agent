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
The tool refuses a bare `/` or empty `--old` (that would match everything) and any
`--old`/`--new` containing a newline (line-injection hazard). Note the report echoes
matched lines — review it before pasting into shared channels/CI logs, since a line
that references `<old>` can also carry unrelated sensitive content.

### 2. Confirm, then apply

Only after the user confirms the reported set, rewrite in place:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-.}/core/infra/reorg-sync.sh" \
  --old <old-prefix> --new <new-prefix> --root <tree> --apply
```

Replacement is a literal substitution **anchored at a path-component boundary via a
Unicode-aware whitelist** — a match counts only when the next character is `/`, a
line/string end, whitespace, or an unambiguous delimiter (quote, `: , ; = | < > ( )
[ ] { }`). Any other following character — a word char in *any* script (so CJK
siblings like `.../논문` vs `.../논문자료` are safe), or `. - + @ ~ %` — marks a
longer sibling name and is left untouched. Writes are atomic (temp + rename,
permissions preserved); a file that cannot be rewritten is reported on stderr and
the sweep continues, exiting 1 so the failure is visible. Binary files and the
`.git` object store are skipped. The native-memory key is rewritten with the
harness's `/ . _` → `-` encoding (Unicode-boundaried), confined to lines that carry
the `claude/projects` consumer context — ordinary kebab-case text is never touched.
One documented residual: a directory whose name is the moved prefix + a literal
space + more (`/old/data 2024` for OLD `/old/data`) is read as the component plus
text; the dry-run surfaces it before any apply.

### 3. Out-of-tree targets (report, don't auto-touch)

The path-keyed native-memory dir itself lives under `~/.claude/projects/` (outside
the swept tree) and the live user crontab is a system resource — this skill rewrites
*references* to them inside the tree, but does not mutate `~/.claude` or run
`crontab` for you. Surface those as follow-ups for the user to apply deliberately.

## Notes

- Idempotent: a second `--apply` run with the same prefixes finds nothing to change —
  including when NEW extends OLD (`/proj` → `/proj_v2`), where existing NEW
  occurrences are protected from re-substitution.
- Scope is `--root`; run once per tree that may hold references (repo, dotfiles, notes).
- Cron `@keyword` schedules (`@daily`, `@reboot`) classify as `crontab` like numeric rows.
