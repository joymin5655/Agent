# council-review — reference (read on demand)

Detail moved out of `SKILL.md` to keep it under the instruction budget
(`core/tests/instruction-budget.sh`). `SKILL.md` keeps a one-paragraph summary of each.

## Round cap

Review rounds on one PR/diff are capped so a guard-heavy change cannot loop for hours:

- **Rounds 1-2**: a full council and a `security-reviewer` re-review each run at most twice
  for the same PR/diff.
- **Round 3 onward**: confirm only the fix delta (the commits since the last round) with one
  `code-reviewer` dispatch. If the delta touches a risk-area file, add exactly one external
  lane via a single-lane `call-worker.sh` call — the pre-commit hook matches evidence to the
  staged risk files' blob hashes (`core/infra/review-evidence.py`), so a changed risk file
  needs fresh evidence. No third full council. `council-escalation-gate.py` still denies a
  plain `code-reviewer` dispatch when the delta is council-scale or touches a risk file, so
  wrap that one dispatch in the Step 0.5 council-active flag (`--council-flag set`) and clear
  it as in Step 6 — the cap narrows the review, it does not bypass the gate's evidence rules.
- **Leftover findings** go to the PR body under "Deferred findings" or to the backlog; they do
  not block the merge decision.
- **Exception**: a leftover finding that is Critical (security-incident class) earns another
  round. Record the reason in the PR body.

## Where captures live

Captures and their index live outside the plugin cache, per project:
`~/.agent/workers/<project-key>/<ts>-<role>.md` plus one `reviews.jsonl` row per
capture (`diff_key` = `$DK`); override the directory with `AGENT_WORKERS_DIR`.
Lane telemetry goes to `~/.agent/logs/council-lanes.jsonl`.

The `[[ -f "$CW" ]]` line is a diagnostic, not a short-circuit: if the path is
missing the dispatches below still run and each exits 127, which the
degradation table already maps to "lane absent" — the echo just names the
unresolved root instead of leaving a bare shell error. A missing `$CW`
therefore means every external lane is reported absent this run (step 5's
single-vendor warning applies) — never substitute a different resolution.

## The commit gate

The commit gate (`core/git-hooks/pre-commit`) blocks risk-area commits that have no
external `complete` review bound to the staged content. The user-only escape
`AGENT_REVIEW_OVERRIDE="<reason>"` exists for the case where every external lane is
down; an agent must never set it itself (`pre-tool-guard.sh` denies a Bash command that
sets the recognised assignment forms, and logs the attempt; a speed bump, not a boundary).
Risk areas are classified by `core/infra/council-threshold.sh`: migration,
secret, edge-fn, billing, and auth (code files only: an auth-family directory such as
`auth/`, `oauth/`, `authn/`, `authz/`, `authentication/`, `authorize*/`, `login/`, or a file
named `auth*`/`login*`/`*_auth*`; `author*` never matches). Out of the auth class: sso, session, jwt, token*, password*,
rbac/acl/iam, oidc/saml, mfa/otp, signin/signup, logout, and non-code policy files (only
`.rego` counts).

During a merge, a risk file whose staged state equals a merged-in parent's is not re-gated
when a remote DEFAULT branch (the target of `refs/remotes/<remote>/HEAD`, else
`<remote>/main`/`master`) contains that parent (any parent of an octopus). Remote-tracking
refs are local state an agent could rewrite, so this is a convenience for merging the
default branch in, not proof of review; a local branch, a scratch branch pushed to the
remote and a hand-written `MERGE_HEAD` earn no exemption. `core/git-hooks/pre-merge-commit`
runs the same check for auto-merge commits and passes the merged heads explicitly. Observed
limit: `git cherry-pick` and `git rebase` commit without running pre-commit at all, so they
are not gated.

Limits of the gate, stated plainly. The `pre-tool-guard.sh` guards (`review-override` for
`AGENT_REVIEW_OVERRIDE`/`AGENT_WORKERS_DIR`/`AGENT_LOGS_DIR`/`AGENT_WORKER_POLICY_CMD`/
`AGENT_BACKENDS_FILE`/`GITHEAD_*`, also `unset`/`env -u` of the policy and registry names,
`evidence-ledger` for `reviews.jsonl`/`review-override.jsonl`/`agent-author-vendors`) are
Bash-tool speed bumps: an interpreter
one-liner (python/perl/node -e) that sets env or writes files, and a script written then
run, evade them. The ledger row binds the diff key to "an external lane returned complete
while this key was set", not to the bytes the vendor actually read. In this framework repo
the gate code itself (`core/git-hooks`, `core/infra/review-evidence.py`,
`core/infra/council-threshold.sh`, `core/hooks/pre-tool-guard.sh`) is editable in-tree.
