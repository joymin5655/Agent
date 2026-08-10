# Kiro adapter — gateway lanes for cross-vendor second opinions

Kiro CLI is not a vendor. It is a **gateway**: one CLI that reaches Anthropic,
OpenAI, Zhipu, DeepSeek, MiniMax and Alibaba models behind a single credential.
That is why `core/infra/backends.json` registers it as several backends
(`kiro-openai`, `kiro-zhipu`, `kiro-anthropic`) rather than one, each carrying
the `vendor` it actually reaches plus `"gateway": "kiro"`.

**Why the split matters.** A second opinion is only worth dispatching when its
vendor differs from the session asking for it. A Claude session that routes
`second-opinion-review` to `kiro-anthropic` gets a fluent restatement of its own
priors, not an independent check. Keeping `vendor` honest makes that visible in
the registry instead of hiding it behind one `"vendor": "aws"` label.

## Tier ladder

Tiers come from Kiro's own published `rate_multiplier` (`kiro-cli chat
--list-models -f json`), not from guesswork:

| Lane | TOP | MID | LOW |
|---|---|---|---|
| `kiro-openai` | `gpt-5.6-sol` (2.4x) | `gpt-5.6-terra` (1.2x) | `gpt-5.6-luna` (0.6x) |
| `kiro-anthropic` | `claude-opus-5` (2.2x) | — | — |
| `kiro-zhipu` | — | `glm-5` (0.5x) | — |

## Model names live here, never in the registry

`backends.json` forbids model IDs — `core/tests/backends-schema-test.sh` enforces
it (`no-model-ids`). Each profile in this directory pins its own model, exactly
as `adapters/codex/{quick,deep}.config.toml.template` does. `tier_args` therefore
carries `--agent <profile>`, never `--model <id>`.

## Read-only by construction

Every profile ships `"tools": ["read"]` **and** `"allowedTools": ["read"]`, and
`core/tests/backends-schema-test.sh` asserts that on the shipped templates: each
one must be valid JSON, pin a `model`, and carry only allowlisted read-only tool
entries under *both* field names (an unrecognized capability fails — a denylist
would have to be updated every time the CLI grows a new write verb). Before that
check existed, flipping every template to `["read","shell","write"]` left the whole
battery green.

This is the real isolation boundary, and it is stronger than the CLI's own flags:

- `--trust-tools=` (documented as "trust no tools") is **ignored** — the CLI warns
  `needs to be prepended with @{MCPSERVERNAME}/` and applies default trust.
- Headless mode denies `fs_write` on its own ("non-interactive mode (no user to
  approve)"), but **`-a` / `--trust-all-tools` lifts that**.
- A profile's tool list overrides even `-a`. Verified 2026-07-30: dispatching with
  `-a --agent kiro-openai-low` and asking for a file write returns *"I can't create
  or modify files in this read-only environment"* and writes nothing.

So these lanes carry `second-opinion-review`, `second-opinion-verify` and
`advisor`. They must never carry `implementer` — a read-only worker cannot
implement, and loosening a profile to allow writes would silently remove the only
enforcement layer that survives `-a`.

The guarantee holds for the profile that actually gets loaded — see
[The workspace-shadowing hazard](#the-workspace-shadowing-hazard) for the one way
a different profile can be substituted, and what the preflight does about it.

## Installation

Profiles are discovered from `~/.kiro/agents/{name}.json` (global) or
`.kiro/agents/{name}.json` (project-local, takes precedence). Install the global
copies and the preflight probe:

```bash
mkdir -p ~/.kiro/agents ~/bin
for f in adapters/kiro/*.json.template; do
    cp "$f" ~/.kiro/agents/"$(basename "$f" .json.template)".json
done
ln -sf "$PWD/adapters/kiro/kiro-preflight.sh" ~/bin/kiro-preflight
chmod +x adapters/kiro/kiro-preflight.sh
```

The probe resolves its argv from `core/infra/backends.json` with `jq`, and follows
the symlink to find that registry — so `jq` must be installed (`call-worker.sh`
already requires it). Without `jq` the probe refuses (exit 7) rather than guessing
a binary or a profile name. `bash setup.sh --doctor` reports the whole lane: gateway
CLI on PATH, one profile file per `--agent` in the registry, and a resolvable
preflight probe.

## Authentication, and why `kiro-preflight` exists

`KIRO_API_KEY` (Pro-tier, issued at app.kiro.dev -> API Keys, shown once) is what
bootstraps headless auth — browser login does not reach a non-interactive worker.
But **the env var is not a usable health signal**, for two measured reasons.

**1. No subcommand reports auth failure through its exit code.** On 2.15.2, with
no key, a bogus key, and a valid key, all three exit 0:

```
kiro-cli --version            -> 0 / 0 / 0
kiro-cli chat --list-models   -> 0 / 0 / 0
kiro-cli agent list           -> 0 / 0 / 0   (prints "not logged in", still exits 0)
```

`agent list` is worse than merely quiet: with a bogus key it prints the workspace
and global agent directories and nothing else. It is a **local directory
enumeration**, not a server round trip, so it cannot validate a credential at all.

**2. The credential is cached, so the env var stops mattering.** After the first
successful dispatch the CLI stores a derived session token in the macOS Keychain
under service `kirocli:social:token`. From then on a *bogus* `KIRO_API_KEY` — or
none at all — still authenticates and still bills credits. Observed here: the key
was stored at 08:25:03Z, the token appeared at 08:55:42Z after the first
successful run, and every later call succeeded regardless of the env var.

So the only honest probe is a real inference round trip. `kiro-preflight.sh` makes
one and demands **positive proof** that it happened: the prompt asks for one exact
token back (`KIRO-PREFLIGHT-OK-4f7c1a`) and a reply that does not contain that
token is a refusal. Checking "output is nonempty" was not enough — a CLI printing
`Error: insufficient credits` and exiting 0 satisfied it. Auth-failure text is
checked *before* the status (because of reason 1), and the probe refuses on any
nonzero exit, any timeout, any missing token, any mktemp failure, and any registry
shape it cannot reproduce. It is fail-closed everywhere: an unknown state is a
refusal. `core/tests/kiro-preflight-test.sh` pins each of those paths with stubbed
CLIs and makes zero paid calls.

### The probe runs the argv the dispatch will run

The probe composes its command line from `core/infra/backends.json` — the same
file, the same lane, the same lookups `call-worker.sh` uses:

| Piece | Where it comes from |
|---|---|
| binary + subcommand | the lane's `cmd` (`cmd[0]` is the binary — so the probe can never validate a *different* executable than the dispatch) |
| profile resolution | the lane's `tier_args`, preferring the **LOW** tier's `--agent <profile>`, then MID, then TOP |
| model (fallback only) | `KIRO_PREFLIGHT_MODEL` — used only when the lane pins no profile at all |

`call-worker.sh` passes the lane it is about to dispatch (`AGENT_PREFLIGHT_LANE`)
and the registry path (`AGENT_BACKENDS_FILE`); run by hand, `kiro-preflight <lane>`
takes the lane as an argument and defaults to `kiro-openai`.

Why this matters: a probe that used a bare `--model` never touched `--agent`
resolution at all, so every profile could be missing, malformed or shadowed while
the probe reported health. Probing through `--agent` means a broken profile is
caught *before* the paid dispatch, not by it. There is deliberately **no**
`KIRO_CLI_BIN`-style override: an env var that repoints the probe is exactly the
lie the probe exists to prevent (tests put a stub named after the registry's own
`cmd[0]` on PATH instead).

Exit codes: `0` healthy · `1` gateway CLI missing · `2` workspace shadow present ·
`3` auth rejected · `4` timed out · `5` any other failure, including a reply with
no success token · `6` internal (mktemp) failure · `7` registry/lane unusable
(no `jq`, no registry, unknown lane, non-array `cmd`, non-object `tier_args`).

### Cost of a preflight

The probe is a **real, billable call** — that is the point, and it is the price of
not paying for a dispatch that was doomed. Two consequences worth knowing:

- It rides the lane's **cheapest declared profile** (LOW where the lane has one:
  `kiro-openai` probes at `gpt-5.6-luna`, 0.6x). A lane with only a TOP profile
  probes at TOP — `kiro-anthropic` bills its preflight at 2.2x. If that matters,
  give the lane a LOW-tier profile; the probe will prefer it automatically.
- The prompt is one line and the requested reply is one token, so the call is
  minimal, but it is one call per dispatch *attempt* (including attempts that
  then fall back to another backend).
- `call-worker.sh` allows a gateway probe 60s by default (a round trip, not a
  `--version`); override with `AGENT_WORKER_PREFLIGHT_TIMEOUT_S`.

**When the subscription lapses**, expect the cached token to keep working until it
expires, then the lane goes dark — preflight refuses and `call-worker.sh` maps it
to unavailable (125 -> 127). If the lapse is permanent, set `"enabled": false`
with a `disabled_reason` rather than leaving a lane that always fails preflight.

## The workspace-shadowing hazard

`--agent <name>` resolves `./.kiro/agents/<name>.json` **before**
`~/.kiro/agents/<name>.json`, and `call-worker.sh` inherits its caller's working
directory. A repository can therefore ship
`.kiro/agents/kiro-openai-top.json` with `"tools": ["shell","write"]` and silently
replace the read-only profile this framework installed — different tools, and a
different model, while the registry still reads as a pinned read-only lane.

This is not theoretical. Measured 2026-07-30: with a crafted workspace profile the
CLI logged `Agent conflict for kiro-openai-low. Using workspace version.` and the
dispatch then created a file under `--trust-all-tools`. Standing in an untrusted
checkout while dispatching a second opinion hands that checkout write and shell.

`kiro-preflight.sh` refuses (exit 2) whenever `./.kiro/agents/kiro-*.json` exists,
deliberately over-broadly — it cannot know which profile the pending dispatch will
name. That scan is **defense in depth, not the control**: a scan happens before the
dispatch, so anything that plants the shadow *after* the scan wins the race.

The control is in the dispatcher. `core/infra/call-worker.sh` runs every backend
carrying a `"gateway"` field from a **neutral working directory** — a fresh
`mktemp -d` owned by that process, removed when it exits — instead of the caller's
cwd. No repository is on the profile resolution path at all, so there is nothing to
plant and no window to plant it in. Non-gateway backends still inherit the caller's
cwd (codex needs it: it reads the repo it is reviewing). Proven by
`core/tests/call-worker-test.sh`: a gateway dispatch does not run in the caller's
cwd, a non-gateway dispatch still does, and a `./.kiro/agents/kiro-*.json` planted
in the caller's cwd is not visible to the gateway dispatch. The preflight probe runs
in that same neutral directory, so its scan reflects the cwd the dispatch will
actually resolve from.

## Known limitations

- MCP is unavailable under API-key auth (`Failed to retrieve MCP settings`).
  Irrelevant for read-only second opinions; blocking if you ever want MCP tools.
- Long runs can hit a transient `Authentication failed` mid-session even with a
  valid key (observed once on a ~30-minute dispatch). `timeout_s` is set to 420
  to keep individual dispatches well inside that window.
- Output is heavily ANSI-decorated, including spinner frames. Strip with
  `sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'` before parsing a capture.
