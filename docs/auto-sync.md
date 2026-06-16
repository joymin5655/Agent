# Auto-Sync (Auto-PR mode)

A `post-commit` git hook that keeps the remote up to date automatically whenever
the agent system changes. It pushes the current **feature branch** and ensures a
**pull request** exists. A human still merges — the hook never merges for you.

Hook file: `core/git-hooks/post-commit`.

## What it does

On every commit (when enabled), in order:

1. **Opt-in gate** — only runs if `git config --bool agent.autosync` is `true`.
2. **CI gate** — never runs when `GITHUB_ACTIONS` is set.
3. **Branch gate** — if you are on `main`/`master`, it logs and stops.
   Auto-PR mode never pushes the default branch directly.
4. **Scope gate** — only acts when the commit touched agent-system paths.
5. **Secret self-gate** — runs `gitleaks` on the new commit *before* any push.
6. **Push + PR** — in the background, pushes the branch to `origin` and, if no
   PR exists, opens one with `gh pr create --base main --head <branch> --fill`.

The commit returns instantly: the push and PR happen in a detached background
subshell. The hook is non-blocking — its exit code never affects the commit.

## Auto-PR mode (human merges)

This is **Auto-PR**, not auto-merge:

- It targets your repo's own remote via `origin` (whatever its URL is) — no
  hardcoded remote.
- It pushes **feature branches only**. It **never auto-pushes `main`/`master`**.
- It opens a PR against `main` and stops. **A human reviews and merges.**

## Enable

Two things are required:

1. Wire the hooks directory (sets `core.hooksPath=core/git-hooks`):

   ```bash
   bash setup.sh --hooks-only
   # or, with the full project scaffold:
   bash setup.sh --project
   ```

2. Opt in explicitly (default is OFF):

   ```bash
   git config agent.autosync true
   ```

Merely wiring `core.hooksPath` does **not** turn on auto-sync — the opt-in flag
is mandatory, so consumers never get surprise auto-pushes.

## Opt out

```bash
git config agent.autosync false
# or remove the setting entirely:
git config --unset agent.autosync
```

With the flag unset or `false`, the hook exits silently and does nothing.

## gitleaks self-gate (does not depend on pre-push)

Before any push, the hook scans the just-made commit with `gitleaks` (using
`gitleaks.toml` at the repo root if present). This is deliberately independent
of the `pre-push` hook:

- On a fresh clone, `core.hooksPath` may be unset, so the `pre-push` gitleaks
  gate is **not active**. Auto-sync therefore gates itself.
- If `gitleaks` is **not installed**, the hook refuses to push (it does not
  fall back to an unscanned push).
- If `gitleaks` **flags anything**, the push is aborted.

In all of these cases the commit itself is unaffected — only the auto-push is
withheld.

## Scope (agent-system paths only)

The hook only syncs commits that touched at least one of these top-level paths:

```
agents/  hooks/  skills/  core/  commands/  rules/  codex-skills/  docs/  .claude-plugin/
```

Commits that change nothing in these paths are skipped (logged as out of scope).

## Sync log

All outcomes are appended, timestamped (UTC), to:

```
<repo>/.git/agent-autosync.log
```

This lives inside `.git`, so it is never committed. Inspect it to see what the
hook decided and did on each commit.

## DRYRUN (testability)

Set `AGENT_AUTOSYNC_DRYRUN=1` to make the hook print the exact actions it *would*
take instead of running `gitleaks`/`git push`/`gh`:

```
DRYRUN push origin <branch>
DRYRUN gh pr create --base main --head <branch> --fill (if no PR exists)
```

This is what the decision-logic test (`core/tests/post-commit-autosync-test.sh`)
uses to assert behavior without touching the network.
