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

Read a lane's PARAPHRASE and findings from its own answer only. A codex capture repeats the
whole prompt, output contract included, before answering: its answer is the block after the
capture's last `tokens used` count. A gemini capture is one JSON object: its answer is the
`response` value.

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

## Approval declined (step 2)

Skip every external lane that needed approval (no YES call for it; with no policy that
means no `call-worker.sh` calls at all) and proceed with the lanes that ran, or the Claude
`code-reviewer` lane alone. When no external lane ran, this is the same "single-vendor
review" degrade the single-vendor warning (step 5) reports, so the report's first line must
say so rather than borrow the council's authority. The `code-reviewer` dispatch still needs
the step 0.5 flag — the gate does not know approval was declined, only that the
council-active flag is fresh and bound to this diff's hash.

## Lane dispatch notes (step 3)

Each lane runs once per attempt (an approved policy exit 3 retries at most once, with YES),
and every attempt writes its own `<lane>.<attempt>.path`/`.err`.
`core/tests/council-lanes-test.sh` runs the lines between the `council-lanes` markers. In the
policy branch the first wait happens before the question, because only exit 3 lanes are asked
about; the `code-reviewer` lane still runs alongside them. The pre-dispatch refusal path
(exit 3) writes no capture file, so the exit code is the only signal for it. Do not
sleep-poll: each lane's `timeout_s` is the hard cap.

## Degradation

| Signal | Meaning | Action |
|---|---|---|
| call-worker exit 3 | not approved: no `AGENT_WORKER_YES=1`, or the policy said no / failed closed | ask once (step 2, the user's money decision) and re-run with YES, or drop the lane |
| exit 127 / `status: unavailable` | lane disabled, CLI or preflight missing, capped by the policy, or the author's own vendor | lane absent, quote reason |
| exit 124 / `status: timeout` | hung CLI killed | lane absent |
| exit 1 / `status: rate-limited` | vendor quota/rate limit hit (e.g. the Antigravity account quota) | lane absent — fail-open; report "rate-limited, retry later", never an upgrade pitch |
| exit 1 / `status: failed` | backend errored | lane absent, quote stderr tail |

External failures never abort the review — the Claude lane carries it.

## Dispositions and ledger

Every finding that survives the citation check gets exactly one disposition:

- `fix` — fixed in this change (every Act on finding).
- `contest` — wrong, shown with evidence the lane could read: a quoted line of the diff or of
  its prompt, or a repository file the lane could open.
- `escalate` — wrong only by evidence outside the lane's input (a recorded decision, another
  repo, a convention not in the repo). Cite it (`file:line` or decision ID), list it in the
  report's "Escalated" section, and flag Blocker/Major ones at the top for the owner to confirm.
- `decline` — true but not acted on here (a nit, or Noted/backlog).

Mapping: Act on → `fix`; Consider → `fix` or `decline`; Noted → `decline` (or `fix` when it
is fixed anyway); Dismissed → `contest` or `escalate` (by where the evidence lives).
`escalate` exists only for Dismissed findings.

Rules: a PARAPHRASE mismatch cannot be contested; never lower a severity without evidence;
"I wrote it" is not evidence.

### Round ledger

Path: `<workers-dir>/ledgers/<branch>.jsonl`. `<workers-dir>` is the folder call-worker
writes this run's captures to: `$AGENT_WORKERS_DIR`, else `~/.agent/workers/<project-key>`
with `<project-key>` from `python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/review-evidence.py"
project-key`. `<branch>` = the current branch with `/` replaced by `__` — stable across
rounds, unlike the diff key. Append one `jq -cn` line per finding per round:

```json
{"id":"codex-r1-2","round":1,"lane":"codex","file":"core/x.sh","line":41,
 "quote_sha256":"<hash>","severity":"Major","category":"logic",
 "disposition":"fix","evidence":"","status":"fixed"}
```

`id` = `<lane>-r<round>-<n>`; `status` is `open|settled|deferred|fixed`, set by the
disposition: `fix` → `fixed`; `contest` → `settled`; `decline` → `deferred`; `escalate` →
`open` until the owner rules (then `settled`, or re-bucketed and `fixed`/`deferred`). Store the
quote's hash, never its text.

Match key: same `file` and equal `quote_sha256`; when the quoted line changed, same `file`,
same `category` and a `line` within ±5. The ledger is never sent to the lanes (fresh eyes each
round); the synthesizer reads it:

- a finding matching a `settled` or `deferred` entry is not re-litigated — report
  "settled/deferred in round N";
- a finding matching a `fixed` entry reopens it (the fix did not hold);
- an entry reopened a second time stops the loop and goes to the owner.

The two-round cap stays (see Round cap). The PR body's "Deferred findings" are the ledger's
`deferred` entries; the report's "Escalated" section lists the `open` ones.
