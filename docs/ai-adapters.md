# AI runtime adapters

Use this guide when adding or changing a runtime host. Read the
[cross-runtime design](cross-runtime-harness-design.md) first, then use the
[dated capability matrix](benchmark/runtime-capability-matrix-2026-07.md) for
current vendor facts.

The canonical event and decision wire format remains
[`hook-protocol.md`](hook-protocol.md).

## What an adapter is

An adapter connects a runtime host to the deterministic core:

```text
runtime-native event
  -> adapter translation
  -> canonical event
  -> core hook
  -> canonical policy intent
  -> native decision or explicit degradation
```

The adapter owns:

- native event and tool names;
- native registration and packaging;
- input/output translation;
- decision mapping;
- tool-coverage reporting;
- runtime-specific installation and health probes.

The adapter does not own:

- project risk policy;
- model selection;
- mission completion criteria;
- provider credentials;
- application-specific paths or rules.

A model API is normally a worker backend, not a runtime adapter. Arena is an
evaluation source, not either one.

## Current repository state

| Runtime | Shipped Agent path | Honest support |
|---|---|---|
| Claude Code | native plugin hooks | Tier A for configured tools |
| Codex | native hooks (fixtures + live `codex exec` e2e, 2026-09-27) | Tier A for Bash, `apply_patch`, MCP |
| Gemini CLI | exclusive shell wrapper | Tier B shell; Tier C uncovered writes |
| Antigravity | native hooks via a plugin folder (agy 1.2.12; fixtures + workspace-plugin probe, global folder unmeasured) | Tier A for configured tools; see `adapters/antigravity/README.md` |

