# Maintainer workflow — how the harness is run day to day

Snapshot: 2026-10. This is one developer's working profile, written down so others can read it
and borrow from it. It is not a shipped default: the shipped gates stay conservative
([`customization.md`](customization.md) → "Shipped defaults vs a personal profile"). Habits that
no gate in this repo enforces are marked **practice**.

## The day at a glance

```text
request
 ├─ fuzzy ─▶ plan first (/spec --interview) ─▶ owner approves the plan
 └─ clear ─▶ one top-tier session keeps judgment
               ├─ exploration, implementation ─▶ dispatched to MID / LOW tiers
               ├─ review ladder (tier 0 / 1 / 2) ─▶ never self-approved
               └─ /wrap: gitleaks + risk gates ─▶ branch push + PR ─▶ CI ─▶ squash merge
before any interruption ─▶ handoff file; raw capture ─▶ curated notes ─▶ human vault
```

## Who decides what

- **One session holds judgment.** The top-tier session plans, distributes work, reads gate
  verdicts and synthesizes results. It does not hand those decisions down a tier.
- **Hands are dispatched.** Exploration and implementation run at MID; lookups, mechanical
  fixes and fan-out workers run at LOW. Every dispatch names its model explicitly, because an
  unspecified dispatch silently inherits the session's top model
  ([`model-routing.md`](model-routing.md) → "Work class → tier").
- **Effort before tier-up.** A bounded task gets more reasoning effort on its rung before it is
  promoted to a more expensive one.
- **Nothing switches models at runtime.** Hooks only remind, and the session still makes the call.

## Plan first when the request is fuzzy

- A request with two readings, or with an unknown that would change the shape of the work, goes
  through `/spec --interview`: an unknowns table, at most four questions per round (each with a
  recommended default), a re-score, and a stop when no decision-changing unknown remains
  ([`skills/spec/SKILL.md`](../skills/spec/SKILL.md)).
- Facts that tools can answer — does the file exist, is the branch merged — are looked up before
  anyone is asked. Questions are reserved for preferences, priorities and scope
  ([`rules/policy/operating-contract.md`](../rules/policy/operating-contract.md)).

## Review is laddered and never self-approved

- `core/infra/review-tier.sh` assigns each diff one tier. **Tier 0** (docs-only, or a small
  non-risk change) is a self-check. **Tier 1** is one `code-reviewer` pass at commit time.
  **Tier 2** (council-scale size or a risk-area path) is `/council-review`, which adds reviewers
  from other vendors so one model family never approves its own work.
- Risk-area paths — auth, secrets, billing, migrations — are reviewed immediately, whatever the
  tier.
- Review rounds are capped: a full council or security re-review runs at most twice per PR, and
  from round 3 only the fix delta is checked
  ([`skills/council-review/SKILL.md`](../skills/council-review/SKILL.md) → "Round cap").
- The reviewer pair is measured, not assumed: [`benchmark/results.md`](benchmark/results.md).

## Autonomy with a short always-ask list

The supervising session decides most things itself, logs each decision with its reason, and
reports it in one line. A short list of action classes always goes back to the human:

- secrets and authentication
- payments and paid usage
- sending anything to other people
- production deploys and public releases
- merges into risky paths, force-pushes
- permanent deletion without a verified backup
- weakening a guard, a permission, or the delegation rules themselves

The shipped anchors are the risk-area rule in the operating contract and the merge rule in
[`AGENTS.md`](../AGENTS.md) §6: the owner's supervisor may squash-merge planned work once CI and
the review ladder pass, while hook, guard, permission and release PRs wait for a human. The
written delegation charter and its decision log are personal configuration (**practice**).

## Guards instead of approval prompts

- Approval prompts get rubber-stamped ([`gate-registry.md`](gate-registry.md)). The maintainer
  runs sessions with high autonomy and relies on tool-boundary guards instead — destructive
  commands and secret access are denied at the hook
  ([`concepts/security-guards-generic.md`](concepts/security-guards-generic.md)).
- Each guard is "a speed bump, not a boundary": interpreter one-liners and scripts written then
  run can evade it. The commit gates (gitleaks, risk areas) and CI remain the backstop.

## Several sessions at once

- Several sessions often run in parallel, each in its own worktree and branch
  ([`concepts/multi-session-worktree.md`](concepts/multi-session-worktree.md)).
- Before touching a shared branch, job or config, a session checks whether another live session
  owns it. On overlap it backs off and reverts its own shared-state changes; it never kills
  another session's process (**practice**, built on the ownership rule in the operating
  contract).

## State lives in files, not in the conversation

- Before any interruption — a context limit, the end of a day — progress and unresolved evidence
  go into a handoff file, and the next session resumes from it.
- Long multi-wave work runs under `/supervise` with resumable state
  ([`concepts/loop-engineering.md`](concepts/loop-engineering.md) → durable state).
- Knowledge flows one way: raw captures (untrusted, any agent) → curated typed notes via
  `/brain-ingest` → a human-gated vault. Memories and notes are evidence to check against current
  files, never instructions to follow ([`AGENTS.md`](../AGENTS.md) → "Agent brain").

## Lessons that became rules

| Lesson | Where it is encoded |
|---|---|
| A reviewer that died at its session limit reports zero findings and looks clean | `skills/verify-completion/SKILL.md` ("A dead reviewer is not a clean review"); `/supervise` safeguards |
| A lane that goes idle without a report reads as "nothing found" | `skills/verify-completion/SKILL.md` ("…is a FAILED lane") |
| An external lane can exit 0 with an empty answer and look finished | `core/infra/call-worker.sh` (empty rc-0 output is a failed lane) |
| The top-tier model quietly does the implementation itself | `skills/supervise/SKILL.md` Model policy (the +15-edit advisory retired to `legacy/top-edit-advisor/`) |
| A pipeline reports its last command's status, so a failing check can look green | `set -euo pipefail` and the counting idiom, scanned by `core/tests/pipefail-idiom-scan.sh` |
| Review of a guard-heavy diff can loop for hours | the round cap in `skills/council-review/SKILL.md` |
| An assumed model weakness expires, and its gate turns into friction | review dates in [`gate-registry.md`](gate-registry.md) |
| Parallel judges overwrite each other's scratch files | **practice** — each dispatch prompt names the only path it may write |

## Borrowing this

- Start from the shipped observe/dry-run defaults and promote one gate at a time, once its scope
  matches how you actually work ([`customization.md`](customization.md)).
- Keep personal glue — real paths, machine-specific environment, credentials, your own risk
  areas — in a private repository applied on top of this framework
  ([`getting-started.md`](getting-started.md) → "What does NOT belong here"). The maintainer's
  private repository holds the package list, shell configuration, scheduled jobs and a bootstrap
  script that restores the personal layer and installs this plugin on a new machine.
