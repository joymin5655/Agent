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
The tool refuses five input shapes outright, each a proven corruption/injection
hazard:

- a bare `/` or empty `--old` (would match everything);
- a **relative** `--old`/`--new` (both must be `/`-leading — a slash-less OLD is
  byte-identical to its own encoded key form and would double-match both axes);
- any `--old`/`--new` containing a **line separator** — not just `\n` but every
  character Python's `splitlines()` honors (`\r \v \f \x1c-\x1e \x85 U+2028
  U+2029`), any of which would inject lines into swept files on apply;
- a **promote-up** move (`--old` under `--new`, e.g. `/old/sub` → `/old`): after
  one apply, a migrated ref and a fresh `/old/sub` ref are byte-identical, so no
  stateless rewrite can be idempotent — a re-run eats one path component per
  pass, which is data corruption. A real reorg moves children individually; run
  one sweep per moved child instead. (Decision 2026-08-10, superseding the
  earlier "make promote-up rewrite" direction.) The refusal is **per axis**: the
  encoded-key forms of OLD/NEW are checked too, and because `enc()` preserves
  characters like `:` and space, a move can be a promote-up on the *key* axis
  alone (`/a.b:c` → `/a/b` gives keys `-a-b:c` / `-a-b`) — refused with a
  key-axis message. Identity (`--old X --new X`, including trailing-slash
  spellings) is **not** a promote-up: it is accepted and reports an honest 0, as
  does the key axis of a rename that changes only `/ . _` (whose keys encode
  identically);
- a **suffix-overlap** ("demote") move — `--new` occurs inside `--old` at any
  offset ≥ 1 followed by a path boundary or OLD's end (as a suffix `/srv:/app`
  → `/app`, `/a/b` → `/b`; or *strictly inside*: `/srv:/app/bin` → `/app`, 9th
  panel), or a proper suffix of `--old` equals a boundary-terminated proper
  prefix of `--new` (partial: `/a/b` → `/b/c`): the mirror of promote-up.
  After one apply, pre-existing text ending in OLD's leading remainder
  followed by the written NEW is byte-identical to a fresh OLD ref, so each
  re-apply eats one *leading* component per pass (8th/9th panels, reproduced
  on every boundary character). Sweep with a more specific `--old`, or move
  through an intermediate name sharing no boundary-anchored affix with either
  side. (`/proj` → `/proj/inner` is *not* this shape — extends-moves stay
  supported via the protected-span guard. `/data/appx` → `/app` is not either:
  a non-boundary junction after the embedded NEW cannot re-match.) Unlike
  promote-up, this family is checked on the **path axis only**: a key-axis
  straddle is unconstructible (the key matcher is pinned by its fixed-width
  `claude/projects/` lookbehind), so key-suffix-overlapping moves like
  `/x/a_b` → `/a/b` (keys `-x-a-b` / `-a-b`) sweep normally.

Note the report echoes matched lines — review it before pasting into shared
channels/CI logs, since a line that references `<old>` can also carry unrelated
sensitive content.

### 2. Confirm, then apply

Only after the user confirms the reported set, rewrite in place:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-.}/core/infra/reorg-sync.sh" \
  --old <old-prefix> --new <new-prefix> --root <tree> --apply
```

