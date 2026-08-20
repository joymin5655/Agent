---
name: worker-setup
description: Per-lane install → auth → verify onboarding for the cross-vendor worker lanes (codex, antigravity/gemini, grok, kiro) with a cost-model/tier briefing before anything is installed. NOT a dispatcher (`core/infra/call-worker.sh` is), and NOT a paid probe run without explicit user approval — every real round-trip probe is announced before it runs.
when_to_use: "/worker-setup", "set up codex/gemini/grok/kiro lanes", `setup.sh --doctor` WARNed about a worker lane, or `/council-review` reported a lane absent and the user wants to fix that.
tools: Bash, Read, Grep, Glob
---

# /worker-setup

## Goal

Onboard the cross-vendor worker lanes (`core/infra/backends.json`) one at a
time: install → authenticate → verify, with an honest cost/allocation
briefing up front. This skill never dispatches a review or a completion
check itself — that is `core/infra/call-worker.sh`, consumed by
`/council-review` and `/verify-completion --second-opinion`. This skill only
gets a lane from absent to healthy.

## Step 0 — resolve the harness root

```bash
HR="${CLAUDE_PLUGIN_ROOT:-$PWD}"
test -f "$HR/core/infra/backends.json" || echo "worker-setup: backends registry not found at $HR — plugin users: reinstall the plugin; repo users: run this from the repo root" >&2
```

Stop here with that guidance if the registry does not resolve. Every command
below is relative to `$HR`.

## Step 1 — read-only status sweep (zero paid calls)

Read `$HR/core/infra/backends.json` **live** with `jq` — never hardcode the
lane list, the registry is the source of truth and can grow lanes this skill
has never seen. For every backend, report one row:

| Column | How to get it |
|---|---|
| lane | the backend's key in `.backends` |
| vendor | `.backends[$lane].vendor` |
| cmd on PATH | `command -v` on `.backends[$lane].cmd[0]` |
| preflight on PATH | `command -v` on `.backends[$lane].preflight[0]` |
| config seeded | codex: `~/.codex/config.toml` exists; gemini/antigravity: `~/.gemini/antigravity-cli/agent-tiers.json`; grok: `~/.grok/agent-tiers.json`; kiro-*: at least one `~/.kiro/agents/*.json` matching a `--agent` in that lane's `tier_args` |
| cost model | from step 2's table |
| tiers | keys of `.backends[$lane].tier_args` |
| roles served | reverse-lookup: which `.roles[*].backend` (or `.fallback`) names this lane |

Also check once, separately: is `$HOME/bin` on `PATH` (workers/preflights
resolve from there — `setup.sh`'s `ensure_home_bin`/doctor row).

This step makes zero network calls and zero CLI invocations beyond
`command -v` — it is safe to run unconditionally, including before the user
has decided anything.

## Step 2 — cost & allocation briefing

State the cost model per lane (SSOT: `docs/model-routing.md` §
Cross-vendor lanes → "Lane cost models"), in plain terms:

- **grok** — the user's xAI account, operated on the free tier by design;
  exhausting quota mid-review fails open (the lane reports rate-limited and
  is skipped, never an upgrade prompt).
- **antigravity (gemini lane)** — the user's Google account quota (Antigravity
  free/AI Pro tiers), authenticated via the OS keyring.
- **codex** — the user's ChatGPT subscription quota (`codex exec`).
- **kiro-* (openai/zhipu/anthropic gateway lanes)** — `KIRO_API_KEY`,
  metered/paid per call. The preflight itself is a real, billable round trip
  (`adapters/kiro/README.md` § Cost of a preflight) — never free to check.

One paragraph on allocation, not a design: tier-aware task allocation across
vendors seats TOP-tier votes/advisors for review and gate work, treats codex
MID as the implementer lane, prefers subscription/free-quota lanes (grok,
antigravity, codex) for advisory volume, and reserves the metered kiro lanes
for gate votes where a paid round trip is worth it. Close this paragraph with:
cross-vendor task-allocation routing is a candidate follow-up design, not
built here — route it through `/spec` when it's taken up. Do not design that
routing in this skill.

## Step 3 — ask which absent lanes to onboard

From step 1's table, list every lane that is not fully healthy (missing cmd,
missing preflight, or unseeded config) and ask the user which of those to
onboard now — options with a sensible default (e.g. "onboard all absent
free/subscription lanes, skip kiro" as the default when kiro is among the
absent set, since it is the only metered one). A declined lane stays
reported absent in `/council-review`'s lane status line — this skill never
substitutes another vendor for a lane the user chose not to onboard.

## Step 4 — per-lane install → auth → verify

For each lane the user selected, in order:

**Install — run by the user, not by this session.** Hand the user the command
for their lane and let them run it (`!` prefix, or their own terminal). Do NOT
execute a vendor installer from this skill: `rules/public-repo.md` forbids
pulling dependencies without explicit approval, and a piped remote installer is
unpinned, unsigned code executing in a `$HOME` that already holds this user's
CLI credentials. Where a package manager is available, prefer it — it pins a
version and leaves an audit trail:

