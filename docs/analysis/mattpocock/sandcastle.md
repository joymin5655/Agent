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

**Install-time: PASS, clean.** `npm install --save-dev @ai-hero/sandcastle` — no `postinstall`
script in `package.json` (grep confirmed, zero hits across the whole repo). The `sandcastle init`
CLI command scaffolds a `.sandcastle/` directory inside the current project only. Docker/Podman/
Vercel credentials and API keys (`CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`) are read from a
project-local `.sandcastle/.env` the user fills in themselves.

**Runtime: DOES write to `~/.claude/projects/` — correction to an earlier draft of this
dossier**, which claimed sandcastle "never touches `~/.claude`." That was wrong; verified by
reading the source rather than asserting from the README:

- `src/SessionStore.ts:56-64` (`claudeHostSessionPath`) and `:90-98`
  (`claudeSubagentsDirOnHost`) default to `join(process.env.HOME ?? "~", ".claude", "projects")`
  when no `hostProjectsDir` override is passed.
- `src/AgentProvider.ts:370-421` (`captureToHost`) copies the sandboxed agent's Claude Code
  session JSONL (and any subagent transcripts) out of the container and `writeFile`s them to
  that host path (`:348-349`, `:381`) — i.e. it writes real files under `~/.claude/projects/
  <encoded-cwd>/` after every run.
- `README.md:891`: **"Session capture is enabled by default for `claudeCode()`, `codex()`, and
  `pi()` and can be opted out via `captureSessions: false`."** — default-on, not default-off.

This is a documented, functional feature (so a sandboxed agent's session can be resumed
normally on the host afterward) — not a hidden or unconsented write in the OpenKnowledge sense
(no install-time trigger, the user explicitly invoked `sandcastle.run()`/`interactive()` to get
this behavior, and it's scoped to session-transcript JSONL files, not arbitrary config
mutation). But it is a real `~/.claude` write path, on by default, and this dossier should say
so accurately rather than assert its absence.

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

- Default-on session capture (see Install/distribution section above) writes the sandboxed
  agent's Claude Code session JSONL — and any subagent transcripts — to `~/.claude/projects/`
  on the host after every run (`src/AgentProvider.ts:370-421`). Direction of flow is
  sandbox→host, not exfiltration outward; the content is the same transcript the user would
  have produced running Claude Code directly, now persisted to the normal host location so
  `claude --resume` works afterward. Opt-out exists (`captureSessions: false`) but is not the
  default.
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
