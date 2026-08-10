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
| Codex | exclusive shell wrapper | Tier B shell; Tier C uncovered writes |
| Gemini CLI | exclusive shell wrapper | Tier B shell; Tier C uncovered writes |
| Antigravity | none | planned |

The current parity test feeds logically identical synthetic events through the
three shipped adapters and compares their core decision JSON. It does not launch
each vendor runtime or prove that every native tool is intercepted.

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

The shipped Codex adapter is a compatibility wrapper:

- `codex-shell-wrap.sh` intercepts the configured shell path;
- the translator constructs a canonical `PreToolUse` event;
- core `deny` and `ask` both block at the wrapper;
- a session wrapper simulates lifecycle events;
- native file-write tools are not covered.

This is shell-route enforcement, not runtime-wide enforcement.

### Upstream native path

Current Codex supports:

- `.codex-plugin/plugin.json`;
- plugin `hooks/hooks.json`;
- skills and MCP servers;
- native lifecycle hooks;
- native Bash, `apply_patch`, MCP, and local-function hook coverage;
- sandbox and permission configuration.

XRH-02 in the
[cross-runtime design](cross-runtime-harness-design.md#xrh-02--codex-native-path)
migrates Agent to that path. The wrapper remains until native end-to-end tests
prove equivalent or stronger coverage.

### Decision mapping

Codex currently supports `allow` and `deny` from `PreToolUse`.
`permissionDecision: "ask"` is parsed but unsupported: the hook fails and the
tool call continues.

Therefore the native Codex adapter (XRH-02 target — the shipped `adapter.sh`
stdin path does no such translation today; only `codex-shell-wrap.sh`'s own
Mode-1 logic maps ask to block) must never pass canonical `ask` through
unchanged:

1. use a separately proven native permission flow when one already owns the
   tool call; otherwise
2. return fail-closed `deny` with a reason explaining how to retry after user
   approval.

See `adapters/codex/README.md` for shipped wrapper behavior and the
[official Codex hook reference](https://learn.chatgpt.com/docs/hooks) for the
native target.

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
path is verified on the machine.

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

Antigravity is a new adapter target, not a rename of Gemini CLI.

The native package uses:

- `plugin.json`;
- `hooks.json`;
- `skills/`;
- `rules/`;
- `mcp_config.json`.

Its documented `PreToolUse` contract uses camelCase input and supports
`allow`, `deny`, `ask`, and `force_ask`. The adapter must translate
`toolCall.name` and `toolCall.args` to the canonical tool event.

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
