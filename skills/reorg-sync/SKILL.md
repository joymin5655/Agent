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
Unicode-aware whitelist on both sides** — a match counts only when the next
character is `/`, a line/string end, whitespace, or an unambiguous delimiter (quote,
`: , ; = | < > ( ) [ ] { }`), AND the preceding character is not a path-body char
(so `<old>` is not matched as the tail of an unrelated longer absolute path — e.g.
`/proj/x` never hits `/other/tree/proj/x`; a preceding `/` is deliberately *not* a
boundary). Any following character that is a word char in *any* script (so CJK
siblings like `.../논문` vs `.../논문자료` are safe), or `. - + @ ~ %`, marks a
longer sibling name and is left untouched. Writes are atomic (temp + rename,
permissions preserved); a file that cannot be rewritten is reported on stderr and
the sweep continues, exiting 1 so the failure is visible. Binary files and the
`.git` object store are skipped. The native-memory key is rewritten with the
harness's `/ . _` → `-` encoding (Unicode-boundaried), confined to lines that carry
the `claude/projects` consumer context — ordinary kebab-case text is never touched.
Because that fold is lossy, **only the exact key (the moved dir's own, `cwd == OLD`)
is rewritten**: a `-`-continuation key like `-old-prefix-sub` is left untouched,
since after the fold it is indistinguishable from a dash/dot/underscore *sibling*
(`enc('/old/prefix/sub')` == `enc('/old/prefix-sub')`). Skipping a deeper key is a
safe miss (the orphaned dir simply stays, as before this tool) rather than risk
corrupting an unrelated project's key. One documented residual: a directory whose
name is the moved prefix + a literal space + more (`/old/data 2024` for OLD
`/old/data`) is read as the component plus text; the dry-run surfaces it before any
apply.

**Coverage caveat (report honestly):** only references that end at a boundary
(`/`, whitespace, a delimiter, or line/string end) are detected — a reference
whose prefix is followed by `.`, `-`, or another word character (`see /old/prefix.`,
`val=/old/prefix-based`) is *intentionally* skipped, because it is indistinguishable
from a sibling name, and it will **not appear in the dry-run report**. This is safe
(a missed old path breaks loudly later, it is never silently corrupted), but it
means "dry-run reports nothing more" does not guarantee "every textual mention was
swept." After apply, a `grep -rF '<old>'` over the tree is the way to confirm no
intentional-skip tails remain that you actually wanted rewritten.

### 3. Out-of-tree targets (report, don't auto-touch)

The path-keyed native-memory dir itself lives under `~/.claude/projects/` (outside
the swept tree) and the live user crontab is a system resource — this skill rewrites
*references* to them inside the tree, but does not mutate `~/.claude` or run
`crontab` for you. Surface those as follow-ups for the user to apply deliberately.

## Notes

- Idempotent: a second `--apply` run with the same prefixes finds nothing to change,
  including every shape where NEW contains OLD — as a prefix (`/proj` → `/proj_v2`,
  `/proj` → `/proj/inner`) OR after a delimiter (`/a` → `/a:/a`). Enforced by a
  **protected-span guard**: apply computes the boundary-anchored literal-NEW spans
  positionally on the buffer and refuses to rewrite any OLD *fully contained* in one
  (already-migrated text). Full containment — not "starts inside" — so a promote-up
  reorg where NEW is a boundary-prefix of OLD (`/old/sub` → `/old`) still rewrites:
  the longer OLD overruns the NEW span and is a genuine fresh ref (a starts-inside
  test silently no-op'd 100% of that direction; retired 2026-07-16). No text is
  mutated during the scan, so an adjacent component's boundary is never disturbed —
  the flaw that sank an earlier NUL-nonce mask (which corrupted a nested sibling)
  and a leading-only negative lookahead (which missed the copy of OLD that NEW
  reintroduces after a delimiter, compounding `/a:/a:/a…`); both were retired
  2026-07-16. The cost is a deliberate safe miss: a *fresh* OLD ref that
  coincidentally sits inside a literal-NEW-shaped span is treated as migrated and
  left alone — never corrupted. Confirm with `grep -rF '<old>'` after apply.
- Report fidelity: the dry-run report and `--apply` consume one shared match set
  (per-occurrence, span-guard applied), so the per-class counts equal the
  substitutions `--apply` performs exactly — in both directions. N same-class refs
  on one line count N; a line carrying BOTH a native-memory-key ref and a
  co-resident plain-path ref counts once per axis; a ref the span guard safe-misses
  is *not* counted (previously reported as a hit that apply then skipped).
- Scope is `--root`; run once per tree that may hold references (repo, dotfiles, notes).
- Cron `@keyword` schedules (`@daily`, `@reboot`) classify as `crontab` like numeric rows.