Replacement is a literal substitution **anchored at a path-component boundary via a
Unicode-aware whitelist on both sides** — a match counts only when the next
character is `/`, a line/string end, whitespace, or an unambiguous delimiter (quote,
`: , ; = | < > ( ) [ ] { }`), AND the preceding character is likewise a whitelisted
boundary (whitespace, quote, structural punctuation, the two-character shebang
sigil `#!`, or string start — a *bare* `!` or `#` is deliberately not a boundary,
since `/proj/dir!/old/x` is a legal path that must not tail-match). The left side
is a whitelist too — not a blocklist of
known body chars — so a combining mark (NFD text, the macOS filename normal form),
an emoji, or any other exotic character is treated as part of a longer name, and
`<old>` is never matched as the tail of an unrelated longer absolute path (e.g.
`/proj/x` never hits `/other/tree/proj/x`; a preceding `/` is deliberately *not* a
boundary). Any following character that is a word char in *any* script (so CJK
siblings like `.../논문` vs `.../논문자료` are safe), or `. - + @ ~ %`, marks a
longer sibling name and is left untouched. Writes are atomic (random-name `mkstemp`
temp + rename — a pre-existing file can never be clobbered as the temp target —
permissions preserved); a file that cannot be rewritten is reported on stderr and
the sweep continues, exiting 1 so the failure is visible. Binary files,
non-regular files (symlink/FIFO/socket/device — a FIFO would block the sweep
forever), and the `.git` object store are skipped — with one deliberate
exception inside `.git`: the worktree link is double-ended, so the repo-side
reverse pointer `.git/worktrees/<name>/gitdir` (a one-line file holding the
worktree's absolute path) is swept along with the checkout-side `.git` file,
while its siblings (`HEAD`, `index`, `commondir`, …) and everything else under
`.git` stay untouched (9th panel). The native-memory key is rewritten with the
harness's `/ . _` → `-` encoding, **anchored directly after `claude/projects/`** — ordinary kebab-case
text is never touched, and neither is an unrelated path component that merely
happens to equal the encoded key (`/backup/-old-x/f`).
Because that fold is lossy, **only the exact key (the moved dir's own, `cwd == OLD`)
is rewritten**: a `-`-continuation key like `-old-prefix-sub` is left untouched,
since after the fold it is indistinguishable from a dash/dot/underscore *sibling*
(`enc('/old/prefix/sub')` == `enc('/old/prefix-sub')`). Skipping a deeper key is a
safe miss (the orphaned dir simply stays, as before this tool) rather than risk
corrupting an unrelated project's key. See **Documented residuals** below for the
two limits this design accepts.

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
  **protected-span guard**: apply computes the literal-NEW spans positionally on
  the buffer (right-boundary-anchored only — a *written* span's left neighbour
  is whatever the splice left there, so requiring a left boundary missed the
  second of two adjacent rewrites and the tool re-ate its own output; 8th panel)
  and refuses to rewrite any OLD that *starts inside* one (already-migrated
  text). No text is mutated during the scan, so an adjacent
  component's boundary is never disturbed — the flaw that sank an earlier NUL-nonce
  mask (which corrupted a nested sibling) and a leading-only negative lookahead
  (which missed the copy of OLD that NEW reintroduces after a delimiter,
  compounding `/a:/a:/a…`); both were retired 2026-07-16. A ref that begins
  exactly where an already-migrated NEW span ends is likewise treated as
  migration residue: when NEW's own last character is a boundary char
  (`/backup (2026)`, `/srv:`), writing it flips the left boundary of whatever
  followed, so without that rule a re-apply ate one path component per pass. The
  two directions NO guard can make idempotent — promote-up (OLD under NEW) and
  suffix-overlap (NEW boundary-embedded inside OLD at offset ≥ 1, or a proper
  suffix of OLD = a boundary-terminated proper prefix of NEW)
  — are refused at the CLI instead (see step 1); the 5th, 8th and 9th panels
  proved each corrupts data on re-apply (one component eaten per pass, trailing
  or leading respectively). The remaining
  cost is a deliberate safe miss: a *fresh* OLD ref that coincidentally sits
  inside or immediately after literal-NEW-shaped text is treated as migrated and
  left alone — never corrupted. Confirm with `grep -rF '<old>'` after apply.
- Report fidelity: the dry-run report and `--apply` consume one shared match set
  (per-occurrence, span-guard applied), so the per-class counts equal the
  substitutions `--apply` performs exactly — in both directions. N same-class refs
  on one line count N; a line carrying BOTH a native-memory-key ref and a
  co-resident plain-path ref counts once per axis; a ref the span guard safe-misses
  is *not* counted (previously reported as a hit that apply then skipped).
- Scope is `--root`; run once per tree that may hold references (repo, dotfiles, notes).
- Cron `@keyword` schedules (`@daily`, `@reboot`) classify as `crontab` like numeric rows.

## Documented residuals (accepted limits — NOT "never corrupts")

Two hazards survive by explicit decision (2026-08-10); both are surfaced by the
dry-run report, which is why step 1 is mandatory:

1. **Whitespace-as-boundary sibling residual.** Whitespace — ASCII space AND
   Unicode whitespace (U+00A0 no-break, U+3000 ideographic, …) — is a boundary,
   so a sibling directory whose name is the moved prefix plus whitespace plus
   more (`/old/data 2024` for OLD `/old/data`; `/x/논문 자료` for OLD `/x/논문`)
   *is* matched at the prefix and would be part-rewritten by apply. Kept because
   the reverse trade-off is worse: without a whitespace boundary, every
   `see /old/x` / `run /old/x ...` reference goes undetected. Review the
   dry-run rows for such siblings before `--apply`.
2. **Lossy key-encoding collision.** The harness memory-key transform `enc()`
   folds `/`, `.`, `_` all to `-` and is non-injective: a sibling differing from
   OLD only in a folded char (`/x/10_Reference` vs `/x/10-Reference`) has the
   byte-identical encoded key, so its key-form refs are reported — and on apply,
   rewritten — together with the exact key. This is a property of the harness
   transform itself, not fixable in a text sweeper; the dry-run report shows
   every key hit for review.
