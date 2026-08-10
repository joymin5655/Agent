---
name: wrap
description: Commits staged changes and opens a PR. Runs gitleaks + risk-area guards before committing. Push is user-confirmed by default; --auto-push and --auto-merge are opt-in. NOT for review or verification (run those before wrapping), and NOT when nothing has changed yet — there is nothing to commit.
when_to_use: User asks to commit and open a PR — "wrap up", "ship this", or `/wrap`.
tools: Bash, Read, Grep, Glob
---

# /wrap

## Goal

Move from "code written and tested locally" to "PR open on GitHub" in
one skill invocation, with all the safety gates intact.

## Modes

| Mode | What it does | Trigger |
|---|---|---|
| `/wrap` | Commit + open PR. **User pushes manually.** | Default. |
| `/wrap --auto-push` | Commit + push + open PR. User merges. | Explicit. |
| `/wrap --auto-merge` | Full chain via `core/infra/auto-ship.sh`. | Explicit. |

`--auto-merge` requires all 4 trigger conditions from
`rules/policy/actions-billing-admin-merge.md` to hold.

## Steps

### 1. Pre-flight checks (gates)

Run in order; any failure aborts before the commit.

a. **gitleaks** on staged diff:
   ```bash
   gitleaks protect --staged --redact -v --config=gitleaks.toml --no-banner
   ```
   Before trusting a clean result, confirm the gate is actually *live* with the
   fire drill (W-3) — it plants a synthetic secret matching the repo's own rule
   and asserts gitleaks catches it, so a misconfigured allowlist can't give a
   false all-clear:
   ```bash
   bash core/infra/gitleaks-fire-test.sh   # PASS = gate live; FAIL = misconfigured; exit 2 = gitleaks absent (SKIP)
   ```
a2. **Remote-URL credential scan** (W-3) — a token baked into the push remote's
   URL lives in `.git/config`, invisible to the content scanners above:
   ```bash
   git remote get-url origin | python3 core/git-hooks/scan-remote-url.py
   ```
   Nonzero exit = the remote URL embeds a credential; strip it before pushing.
   (The pre-push hook also runs this, but checking here fails earlier.)
a3. **Memory-pollution guard** — a memory plugin's session-context dump
   injected into a tracked instruction file (e.g. `AGENTS.md`) must never
   reach a commit:
   ```bash
   bash core/tests/memory-pollution-guard.sh
   ```
   FAIL = revert the injected block (`git checkout -- <file>`) before committing.
b. **Whitelist path scan** — only files inside allowed paths should be
   staged. Allowed paths default to anything except `secrets/`,
   `.env*` (excl. `.env.example`). Override via `hook-config.yml`.
c. **Risk-area scan** — for each of the 5 risk areas
   (`rules/policy/security-guards.md`):
   - `data` (e.g., `migrations/*.sql`) → ABORT, user must drive.
   - `secrets` → ABORT.
   - `deploy` (function bundles) → ABORT, user must drive.
   - `payment` → ABORT, user must drive.
   - `domain-output` → advisory; if net removal, ABORT.

### 2. Commit

- Generate a conventional-commit message (`feat:`, `fix:`, etc.).
- Body: 1–3 lines on **why** (not what — the diff says what).
- Trailers: `Co-Authored-By` if you (the AI) are an authoring agent.

```bash
git commit -m "<type>: <subject>

<body>"
```

If pre-commit hook fails: read its stderr, fix the underlying issue,
re-stage, and create a **new** commit (don't `--amend`).

### 3. Push (mode-dependent)

- Default `/wrap`: **don't push**. Report the commit SHA and tell the
  user how to push when ready.
- `--auto-push`: `git push -u origin <branch>` (pre-push hook runs).
- `--auto-merge`: Push, then invoke `core/infra/auto-ship.sh <PR-N>`.

### 4. Open PR

Only if push happened.

```bash
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
- …
- …

## Test plan
- [ ] …
- [ ] …
EOF
)"
```

Title: short (≤ 70 chars). Body: summary + test plan.

### 5. Report

```
Commit: <sha> on <branch>
Push: <yes/no>
PR: <url or "not opened">
Next steps: <what user should do>
```

The wrap is complete only when this report is emitted with a real commit SHA
and every step-1 gate actually ran (a skipped gate is reported as skipped,
never silently omitted).

## Hard rules

- **Never bypass gates** with `--no-verify` unless the user has typed
  that flag in their message.
- **Never force-push** to `main` or another agent's branch (R6).
- **Never commit `.env*`** (only `.env.example`).
- **Never amend** a commit that's been pushed.
- If user says "stop" or "cancel" at any step, halt immediately.

## Skill failure modes

- gitleaks finds a real secret → ABORT, instruct user to rotate the
  secret and re-stage.
- Risk-area violation → ABORT, instruct user that this requires manual
  review.
- CI fails after push → don't auto-merge; report and let user decide.
