# Cross-runtime harness design

- Status: target architecture and implementation blueprint
- Verified: 2026-07-28
- Audience: maintainers adding runtimes, model providers, or evaluation sources

This document defines how one Agent workflow can run across Claude Code, Codex,
Antigravity, Gemini CLI, API-hosted models, and local models without pretending
that those products expose identical controls.

It is an implementation blueprint, not a claim that every target described here
already ships. The dated evidence and current support status live in the
[runtime capability matrix](benchmark/runtime-capability-matrix-2026-07.md).
The current canonical event wire format remains
[`hook-protocol.md`](hook-protocol.md).

## 1. Executive decisions

The portable unit is the **workflow contract**, not a plugin directory, prompt,
or model name.

Three independent axes must never be collapsed:

1. **Runtime host** — owns the agent loop, tool execution, permissions, sandbox,
   hooks, and session lifecycle. Examples: Claude Code, Codex, Antigravity CLI.
2. **Model backend** — generates or reviews content. Examples: Anthropic,
   OpenAI, Google, xAI, OpenRouter-routed, and local models.
3. **Evaluation evidence** — informs role-to-tier routing. Examples: Agent's
   evals, task-specific benchmarks, and Arena.

Changing a model does not install a runtime hook. A high Arena rank does not
prove that a model can enforce a file-write policy. An MCP server makes tools
portable, but the host still owns consent, sandboxing, and invocation policy.
The MCP architecture explicitly assigns those responsibilities to the host
([MCP architecture][mcp-architecture]).

Cross-runtime parity means:

- the same logical event reaches the same deterministic core policy;
- the same policy intent is enforced where the runtime exposes an equivalent
  boundary;
- unsupported behavior is reported and degraded according to an explicit rule;
- generated prose, plans, and code are not expected to be byte-identical.

## 2. System model

The design has five ownership layers. They are logical layers, not a requirement
that every host execute five separate processes.

| Layer | Owns | Must not own |
|---|---|---|
| 1. Mission contract | goal, scope, state, artifacts, completion criteria | vendor model IDs |
| 2. Runtime adapter | native events, tool names, decisions, packaging | project policy |
| 3. Policy core | deterministic gates and canonical decisions | runtime config |
| 4. Worker backend | external model invocation and captured result | local tool authority |
| 5. Evaluation evidence | routing recommendations and dated measurements | live enforcement |

The control flow is:

```text
evaluation evidence ──> role/tier policy ──> runtime or worker backend
                                              │
user goal ──> mission contract ──> agent loop │
                                   │          │
                                   ▼          ▼
                            runtime adapter / controlled gateway
                                   │ canonical event
                                   ▼
                              deterministic core
                                   │ allow / deny / ask
                                   ▼
                             effect boundary or user
```

Only the adapter or controlled gateway may translate runtime-native payloads.
Only the core decides project policy. A backend response is evidence or proposed
work; it receives no ambient authority merely because its model is capable.

## 3. Current baseline and target

The current repository already has:

- a five-event canonical hook contract;
- deterministic hooks under `core/hooks/`;
- Claude Code, Codex, and Gemini adapter implementations;
- synthetic cross-adapter decision tests;
- role-to-tier policy in [`model-routing.md`](model-routing.md);
- explicit external-worker dispatch, timeouts, captures, and cost approval;
- portable task state:
  `pending → in_progress → reviewing → completed`, with `blocked` as a side state;
- a separate durable goal lifecycle:
  `active | paused | budget_limited | complete | aborted`.

The two state vocabularies stay separate. Task state coordinates sessions. Goal
state controls a bounded multi-wave mission. An adapter must not invent a third
vendor-specific mission lifecycle.

The current limitations are equally important:

- the shipped Codex and Gemini enforcement paths are shell wrappers;
- those wrappers do not intercept every native file-write tool;
- the parity test proves translation through the same core hook, not native
  runtime registration, sandbox behavior, or complete tool coverage;
- the repository has a Claude plugin manifest, but no Codex or Antigravity
  package yet;
- Gemini is disabled as an external worker on the default individual-user path.

The target is to retain the core contract while replacing wrapper-only paths
with native hooks where they are available and adding honest capability
negotiation where they are not.

## 4. Portable workflow contract

### 4.1 Mission envelope

Every orchestrated mission must make these values durable outside the model
transcript:

