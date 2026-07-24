# mattpocock/slopwatch

- **Clone**: `_repos/reference/mattpocock-slopwatch` (shallow)
- **License**: none declared (no `LICENSE` file found) · **Stars**: 40 · **Pushed**:
  2026-04-20 (~3mo stale, and code confirms very early stage — see below)

## Purpose

"Self-hosted, on-prem observability platform for coding agents" (per `CONTEXT.md`) — intended
to ingest normalized events (Session/Turn/Model request) from per-agent Listeners (Claude Code,
Codex CLI, Pi, OpenCode, Copilot CLI), store them in Postgres, and serve a cost/usage dashboard
("This Session cost $14 — where did it go?" is the example dialogue in `CONTEXT.md`).

## Architecture (bun monorepo: apps/, packages/, listeners/)

- `packages/events` — `@slopwatch/events`, the shared `NormalEvent` schema and typed
  Listener→Server client.
- `listeners/claude-code` — the only listener present in this clone. **Its entire
  implementation is a 4-line stub**: `console.log("slopwatch claude-code listener stub")`,
  imports `sendEvents`/`NormalEvent` but never calls them.
- `apps/server` — presumably the Postgres-backed ingest/dashboard server; not deeply inspected
  since the listener (the part that would actually integrate with Claude Code) is unimplemented.
- `research/v1-architecture-decisions.md`, `research/coding-agent-ingestion.md`,
  `research/developer-leaderboard-design.md` — design docs exist and are fairly developed;
  the code has not caught up to them yet.
- `docs/adr/0001-bun-everywhere.md` — one ADR so far (bun as the runtime/package-manager
  choice).

## Install / distribution mechanism

N/A in practice — there is nothing installable yet. No package is published; the listener that
would integrate with a user's Claude Code install is an unimplemented stub. No security-relevant
install-time behavior to check because there is no working install path.

## Key patterns worth absorbing

1. **`CONTEXT.md` as an explicit domain-vocabulary contract**, with a "Language" section
   (canonical terms + an `_Avoid_:` list of near-synonyms to reject), a "Relationships" section,
   an example dialogue showing the vocabulary in use, and a "Flagged ambiguities" section
   logging terms that were debated and how they were resolved (or left open). This is a
   genuinely well-executed instance of a pattern — glossary-with-provenance — that this
   harness's `mattpocock/skills` `domain-modeling` skill also produces as an *output*. Nothing
   to absorb mechanically (this harness doesn't maintain its own multi-entity domain model at
   that scale — it's a dev tool, not a multi-service product), but it's a good reference
   example of the `CONTEXT.md` shape if this harness's docs ever needed one.
2. The event taxonomy itself (Session → Turn → Model request, with Subagent as a
   parent-pointer child Session) is a reasonable normalized shape for coding-agent telemetry,
   relevant background if this harness's own M-8 "cost/usage instrumentation" backlog item
   (referenced in memory as "open") is ever picked up — but slopwatch's own listener for
   exactly that integration doesn't exist yet, so there's no working implementation to borrow
   from, only a target schema shape to be aware of.

## Overlap with this harness

Conceptually adjacent to the still-open M-8 backlog item (cost/telemetry instrumentation) but
zero implementation overlap — slopwatch's own Claude Code integration doesn't work yet, so
there's no code path to study, wrap, or wire against.

## Security notes

- None inspectable — no working listener to audit for how it would hook into Claude Code (env
  vars, hook registration, transcript access) since that integration doesn't exist yet.
- Self-hosted-only positioning ("on-prem observability platform") is a reasonable default stance
  for a tool that would otherwise ingest an org's full agent transcripts/costs to a third party
  — worth noting as a design choice to require of any *future* telemetry tool this harness might
  adopt, even though slopwatch itself isn't ready to adopt.

## Verdict

DEFER. Too early-stage to adopt (core integration is a 4-line stub, not a working tool) — revisit
if/when the Claude Code listener actually ships and M-8 (cost instrumentation) becomes active
work. The `CONTEXT.md` vocabulary-contract pattern is noted as a reusable documentation shape,
not something to import now.