- codex: `npm install -g @openai/codex`, or `brew install --cask codex` on
  macOS. Shell installer (`curl -fsSL https://chatgpt.com/codex/install.sh | sh`)
  only if neither is available.
- grok: `npm i -g @xai-official/grok` (publisher `xai-security` /
  `security@x.ai`, verified on the npm registry 2026-08-20), or the shell
  installer `curl -fsSL https://x.ai/cli/install.sh | bash`.
- antigravity (agy): `curl -fsSL https://antigravity.google/cli/install.sh | bash`
  — no package-manager path published (`adapters/antigravity/README.md`).
- kiro: `curl -fsSL https://cli.kiro.dev/install | bash` (macOS/Linux) — no
  package-manager path published.

For the two shell-installer-only lanes, tell the user they can download and
read the script before running it (`curl -fsSL <url> -o install.sh`, inspect,
then `bash install.sh`) — say so rather than assuming they know.

**Auth — interactive, run by the user, not headless.** These are browser or
keyring flows this session cannot drive; instruct the user to run them
themselves via the `!` shell-passthrough prefix, then confirm before moving
on:

- codex: `! codex login` (check with `codex login status` — exit 0 means
  logged in, exit 1 prints "Not logged in").
- antigravity: `! agy` (one interactive session; credential lands in the OS
  keyring — `GEMINI_API_KEY` is deliberately not used, per
  `adapters/antigravity/README.md`).
- grok: `! grok` (first-launch browser OAuth; requires an eligible xAI
  subscription tier).
- kiro: the user exports `KIRO_API_KEY` themselves (issued at
  app.kiro.dev → API Keys, paid). **Never echo, log, or store this value** —
  instruct, don't collect. Name the safe channel explicitly, because the
  wiring/verify steps below need the key in the environment: it belongs in the
  user's shell profile or a secret manager, exported **before** this session
  started. Never inline it on a command this session runs
  (`KIRO_API_KEY=… kiro-preflight …` would write the secret into the
  transcript, the session JSONL under `~/.claude/projects/`, and shell
  history), and never into a repo `.env` — the harness never needs to receive
  the value, only its presence.

**Wire it into the harness**, after auth succeeds:

```bash
bash "$HR/setup.sh" --codex        # or --antigravity / --grok / --kiro
```

This lands the symlinks in `~/bin`, seeds the tiers/profile templates, and
runs `setup.sh`'s own post-install doctor pass.

**Verify — with an explicit heads-up before each real call.** Before running
any of the following, tell the user this is a real round-trip probe (billable
for kiro):

```bash
codex login status             # codex's own preflight: local check, no network call, not billable
antigravity-preflight          # real round trip, free-tier quota
grok-preflight                 # real round trip, free-tier quota
kiro-preflight kiro-openai     # real round trip — BILLABLE (rides the lane's cheapest tier)
```

A nonzero exit here means the lane stays absent — report the exit code and the
probe's **first stderr line**, not its raw output, and do not retry silently.
The auth-failure branch is exactly where a vendor CLI is most likely to echo
the offending key prefix or the account identity back at you, and this session's
output is durable (transcript, session JSONL, anything pasted into an issue).
If the first line is not enough to act on, tell the user to read the full
output themselves rather than reprinting it here.

**macOS-only sandbox note.** `grok-worker.sh` and `antigravity-worker.sh` use
`sandbox-exec` (macOS-only). On Linux they refuse unless
`GROK_WORKER_ALLOW_UNSANDBOXED=1` / `ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1` —
warn the user this is an explicit, unsandboxed opt-out (Linux sandboxing is
backlog, not solved here).

## Step 5 — final verification

```bash
bash "$HR/setup.sh" --doctor
```

Re-print step 1's status table (now reflecting the onboarding just done), and
close with a degrade summary in `/council-review`'s own terms:

- gemini/antigravity absent → council degrades toward a single-vendor
  (Claude-only) review with an honest first line, not silently.
- codex absent → the same degrade, from the other voting lane.
- grok absent → advisory-only impact; it was already opt-in
  (`--with-grok`), so nothing else changes.

## Boundaries

- Never flip `enabled` flags in `core/infra/backends.json` without asking —
  a disabled lane's `disabled_reason` is a deliberate decision, not a bug to
  silently reverse.
- Never store credentials. `KIRO_API_KEY` and any OAuth token are the user's
  to export/manage; this skill only tells them how.
- Every real round-trip probe (antigravity-preflight, grok-preflight,
  kiro-preflight, and any live dispatch) is announced before it runs, and
  kiro's is explicitly flagged as billable — no silent paid call.
- This skill does not design or implement cross-vendor task-allocation
  routing — that is future `/spec` work; step 2 briefs on it, nothing more.