```yaml
mission_id: stable slug or UUID
objective: one measurable outcome
non_goals: explicit exclusions
scope:
  repositories: []
  paths: []
  external_systems: []
task_state: pending | in_progress | blocked | reviewing | completed
goal_state: active | paused | budget_limited | complete | aborted
artifacts:
  restatement:
  plan:
  changes:
  verification:
  execution_record:
limits:
  token_budget:
  dispatch_budget:
  timeout_seconds:
completion:
  commands: []
  assertions: []
```

The existing supervise and verification workflows remain the behavioral source
for these fields. A runtime may display the state differently, but it must not
silently skip restatement, planning, independent verification, or the execution
record.

### 4.2 Canonical event boundary

Version 1 of the canonical hook protocol remains the only input accepted by
current core hooks. New adapters must:

1. receive a native runtime event;
2. normalize it to the current canonical event;
3. call one or more core hooks;
4. normalize the core result into a policy intent;
5. enforce that intent using a documented native mechanism;
6. record any loss of semantics or missing tool coverage.

Provider-specific fields may be retained under adapter-private metadata for
diagnostics. They must not become required core inputs unless the protocol is
versioned and all adapters migrate together.

### 4.3 Effect ownership

A hard gate is real only when every effect in its claimed coverage passes
through one of these boundaries:

- a native pre-tool or permission hook;
- an Agent-owned tool gateway;
- a sandbox or policy engine controlled by the host;
- a wrapper that is the only executable path to the effect.

Instructions, skills, and system prompts influence model behavior but do not
constitute a hard gate. Post-tool hooks can verify or redact results but cannot
undo an external side effect that already happened.

### 4.4 Tool naming

Adapters normalize only tool identity and the common input shapes required by
the core:

- shell command;
- file write or edit;
- MCP tool call;
- user prompt;
- lifecycle event.

They do not normalize every provider's MCP arguments. MCP tools remain
server-defined, and the host retains the permission boundary. MCP capability
negotiation is useful for portable discovery, but it is not a substitute for
the Agent runtime capability descriptor.

## 5. Runtime capability descriptor

XRH-01 will introduce one machine-readable descriptor per runtime. Until that
ships, the dated matrix is the human-readable registry.

```yaml
runtime_id: codex
distribution:
  kind: cli | desktop | ide | sdk | web
  package: product-specific identifier
  channel: stable | preview | enterprise | legacy
status: supported | partial | planned | backend-only | advisory
verified_at: YYYY-MM-DD
instructions:
  supported: true
  files: [AGENTS.md]
skills:
  supported: true
  layout: skills/<name>/SKILL.md
plugins:
  supported: true
  manifest: .codex-plugin/plugin.json
mcp:
  supported: true
  transports: [stdio, streamable-http]
hooks:
  events: [PreToolUse, PostToolUse]
  decision_modes: [allow, deny]
  tool_coverage: [shell, file-write, mcp]
permissions:
  approval_hook: true
  policy_engine: false
sandbox:
  supported: true
  modes: [read-only, workspace-write]
subagents:
  supported: true
headless:
  supported: true
authentication:
  paths: []
enforcement_tier: A
limitations: []
sources: []
```

Rules for the registry:

- `verified_at` and at least one primary source are required.
- `tool_coverage` is evidence-backed and never inferred from an event name.
- distribution channels with different authentication or hook behavior get
  separate descriptors.
- an unsupported field is `false` or an empty list, never omitted as if unknown
  meant supported.
- unknown current behavior sets `status: planned` or `partial` and records the
  uncertainty in `limitations`.

## 6. Enforcement tiers

Support is declared per distribution and per tool class.

| Tier | Meaning | Allowed claim |
|---|---|---|
| A | Native pre-effect event or native policy engine | hard enforcement for tested tools |
| B | Agent-controlled gateway or exclusive wrapper | hard enforcement for listed routes |
| C | Instructions, skills, or prompts only | advisory workflow compatibility |
| D | Model can only return text through a worker call | reviewer or advisor backend |

Tier B is not automatically runtime-wide. A shell wrapper that does not see
native file-write calls is Tier B for shell and Tier C for file writes.

Promotion rules:

1. C → B requires a controlled effect path and a bypass test.
2. B → A requires a native boundary and native end-to-end fixtures.
3. Any untested mutating tool stays at the lower tier.
4. Authentication availability affects `status`, not the semantic tier.
5. A runtime release that changes tool names or hook decisions triggers
   re-verification before the old tier is retained.

