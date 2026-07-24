# mattpocock/ai-hero-cli

- **Clone**: `_repos/reference/mattpocock-ai-hero-cli` (shallow)
- **License**: MIT · **Stars**: 79 · **Pushed**: 2026-07-21 (active) · npm `ai-hero-cli` v0.6.1

## Purpose

A CLI for running exercises in Matt Pocock's "AI Hero" paid course — browse/select/run
numbered exercise lessons, interactive navigation shortcuts (next/prev/quit/help), env-file
and cwd handling. Pre-installed in AI Hero course exercise repos.

## Architecture

- `src/bin.ts` entry point, standard commander-style CLI (`ai-hero exercise [n]`) with flags
  (`--root`, `--env-file`, `--cwd`, `--simple`).
- `qa/` — a folder of shell-script QA scenarios (`test-init.sh`, `test-walk-through.sh`,
  `test-pull-from-random-repo.sh`, `test-cherry-pick.sh`, `test-rebase-to-main.sh`, etc.) that
  exercise the CLI's git-integration surface (the CLI apparently helps students pull/reset/
  cherry-pick exercise solutions from a remote, based on script names — not independently
  confirmed by reading script bodies in this pass).
- `ralph/` — `once.sh`, `afk.sh`, `prompt.md`: looks like an "AFK agent loop" harness used
  internally (mattpocock's own dev tooling for maintaining the course), not part of the
  published CLI's public surface.

## Install / distribution mechanism

`pnpm add -D ai-hero-cli` (or pre-installed in course repos). No `postinstall` script
(grep confirmed). Nothing writes outside the installing project.

## Key patterns worth absorbing

None identified. This is course-delivery tooling (exercise navigation for a paid curriculum) —
its problem domain (present numbered lessons, track position, git-reset a student's local repo
to a lesson's starting state) doesn't map onto anything this harness does. The `ralph/afk.sh`
script is intriguing by name (suggests an unattended-agent-loop pattern, similar in spirit to
this harness's `/supervise --goal-mode`) but reading it would be investigating mattpocock's
private dev tooling rather than a published, documented pattern — out of proportion to spend
more analysis time here given the near-zero domain overlap already established.

## Overlap with this harness

None. Course exercise runner vs. this harness's engineering-workflow governance — different
problem domains entirely.

## Security notes

None applicable — local CLI, git operations on the user's own course-exercise repo, no network
surface beyond what git itself does.

## Verdict

REJECT. No overlap with this harness's purpose; a student-facing course tool, not an
agent-engineering pattern or reusable component.
