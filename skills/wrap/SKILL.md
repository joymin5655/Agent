---
name: wrap
description: Commits staged changes and opens a PR. Runs gitleaks + risk-area guards before committing. Push is user-confirmed by default; --auto-push and --auto-merge are opt-in. NOT for review or verification (run those before wrapping), and NOT when nothing has changed yet — there is nothing to commit.
when_to_use: User asks to commit and/or push and open a PR — "wrap up", "ship this", "commit and push", "push it", "open a PR", `/wrap`; 한국어 "커밋하고 푸쉬", "푸쉬해줘", "PR 올려줘", "보안 점검하고 커밋". Applies even when the change is small or the diff is pasted inline — this skill runs gitleaks and the risk-area guards even in repos whose git hooks are not installed, so do not hand-roll git commit/push instead.
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

> Reviews happen BEFORE wrapping — for a multi-vendor opinion on the diff,
> run `/council-review --staged` first (skills/council-review/SKILL.md).

### 1. Pre-flight checks (gates)

Run in order; any failure aborts before the commit. A gate whose script is
missing (a runtime that did not fill in the plugin root) is reported as SKIPPED,
not as a pass or a fail.

a. **gitleaks** on staged diff:
   ```bash
   cd "$(git rev-parse --show-toplevel)" || exit 1
   if [ -f gitleaks.toml ]; then
     gitleaks protect --staged --redact -v --config=gitleaks.toml --no-banner
   else
     gitleaks protect --staged --redact -v --no-banner
   fi
   ```
   Without `--config`, gitleaks loads `GITLEAKS_CONFIG` or the repo's
   `.gitleaks.toml` when either is set or present, and its built-in rules only
   otherwise. It does not print which one it loaded at this verbosity, so check
   those two yourself and say which config ran in the report. Treat any nonzero
   exit as a finding until its output shows otherwise, and never rerun without
   `--config` to clear a failure.
   Before trusting a clean result, confirm the gate is actually *live* with the
   fire drill (W-3) — it plants a synthetic secret matching the harness's own
   rule and asserts gitleaks catches it, so a misconfigured allowlist can't give
   a false all-clear. Outside the harness repo the drill proves gitleaks and the
   harness's own rules are live (it uses the harness's `gitleaks.toml`), not
   that this project's allowlist is sane, so a PASS there is reported as
   "gitleaks live (harness rules); project config not drilled":
   ```bash
   # PASS = gate live; FAIL = misconfigured; exit 2 = gitleaks absent (SKIP)
   bash "${CLAUDE_PLUGIN_ROOT}/core/infra/gitleaks-fire-test.sh"
   ```
a2. **Remote-URL credential scan** (W-3) — a token baked into the push remote's
   URL lives in `.git/config`, invisible to the content scanners above:
   ```bash
   git remote get-url origin | python3 "${CLAUDE_PLUGIN_ROOT}/core/git-hooks/scan-remote-url.py"
   ```
   Nonzero exit = the remote URL embeds a credential; strip it before pushing.
   (The pre-push hook also runs this, but checking here fails earlier.)
a3. **Memory-pollution guard** — a memory plugin's session-context dump
   injected into a tracked instruction file (e.g. `AGENTS.md`) must never
   reach a commit:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/core/tests/memory-pollution-guard.sh" "$(git rev-parse --show-toplevel)"
   ```
   With no argument the guard checks its own copy, not this repo.
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
d. **Review-tier check** — run the review-cadence script, resolved from the
   plugin cache or the checkout (never bare cwd-relative — a plugin install
   has no `core/` under `$PWD`):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/core/infra/review-tier.sh" --staged
   ```
   A missing script is not a pass: report the check as SKIPPED (step 1's
   "a skipped gate is reported as skipped" rule) rather than reading its
   nonzero exit as "tier 0". `review-tier.sh` delegates the council-scale
   judgment to `council-threshold.sh` internally, so this single call
   replaces what used to be a direct `council-threshold.sh` invocation here.
   - **tier 2** (exit 10, council-scale — line/file threshold or a risk-area
     path) AND no council/degrade review happened this session for this diff
     (no row in `<workers dir>/reviews.jsonl` with `diff_key` equal to
     `python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/review-evidence.py" key --staged`,
     `status == "complete"` and a vendor other than the author's (anthropic unless
     the script's `author-vendor` subcommand names another) — that script's
     `check --staged` automates this, and
     `core/git-hooks/pre-commit` enforces it for risk-area paths; no
     single-vendor degrade note) → recommend `/council-review --staged` and confirm with the user
     before committing solo. For a size-only tier 2 this is advisory, not a
     gate abort — the user can proceed anyway. For risk-area paths the
     pre-commit hook blocks the commit: run `/council-review --staged`, and
     never set `AGENT_REVIEW_OVERRIDE` yourself (user-only). The check exists
     so a council-scale diff doesn't slip into
     a commit on the strength of a Claude-only review that
     `council-escalation-gate.py` never got a chance to catch (e.g. edits
     made without a Task/Agent dispatch).
   - **Round cap**: at most 2 full-council / `security-reviewer` rounds per PR/diff; from the
     3rd round only the fix delta is re-reviewed, inside the council-active flag so the
     escalation gate admits it (see `skills/council-review/SKILL.md` "Round cap").
   - **tier 1** (exit 5, the common case) → if no review artifact exists for
     this diff (the same `reviews.jsonl` diff_key / degrade-note check
     above), add a non-blocking advisory line recommending one
     `code-reviewer` pass before committing. Advisory, not a gate abort —
     same convention as the tier-2 line: the user can proceed anyway.
   - **tier 0** (exit 0, skip — docs-only or ≤`AGENT_REVIEW_SKIP_LINES`
     non-risk code lines) → proceed, printing one line noting the tier-0
     skip so it stays visible rather than silent, e.g. `review-tier: tier 0
     — skip (self-check only)`.
e. **Impact context** (advisory, never a gate). When the repo has a
   CodeGraph index, list the code outside this diff that depends on it and
   the test files the change reaches:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/impact-context.py" --staged
   ```
   Empty output means there was nothing to report: no `.codegraph/`, no
   codegraph installed, or no outside dependents. That is not a failure. When
   the output lists test files, show them and suggest running them before the
   commit if this session has not already run them. When it lists outside
   dependents, pass them to any reviewer dispatched in step d as callers to
   check. The script caps itself at 10s and 60 lines and always exits 0.

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
- `--auto-merge`: Push, then invoke `bash "${CLAUDE_PLUGIN_ROOT}/core/infra/auto-ship.sh" <PR-N>`.

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

## Credits

The "applies even when you could do it yourself" firing clause follows the
plugin-eval finding in addyosmani/agent-skills (`evals/README`, MIT).