## 7. Decision normalization

The current canonical protocol uses `allow`, `deny`, and `ask`.
Observation-only events produce no decision. `observe` below is an adapter
outcome, not a new value in the version 1 hook JSON.

| Intent | Portable behavior |
|---|---|
| `allow` | core does not block; native permissions may still apply |
| `deny` | effect must not execute; reason is visible to model or user |
| `ask` | require an explicit user decision before the effect |
| `observe` | record context or evidence without changing execution |

Runtime mappings:

- **Claude Code** supports `allow`, `deny`, `ask`, and the runtime-specific
  `defer`. The portable core uses the first three; `defer` remains an adapter
  extension. Claude documents precedence as
  `deny > defer > ask > allow` ([Claude hooks][claude-hooks]).
- **Codex** supports native `allow` and `deny` for `PreToolUse`, but currently
  parses and rejects `permissionDecision: "ask"` while continuing the tool
  call. The adapter must never emit that unsupported result. A canonical `ask`
  becomes fail-closed `deny` unless a separately tested native permission flow
  owns that tool call ([Codex hooks][codex-hooks]).
- **Gemini CLI** supports `allow` and `deny` in `BeforeTool`; its policy engine
  can express static `ask_user` rules. A dynamic canonical `ask` becomes
  fail-closed `deny` unless a policy-backed prompt path is installed and tested
  ([Gemini hooks][gemini-hooks]).
- **Antigravity** supports `allow`, `deny`, `ask`, and `force_ask` directly on
  `PreToolUse` ([Antigravity hooks][antigravity-hooks]).
- **Wrappers and gateways** may treat `ask` as `deny` when they cannot interact
  with the user. They must explain how to retry with approval.

An adapter error on a mutating pre-effect event fails closed. An error on an
observation event records a warning and continues unless the mission's explicit
completion gate requires that observation.

## 8. Runtime distribution strategy

### 8.1 Claude Code

Use the existing Claude plugin as the reference implementation:

- `.claude-plugin/plugin.json` for identity;
- `hooks/hooks.json` for lifecycle enforcement;
- `skills/` and `agents/` for reusable workflows and specialists;
- a future root `.mcp.json` for bundled connections; the current plugin does
  not ship one;
- `CLAUDE.md` as the Claude-specific overlay while `AGENTS.md` remains the
  cross-runtime repository contract.

Claude's hook surface is broader than the portable five-event subset. New
Claude-only events may improve observability, but a core policy must not depend
on them until every other target has an explicit mapping or degradation rule.
The current install and event lifecycle is documented in
[`claude-plugin-install-lifecycle.md`](claude-plugin-install-lifecycle.md).

### 8.2 Codex

The target native package uses:

- `.codex-plugin/plugin.json`;
- `hooks/hooks.json`;
- `skills/`;
- optional `.mcp.json`;
- `AGENTS.md`;
- Codex sandbox and approval configuration.

Codex sets `PLUGIN_ROOT` and compatibility `CLAUDE_PLUGIN_ROOT` for plugin
hooks, so the existing relative hook commands can be migrated without copying
the core ([Codex plugin packaging][codex-plugin]).

The shell wrapper stays available as a compatibility path until native
end-to-end tests cover shell, `apply_patch`, and MCP tools. The native path
must not inherit the current wrapper's “ask means block” behavior without
documenting the difference to users.

### 8.3 Gemini CLI

Treat Gemini CLI as a separate enterprise/API distribution, not as an alias for
Antigravity:

- `gemini-extension.json` for the extension;
- `hooks/hooks.json` for native hooks;
- `skills/` for Agent Skills;
- `policies/` for policy-engine rules;
- `GEMINI.md` plus `AGENTS.md` for instructions;
- MCP configuration for shared tools.

Native `BeforeTool` and `AfterTool` replace the shell wrapper once parity and
bypass tests pass. The policy engine may provide stronger static approval
rules, but extension policies cannot silently grant unsafe permissions.

### 8.4 Antigravity

Build a dedicated plugin rather than renaming the Gemini adapter:

- `plugin.json`;
- `hooks.json`;
- `skills/`;
- `rules/`;
- `mcp_config.json`;
- workspace installation under `.agents/plugins/` or the documented global
  plugin location.