The current parity test feeds logically identical synthetic events through the
four shipped adapters (Antigravity's vocabulary is compared after normalization) and
compares their core decisions. It does not launch each vendor runtime or prove that
every native tool is intercepted.

## Canonical adapter contract

Each adapter must:

1. accept a native event or a synthetic fixture;
2. construct the version 1 canonical JSON from `hook-protocol.md`;
3. preserve tool inputs used by the core;
4. invoke the requested core hook;
5. parse empty output as observation/pass-through;
6. translate `allow`, `deny`, and `ask` deliberately;
7. fail closed for unsupported mutating decisions;
8. emit no false success when registration or tool coverage is absent.

Provider-specific event fields may be retained for diagnostics. Do not make
them mandatory core inputs without a protocol version change and lockstep
adapter migration.

## Claude Code

### Current path

Claude Code's native hook JSON is closest to the canonical contract, so
`adapters/claude-code/adapter.sh` is a thin dispatcher.

The repository's Claude plugin contains:

- `.claude-plugin/plugin.json`;
- `hooks/hooks.json`;
- shared skills and agents;
- the Claude adapter and core hooks.

`hooks/hooks.json` registers session, prompt, pre-tool, post-tool, and stop
events. Project-specific behavior still comes from `hook-config.yml`.

### Decision mapping

Claude natively supports:

- `allow`;
- `deny`;
- `ask`;
- runtime-specific `defer`.

The portable core uses the first three. `defer` is useful in non-interactive
Claude integrations but is not part of the current canonical protocol.

### Coverage rule

Claude is the reference adapter, not proof that every Claude tool is covered.
Any new mutating built-in, MCP matcher, or hook event must receive an explicit
coverage decision and fixture.

See `adapters/claude-code/README.md` for current registration.

## Codex

### Current path

The shipped Codex adapter uses Codex's native hook path (XRH-02, delivered):

- config lives in `~/.codex/hooks.json` (merged by `setup.sh --codex`) or a
  plugin's `hooks/codex-hooks.json`, or a trusted project's `.codex/`;
- `adapter.py`'s native mode reads the Claude-shaped stdin Codex sends
  (`hook_event_name`, `tool_name`, `tool_input`, `tool_use_id`, `session_id`,
  `cwd`, `transcript_path`) and runs the requested core hook per event;
- `apply_patch` carries the patch text in `tool_input.command`; the adapter
  splits it into one canonical `Write`/`Edit` event per file (absolute paths
  from `cwd`) and aggregates deny > ask > advisory > allow across files;
- `PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
  and `Stop` are wired for the `Bash`, `apply_patch`, and `mcp__*` matchers;
- Codex only runs a hook after the user reviews and trusts it with `/hooks`
  (trust is tracked per hook hash; a changed hook needs re-review), and
  project-local `.codex/` hooks load only in a trusted project.

The compatibility shell wrapper (`legacy/codex-shell-wrap/codex-shell-wrap.sh`)
is retired to `legacy/` and is a fallback only for `[features] hooks = false`
builds — see `legacy/codex-shell-wrap/README.md`.

Verified end-to-end for Bash and `apply_patch` in one live `codex exec` session
(codex-cli 0.157.0, 2026-09-27); MCP tool calls are fixture-tested only. Not yet
done: `setup.sh --doctor` detecting the plugin install path (it checks the
`setup.sh --codex` merge target only).

### Decision mapping

Codex supports native `allow` and `deny` from `PreToolUse`.
`permissionDecision: "ask"` is parsed but unsupported: Codex marks the hook
failed and continues the tool call. The same fail-open behavior applies to any
hook failure — non-zero exit (other than 2), timeout, or invalid JSON.

The native adapter (`adapters/codex/adapter.py`, `run_native`) now does this
translation itself, so canonical `ask` never reaches Codex unchanged:

1. a core hook's `ask` decision, a non-zero exit, a timeout, or unparseable
   output all become an explicit `deny` JSON on stdout (exit 0) — fail-closed,
   because Codex would otherwise run the tool unchecked;
2. the deny reason for `ask` tells the agent to get the user's explicit
   approval and retry.

Non-`PreToolUse` events stay fail-open by design: an adapter or hook error
there is warned on stderr and the event is dropped rather than blocking an
observation-only hook.

See `adapters/codex/README.md` for the shipped adapter and the
[official Codex hook reference](https://learn.chatgpt.com/docs/hooks) for the
native contract.

## Gemini CLI

### Distribution boundary

Gemini CLI for enterprise, Google Cloud, and paid API-key use remains distinct
from Antigravity. Individual Google AI Pro, Ultra, and free-tier CLI access
moved to Antigravity in June 2026.

Do not label an enterprise/API capability as available to an unauthenticated
individual installation.

### Current path

The shipped Gemini adapter is also a compatibility wrapper:

- `gemini-shell-wrap.sh` intercepts the configured shell route;
- the translator constructs canonical events;
- core `deny` and `ask` both block at the wrapper;
- a session wrapper simulates lifecycle events;
- native file-write and replacement tools are not covered.

The external Gemini worker is disabled by default until a working credential
path is verified on the machine. Since 2026-08-19 the worker contract itself
ships ready: `gemini-worker.sh` (tier bridge, OS-sandboxed dispatch) and
`gemini-preflight.sh` (fail-closed exact-token probe). The registry's
`disabled_reason` names the re-enable condition — a fresh login after which
`gemini-preflight` exits 0.

### Upstream native path

Current Gemini CLI extensions can bundle:

- `gemini-extension.json`;
- `hooks/hooks.json`;
- Agent Skills;
- MCP servers;
- subagents;
- policy-engine rules.

Native `BeforeTool` and `AfterTool` events remove the need for a shell-only
bridge. XRH-03 creates that extension for supported distributions.

### Decision mapping

Gemini hooks document dynamic `allow` and `deny`. The policy engine separately
supports static `ask_user` rules. Until an interactive policy-backed mapping is
installed and tested, canonical dynamic `ask` fails closed as `deny`.

See `adapters/gemini/README.md` for shipped wrapper behavior and the
[Gemini hook reference](https://geminicli.com/docs/hooks/reference/) for the
native target.

## Antigravity

Antigravity is a separate adapter, not a rename of Gemini CLI. The shipped adapter
(`adapters/antigravity/adapter.sh`, installed as a plugin folder by
`setup.sh --antigravity`) is documented in `adapters/antigravity/README.md`.

The native package uses:

- `plugin.json`;
- `hooks.json`;
- `skills/`;
- `rules/`;
- `mcp_config.json`.

Its documented `PreToolUse` contract uses camelCase input and supports
`allow`, `deny`, `ask`, and `force_ask`. The adapter translates
`toolCall.name` and `toolCall.args` to the canonical tool event, and emits `deny`, `ask`
(pass-through) and `force_ask` (a core-hook `ask`); it never emits `allow`.

Antigravity has no exact documented equivalent for every portable lifecycle
event. Missing events stay explicit in the capability registry instead of being
silently mapped to a nearby invocation event.

See the
[official Antigravity hook reference](https://www.antigravity.google/docs/hooks).

## Decision degradation policy

This table is the **target contract** (XRH-02/03 acceptance criteria), not a
description of shipped behavior. The shipped adapters currently fail **open**
on a crashed or empty-output hook: the Codex/Gemini shell wraps discard a
failed hook's output and execute the command, and the Claude adapter passes
silently when a named core hook is missing (`hook-protocol.md` § 4, exit
code 1). Until the native paths land, rule 5 above ("empty output =
pass-through") is what actually happens on error.

| Condition | Mutating pre-effect event | Observation event |
|---|---|---|
| native equivalent exists | translate and enforce | translate and record |
| `ask` unsupported | native prompt if proven, else deny | not applicable |
| event absent | adapter cannot claim coverage | warn and mark unsupported |
| malformed core decision | deny and report adapter error | warn and continue |
| hook timeout | deny for covered mutation | record timeout |
| registration missing | disable mutation or report unavailable | report degraded |

An instruction file is never a fallback for a missing hard gate.

## Four levels of parity

Keep these claims separate:

1. **Core parity** — the same canonical event produces the same deterministic
   core decision.
2. **Translation parity** — native fixtures normalize to the intended canonical
   event and back.
3. **Enforcement parity** — a real runtime tool is blocked before its effect.
4. **Mission parity** — the same mission produces required artifacts and passes
   independent verification.

`core/tests/adapter-parity.sh` currently proves level 1 through the shipped
adapter translators for its fixtures. It does not prove levels 3 or 4.

## Adding a new runtime

### 1. Classify before coding

Decide whether the target is:

- a runtime host;
- a model backend;
- an evaluation source;
- several distributions that need separate descriptors.

If it exposes no controlled effect boundary, stop at advisory or backend-only
support.

### 2. Create a capability descriptor

Record:

- distribution and channel;
- instructions and skills;
- plugin manifest;
- MCP support and transports;
- native events and decision modes;
- exact tool coverage;
- permissions and sandbox;
- subagents and headless mode;
- authentication paths;
- enforcement tier;
- limitations, verification date, and primary sources.

Use the schema in section 5 of
[`cross-runtime-harness-design.md`](cross-runtime-harness-design.md).

### 3. Implement the translator

Create `adapters/<ai-name>/` with:

```text
adapter.sh or adapter.py
native registration or package template
runtime instruction overlay
README.md
tests/run.sh
fixtures/
```

The adapter may call several core hooks, but it must not copy their policy.

### 4. Define all decisions

For each canonical intent, document:

- native output shape;
- exit-code behavior;
- precedence with native permissions;
- interactive and headless behavior;
- fallback when unsupported.

An undefined `ask` mapping blocks release.

### 5. Test all four levels

Minimum tests:

- safe shell event;
- blocked shell secret read;
- blocked native file write;
- blocked MCP mutation;
- canonical `ask`;
- hook error and timeout;
- disabled or missing registration;
- session start and stop where supported;
- one mission with completion evidence.

Native end-to-end tests may be opt-in when they require credentials, but the
capability matrix must remain `partial` until they pass.

### 6. Wire installation and health

Update:

- setup for explicit distribution selection;
- doctor output for package, hook trust, auth, and tool coverage;
- docs index and capability matrix;
- uninstall or rollback instructions;
- version and re-verification date.

Do not enable a paid backend, retired auth path, or untested native mutation by
default.

## Release bar

A runtime can be called “supported” only when:

- its descriptor validates;
- primary sources and a local version are recorded;
- every mutating tool in the claimed coverage has a bypass fixture;
- `deny` is proven before effect;
- `ask` is either proven interactive or fails closed;
- install, doctor, and rollback paths are tested;
- synthetic and native test results are reported separately;
- the dated capability matrix is updated.

Graceful degradation is acceptable for observation. Silent degradation is not
acceptable for mutation.
