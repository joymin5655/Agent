# OpenRouter Adapter — free-tier advisory lane only

**This adapter is a WORKER-LANE bridge, not a runtime host adapter** — same
positioning as `adapters/grok/`. It does not wire the framework's hooks into
an OpenRouter-hosted session; it lets `core/infra/call-worker.sh` dispatch
one-shot, read-only prompts TO OpenRouter's `:free` chat-completions API as a
cross-vendor **advisor**. `adapter-parity.sh` checks hook parity across
claude-code/codex/gemini only; openrouter is intentionally outside that set.

Unlike grok/gemini (a wrapped agentic CLI with a live local `shell` tool),
this lane is a direct HTTPS call — there is no local tool for a prompt to
drive, so this adapter carries no OS sandbox. See "Read-only" below for what
it carries instead.

Role wiring (`core/infra/backends.json`): openrouter carries the
**`advisor-free`** role only. It is deliberately NOT wired into any gate role
— an advisory lane, never a completion-gate vote. Consumers opt in explicitly
(e.g. `/council-review --with-free`).

## Files

| File | Purpose |
|---|---|
| `openrouter-worker.sh`           | stdin→HTTP bridge (curl) + sensitive-cwd guard + retention warning. |
| `openrouter-preflight.sh`        | Fail-closed exact-token health probe (call-worker runs it). |
| `openrouter-tiers.json.template` | Model pin per tier (→ `~/.openrouter/agent-tiers.json`). |
| `sensitive-paths.template`       | Generic cwd blocklist (→ `~/.config/agent-harness/sensitive-paths`). |

## Installation

```bash
ln -sf "$PWD/adapters/openrouter/openrouter-worker.sh"    ~/bin/openrouter-worker
ln -sf "$PWD/adapters/openrouter/openrouter-preflight.sh" ~/bin/openrouter-preflight
mkdir -p ~/.openrouter ~/.config/agent-harness
cp -n adapters/openrouter/openrouter-tiers.json.template   ~/.openrouter/agent-tiers.json
cp -n adapters/openrouter/sensitive-paths.template          ~/.config/agent-harness/sensitive-paths
```

(or `setup.sh --openrouter`, which does the same). Credential: an
[OpenRouter](https://openrouter.ai) API key registered in the macOS Keychain:

```bash
security add-generic-password -a "$USER" -s openrouter-api-key -w
```

The same Keychain entry is also read by
`adapters/claude-code/launchers/claude-ox` (the OpenRouter gateway session
launcher) — one credential, two consumers. The preflight refuses the lane
until a real round trip succeeds; the credential's presence proves nothing.

## What "free" costs here: retention, not sandboxing

A `:free` OpenRouter route is commonly served by an anonymous upstream
provider whose documented policy is to log, retain, and/or train on prompts
and responses — this is the actual cost of the lane, not money. Two things
enforce that:

1. **Retention warning** — printed to stderr on every dispatch
   (`openrouter-worker.sh`), unconditionally.
2. **Sensitive-cwd guard** — the worker refuses to dispatch when the caller's
   working directory is under a path listed in
   `~/.config/agent-harness/sensitive-paths` (installed from
   `sensitive-paths.template`, which ships only generic defaults — `~/.ssh`,
   `~/.aws`, `~/.config`, `~/.claude`, `~/.claude-ox`). Add project- or
   client-specific paths to your local copy; they must never be committed
   here. Override: `AGENT_OPENROUTER_FORCE=1` (explicit, still warned).

There is no OS sandbox here because there is nothing local for a malicious
prompt to drive — the worker never grants the model a shell, file-write, or
exec capability; it is a single HTTP request/response. The credential is kept
out of argv and logs: it is written into a private `curl -K` config file
inside the run's private `mktemp -d` work directory (never `-H` on the
command line, which would be visible to other local users via `ps`), and
removed with the work directory on exit.

## Tier policy

Model IDs are forbidden in `core/infra/backends.json` (no-model-ids gate).
Unlike grok (one model, per-tier CLI reasoning-effort flags), an HTTP `:free`
lane has no CLI to vary — each tier (`LOW`/`MID`/`TOP`) pins its own model in
`openrouter-tiers.json.template`. The shipped template pins
`nvidia/nemotron-3-super-120b-a12b:free` at every tier (2026-08-25 research +
live probes: research shortlist #1 `z-ai/glm-5.2:free` 429'd on both probes
while nemotron passed the exact-token preflight first try — see
`.agent/plans/free-lanes-and-launchers/spec.md` § Research verdicts). Updating
the pin is a template edit only; no code change.

## Egress floor

The worker refuses, before anything leaves the machine: a prompt over
`OPENROUTER_PROMPT_MAX_BYTES` (default 256KiB), or one matching an
unmistakable credential shape (private key blocks, `AKIA…`, `sk-…`, `ghp_…`,
`xox…`). Override — loud, per-dispatch — with
`AGENT_OPENROUTER_UNSAFE_PROMPT=1`. This is a floor, not a gitleaks
replacement: assemble prompts from reviewed diffs, not raw files.

## Cost

The `:free` tier is, per its name, free — `call-worker.sh` still refuses
without `AGENT_WORKER_YES=1` (the session that owns the user relationship
asks first), because the lane still sends prompt content to a third party.
On HTTP 429 (rate-limited) the worker exits 75 (EX_TEMPFAIL), which
`call-worker.sh` maps to `status: rate-limited` — the council fails open,
same contract as grok's free-tier lane.

## Positioning

This lane exists for the same reason grok's advisory seat does — perspective
diversity ("different models fail differently") — at zero subscription cost
and correspondingly lower trust. Findings arrive tagged `[free:advisory]` and
never flip a gate; the model pinned behind it is not vetted as an authority,
only as one more independent read on the diff.