The adapter must translate camelCase Antigravity events such as
`toolCall.args` to the canonical input and translate decisions back to
`allow | deny | ask | force_ask`. Google provides a Gemini-extension import
path, but documents only partial migration parity; the Agent plugin remains an
explicit target, not an assumed automatic conversion
([Antigravity migration][antigravity-migration]).

### 8.5 API and local-model backends

An API or local inference server is a worker backend unless Agent itself owns
the complete loop and tool gateway.

Use the current dispatcher contract:

- role selects a backend and relative tier;
- caller gives per-invocation cost approval;
- preflight verifies the executable or endpoint;
- a timeout bounds the call;
- output is captured with mechanical status;
- fallback is explicit and recorded;
- model output never receives ambient filesystem or network authority.

Future API connections add authentication, rate-limit, and retry adapters
behind the same dispatcher result contract. They do not add provider SDK calls
to deterministic hooks.

### 8.6 Chat-only products

A web chat with no controlled tool boundary is Tier C or D:

- it may consume the mission packet and return advice;
- it may review a diff or completion claim;
- a human or controlled worker must transfer the result;
- it cannot be called a hard-enforcement runtime;
- it cannot be an unattended implementer with unverified side effects.

Arena is an evaluation service in this category, not an Agent runtime adapter.

## 9. Model routing and Arena

Arena is one input to model routing. It ranks model outputs from human
head-to-head preferences and publishes uncertainty, votes, task filters, price,
context, and license metadata. Rankings are live and methodology can change
([Arena Text leaderboard][arena-text], [Arena policy][arena-policy]).

Every routing decision should record:

```yaml
evaluated_at:
source:
task_class:
model_id:
provider:
rank:
rank_spread:
score:
votes:
price_input_per_million:
price_output_per_million:
context_tokens:
license:
availability:
agent_eval_result:
selected_role:
decision_reason:
```

Selection procedure:

1. Choose a task-specific Arena view where one exists; never use overall text
   rank as a universal coding or verification score.
2. Prefer stable entries with adequate votes and inspect rank spread rather
   than treating a one-place difference as meaningful.
3. Check official availability, authentication, context, price, and license.
4. Run Agent's own role-specific eval and failure-mode suite.
5. Map the model to LOW, MID, or TOP; keep the concrete model ID outside core
   hooks and backend-independent workflow policy.
6. Promote only the affected role. Do not replace every tier because one model
   leads one public category.
7. Refresh at each Agent minor release or quarterly, whichever comes first,
   and immediately after a provider retires a required access path.

Arena cannot answer:

- whether a CLI exposes pre-tool hooks;
- whether a sandbox covers a particular filesystem path;
- whether a model can authenticate on the current machine;
- whether a plugin installs on a given distribution channel;
- whether a provider-specific agent is safe to run unattended.

## 10. New-runtime onboarding algorithm

Use this order for every new platform:

1. **Classify it** as runtime host, model backend, evaluation source, or more
   than one with separate descriptors.
2. **Resolve distributions** so desktop, CLI, SDK, enterprise, and individual
   paths are not conflated.
3. **Inventory capabilities** from primary documentation and a versioned local
   probe.
4. **Locate the effect boundary** for shell, file writes, MCP, browser, network,
   and external mutations.
5. **Assign enforcement tiers** per tool class.
6. **Implement translation** without moving project policy into the adapter.
7. **Define every decision mapping**, especially unsupported `ask` behavior.
8. **Package instructions, skills, hooks, and MCP** in the host's native form.
9. **Add synthetic contract tests**, native event fixtures, and opt-in runtime
   end-to-end tests.
10. **Update the capability matrix** with version, date, limitations, and
    primary sources.
11. **Enable by default only after authentication and bypass tests pass**.

If step 4 cannot identify a controlled boundary, stop at Tier C or D.

## 11. Implementation backlog for Claude

### XRH-01 — Capability registry

Deliver:

- a JSON Schema for the descriptor in section 5;
- one descriptor per supported distribution;
- a validator that rejects missing dates, sources, tool coverage, and decision
  mappings;
- documentation generated or checked from the registry.

Acceptance:

- a deliberately incomplete descriptor fails CI;
- an unknown capability never defaults to supported;
- docs and registry contain the same enforcement tier and status.

### XRH-02 — Codex native path

Deliver:

- a Codex plugin manifest that reuses the shared skills and hook core;
- native hook translation for the portable event subset;
- explicit fail-closed handling for canonical `ask`;
- setup and doctor checks that distinguish native plugin and wrapper mode;
- compatibility migration for existing wrapper users.

