# mattpocock/sandcastle

- **Clone**: `_repos/reference/mattpocock-sandcastle` (shallow, HEAD as of 2026-07-25 clone)
- **License**: MIT · **Stars**: 7,012 · **Pushed**: 2026-06-29 (active) · npm `@ai-hero/sandcastle` v0.12.0

## Purpose

A TypeScript library (+ CLI) for orchestrating AI coding agents (Claude Code today) inside
isolated sandboxes — Docker, Podman, or Vercel microVMs — with a configurable branch/worktree
strategy: agent runs on an isolated branch, commits get merged back. Built for parallelizing
multiple AFK (away-from-keyboard) agents, review pipelines, or custom orchestration.

## Architecture

- Core primitives: `run()` (fire-and-collect), `interactive()` (TUI session), `createSandbox()`
  (lower-level handle). Each takes an `agent` (currently `claudeCode(model, opts)`) and a
  `sandbox` provider.
- `SandboxProvider` abstraction (`src/SandboxProvider.ts`) — pluggable backends implemented via
  two factory helpers: `createBindMountSandboxProvider` (Docker/Podman — host filesystem bind
  mount) and `createIsolatedSandboxProvider` (Vercel Firecracker microVMs — fully isolated, no
  host mount). `noSandbox()` is an explicit opt-out for running directly on the host.
- `WorktreeManager` + `CopyToWorktree`/`syncIn`/`syncOut` — git worktree lifecycle around each
  sandbox run: creates an isolated branch, copies files in, runs the agent, copies commits back
  out, merges. This is the same worktree-isolation idea this harness already uses for parallel
  wave dispatch (`.worktrees/`), but sandcastle also adds *container* isolation on top of git
  worktree isolation — two layers, not one.
- `src/templates/{blank,parallel-planner,parallel-planner-with-review,sequential-reviewer,
  simple-loop}` — scaffolded orchestration patterns a user picks via `sandcastle init`, each a
  runnable `.sandcastle/main.ts` starting point.
- Test coverage is extensive (near 1:1 test-file-per-source-file), including
  Windows-path-specific test variants (`*-windowsMounts.test.ts`) — signals real
  cross-platform users, not a toy.

## Install / distribution mechanism — OpenKnowledge precedent check

**PASS, clean.** `npm install --save-dev @ai-hero/sandcastle` — no `postinstall` script in
`package.json` (grep confirmed, zero hits across the whole repo). The `sandcastle init` CLI
command scaffolds a `.sandcastle/` directory **inside the current project only** — never
touches `~/.claude` or any global path. Docker/Podman/Vercel credentials and API keys
(`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`) are read from a project-local `.sandcastle/.env`
the user fills in themselves — explicit, not auto-collected.

## Key patterns worth absorbing

1. **Two-layer isolation (git worktree + container)** — this harness's `/supervise` and
   worktree-isolated waves (e.g. this very wave, `.worktrees/w3-mattpocock`) give filesystem/git
   isolation between concurrent agents on the *same machine*, but nothing stops a wave's agent
   from running arbitrary shell commands against the real host (network, other processes,
   installed tooling). Sandcastle's container layer is a genuinely different risk boundary this
   harness doesn't have. **Not recommended to adopt now** — this harness targets a single
   developer's own trusted machine running Claude Code directly (not a multi-tenant or
   fully-autonomous AFK setup), so container sandboxing would add real operational weight
   (Docker/Podman dependency, image maintenance) for a threat model this project hasn't hit yet.
   Worth revisiting if `/supervise --goal-mode` autonomy is ever extended to run genuinely
   untrusted or long-unattended agent code.
2. **`noSandbox()` as an explicit, named opt-out** rather than an implicit default — a small
   but good API-design habit: sandboxing is opt-in by requiring a provider argument, and
   *skipping* it is a deliberate, visible choice (`noSandbox()`) rather than "just don't pass
   `--sandbox`." No direct equivalent needed in this harness (we don't sandbox at all today),
   but worth keeping in mind if sandboxing is ever added — make the escape hatch as visible as
   the guardrail.
3. **Provider abstraction shape** (`createBindMountSandboxProvider` /
   `createIsolatedSandboxProvider`) is a clean example of "two families of backend, one
   factory-function contract" — generically reusable API design, not agent-specific. Noted for
   awareness, no direct application found in this repo's current surface.

## Overlap with this harness

None functionally — this harness has no sandboxing or container orchestration layer at all.
Conceptual overlap only in "run an agent, collect its diff, merge it back," which this harness
does via plain git worktrees (`.worktrees/<slug>`, see `docs/model-routing.md` and Wave
delegation contracts) without any container step.

## Security notes

- Bind-mount providers (Docker/Podman) share the host filesystem with the sandbox by design —
  isolation is process/dependency-level, not filesystem-level, unless mounts are scoped
  carefully (the `mounts:` config supports `readonly: true` per mount, which is good practice
  the docs demonstrate by example).
- Vercel provider is the only *fully* isolated backend (microVM, no host mount) — the README is
  upfront about this distinction (`Bind-mount` vs `Isolated` column in the providers table),
  which is a good transparency pattern: it doesn't let "sandboxed" imply a uniform security
  guarantee across backends.
- `containerUid`/`containerGid` override with a "pre-flight check catches mismatches" — shows
  awareness of the classic Docker bind-mount UID/permission footgun.

## Verdict

DEFER. Real, well-built tool solving a problem (untrusted/parallel agent execution isolation)
this harness doesn't currently have — no current wave or backlog item calls for container-level
agent sandboxing. Revisit if `/supervise --goal-mode` autonomy scope grows to include
genuinely untrusted code execution.
