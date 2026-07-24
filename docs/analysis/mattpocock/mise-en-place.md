# mattpocock/mise-en-place

- **Clone**: `_repos/reference/mattpocock-mise-en-place` (shallow)
- **License**: none declared · **Stars**: 7 · **Pushed**: 2026-05-31

## Purpose

Matt Pocock's personal business-operations automation repo: invoice-to-PDF generation, X
(Twitter) auth/mentions/analytics scripts, a Todoist smoke-test script, and a `close-mention`
script. Not agent-orchestration tooling — it's ops scripting for running his own newsletter/
course business.

## Architecture

Flat `scripts/*.mts` (Node `--env-file`-driven scripts), a `prep-plan.md`, and one dependency
of note: `"@ai-hero/sandcastle": "^0.5.10"` plus an `x:sandcastle` script
(`npx tsx ./.sandcastle/main.ts`) — this repo is a **real-world consumer of `sandcastle`**
(see `sandcastle.md`), using it presumably to run an agent that handles X mentions or similar
personal-automation task inside a sandbox. That's the only thing here worth noting: independent
confirmation that sandcastle is used in anger by its own author outside the library repo itself,
which is a mild positive signal for sandcastle's maturity, not a pattern to take from
mise-en-place itself.

## Install / distribution mechanism

N/A — private personal-ops scripts, not a distributed package or tool. No installer to check.

## Key patterns worth absorbing

None. Business/personal ops scripting (invoices, social media bot mentions, Todoist) has no
overlap with a coding-agent-orchestration harness's concerns.

## Overlap with this harness

None.

## Security notes

Contains scripts that read `.env` for X/Todoist API credentials — standard local secret
handling, nothing unusual, and not this project's concern since it's not being adopted.

## Verdict

REJECT. Personal business tooling with no engineering-pattern content relevant to this harness.