Acceptance:

- native `PreToolUse` blocks a shell secret read;
- native `PreToolUse` blocks an `apply_patch` fixture;
- an MCP mutation fixture reaches the same core policy;
- canonical `ask` never becomes a Codex hook error followed by execution;
- disabling the plugin makes the doctor report enforcement unavailable.

### XRH-03 — Google distribution split

Deliver:

- a Gemini CLI extension for supported enterprise/API installations;
- a separate Antigravity plugin;
- native event translators for each wire format;
- authentication probes and distinct setup choices;
- a deprecation path for the shell wrapper after native coverage passes.

Acceptance:

- Gemini `BeforeTool` and Antigravity `PreToolUse` reach the same core hook;
- shell and file-write bypass fixtures are blocked in both native paths;
- Antigravity `ask` and `force_ask` are exercised;
- unsupported Gemini dynamic `ask` fails closed;
- an individual Gemini retirement error points to Antigravity without silently
  changing the user's backend.

### XRH-04 — Worker backend contract

Deliver:

- connection kinds for CLI, API, gateway, and local inference;
- shared preflight, timeout, capture status, and explicit fallback semantics;
- provider authentication kept outside model prompts and captures;
- role-tier mapping with no core-hook model IDs.

Acceptance:

- every connection kind passes the same success, failure, timeout, unavailable,
  and fallback fixtures;
- no paid call runs without the existing explicit approval gate;
- backend output cannot execute a local tool outside a runtime-owned boundary.

### XRH-05 — Parity and degradation tests

Deliver four separate test layers:

1. core policy unit tests;
2. adapter translation fixtures;
3. native registration and tool-coverage end-to-end tests;
4. mission-level completion and evidence tests.

Acceptance:

- reports distinguish “same core decision” from “native effect blocked”;
- each matrix cell links to a test or is marked unverified;
- unsupported observation events warn without creating false hard-parity claims;
- unsupported mutating events block enablement or fail closed.

### XRH-06 — Evidence-based routing

Deliver:

- a dated routing-evidence record using section 9;
- role-specific local evals before promotion;
- a refresh report at each minor release or quarterly;
- routing changes limited to the evaluated role and tier.

Acceptance:

- a rank without votes, uncertainty, availability, and local eval cannot promote
  a model;
- historical snapshots remain reproducible;
- live Arena changes do not alter runtime enforcement or core policy.

## 12. Verification and rollout

Documentation phase:

- run the repository documentation reality gate;
- run the sanitize and supply-chain scans;
- check Markdown links and fenced blocks;
- compare every current-product claim with the dated capability matrix;
- verify that no future feature is described as shipped.

Implementation rollout:

1. report-only capability discovery;
2. native hooks installed but shadowing decisions;
3. deny enforcement on a bounded tool allowlist;
4. ask and permission behavior after interactive fixtures pass;
5. full supported-tool coverage;
6. wrapper retirement only after a measured no-regression window.

Rollback is per runtime distribution. A failed native path reverts to the last
tested wrapper for its covered tools or disables mutation; it never silently
falls back to advisory instructions.

## 13. Claude cold-read handoff

Give Claude this document, the dated matrix, and the current
[`hook protocol`](hook-protocol.md). Before editing, Claude must answer:

1. Is the target a runtime, backend, evidence source, or multiple descriptors?
2. Which exact effect boundaries and tool classes are controlled?
3. What happens to each canonical decision?
4. Which claims are current and which belong to XRH-* target work?
5. Which tests prove translation, native enforcement, and mission completion?

Claude should start at the first incomplete XRH item, preserve the layer
boundaries above, and refuse to label synthetic parity as native enforcement.

[antigravity-hooks]: https://www.antigravity.google/docs/hooks
[antigravity-migration]: https://www.antigravity.google/docs/cli/gcli-migration
[arena-policy]: https://arena.ai/blog/policy
[arena-text]: https://arena.ai/leaderboard/text
[claude-hooks]: https://code.claude.com/docs/en/hooks
[codex-hooks]: https://learn.chatgpt.com/docs/hooks
[codex-plugin]: https://developers.openai.com/plugins/build/plugins
[gemini-hooks]: https://geminicli.com/docs/hooks/reference/
[mcp-architecture]: https://modelcontextprotocol.io/specification/2025-06-18/architecture
