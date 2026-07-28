# Runtime capability matrix — 2026-07

- Snapshot date: 2026-07-28
- Scope: runtime enforcement, packaging, model backends, and routing evidence
- Companion design:
[`cross-runtime-harness-design.md`](../cross-runtime-harness-design.md)

This is a dated evidence document. Product behavior, authentication, and model
rankings change. The evergreen design consumes these facts but does not copy
volatile ranks or versions into its core contracts.

## Method

Sources are first-party product documentation, first-party repositories, and
local version probes. “Supported” means the vendor documents a capability for
the named distribution. “Agent current” means this repository actually wires
that capability today.

The matrix separates:

- upstream capability from Agent integration;
- runtime host from model backend;
- native enforcement from wrapper coverage;
- individual, enterprise, API, and migration channels;
- synthetic parity from native end-to-end enforcement.

Local probes on the snapshot date:

```text
Claude Code: 2.1.220
Codex CLI:   0.145.0
Gemini CLI:  0.46.0
Antigravity: not installed
```

The absence of a local Antigravity binary means its row is documentation-backed,
not locally exercised.

## Summary

| Distribution | Upstream tier | Agent current | Target |
|---|---|---|---|
| Claude Code | A | A for registered tools | reference implementation |
| Codex | A | B shell; C uncovered writes | XRH-02 native plugin |
| Gemini CLI enterprise/API | A | B shell; C uncovered writes | XRH-03 extension |
| Antigravity CLI/IDE | A | planned | XRH-03 plugin |
| API or local model only | D by default | D worker backend | XRH-04 |
| Chat-only product | C or D | manual only | reviewer/advisor |
| Arena | evidence source | manual snapshot | XRH-06 |

Tier meanings are defined in the
[cross-runtime design](../cross-runtime-harness-design.md#6-enforcement-tiers).
An A in “Upstream tier” does not mean Agent has implemented that native path.

## Canonical event coverage

The mappings below are based on documented events, not names guessed from
similar products.

| Canonical event | Claude | Codex | Gemini CLI | Antigravity |
|---|---|---|---|---|
| `PreToolUse` | `PreToolUse` | `PreToolUse` | `BeforeTool` | `PreToolUse` |
| `PostToolUse` | `PostToolUse` | `PostToolUse` | `AfterTool` | `PostToolUse` |
| `SessionStart` | native | native | native | no exact documented event |
| `Stop` | `Stop` | `Stop` | `AfterAgent` | `Stop` |
| `UserPromptSubmit` | native | native | `BeforeAgent` | no exact documented event |

“No exact documented event” is not mapped to a nearby event automatically.
Antigravity `PreInvocation` happens before a model invocation but does not
document the same user-prompt contract. Any synthetic mapping must be labeled
partial and tested for the specific workflow.

## Decision coverage

| Runtime event | Allow | Deny | Ask | Runtime extension |
|---|---:|---:|---:|---|
| Claude `PreToolUse` | yes | yes | yes | `defer` |
| Codex `PreToolUse` | yes | yes | no | input rewrite |
| Gemini `BeforeTool` | yes | yes | no dynamic ask | policy `ask_user` |
| Antigravity `PreToolUse` | yes | yes | yes | `force_ask` |

Important differences:

- Claude evaluates multiple decisions with
  `deny > defer > ask > allow` precedence ([Claude hooks][claude-hooks]).
- Codex currently parses but does not support `permissionDecision: "ask"` for
  `PreToolUse`; it reports a hook failure and continues the tool call. Agent
  must map a portable `ask` to a tested permission path or fail-closed `deny`
  ([Codex hooks][codex-hooks]).
- Gemini hook decisions document `allow` and `deny`. Its policy engine can
  define static `ask_user` rules, which is not the same as returning a dynamic
  ask from a hook ([Gemini hooks][gemini-hooks],
  [Gemini extensions][gemini-extensions]).
- Antigravity directly documents `ask` and `force_ask`
  ([Antigravity hooks][antigravity-hooks]).

## Claude Code

### Upstream capability

- **Instructions:** `CLAUDE.md` and project rules.
- **Skills:** `skills/<name>/SKILL.md`.
- **Packaging:** optional `.claude-plugin/plugin.json` plus root-level
  skills, agents, hooks, MCP, LSP, monitors, executables, and settings.
- **Hooks:** broad lifecycle coverage including session, prompt, tool,
  permission, subagent, task, compaction, and stop events.
- **Handlers:** command, HTTP, MCP tool, prompt, and experimental agent hooks.
- **Decisions:** `allow`, `deny`, `ask`, and non-interactive `defer`.
- **MCP:** native client and plugin-bundled server support.
- **Subagents:** native and plugin-defined.
- **Headless:** supported through non-interactive CLI mode.
- **Enforcement:** native pre-effect hooks give Tier A coverage for registered
  and tested tools.

Primary sources:
[plugin structure][claude-plugins] and [hook reference][claude-hooks].

### Agent current

- `.claude-plugin/plugin.json` exists.
- `hooks/hooks.json` registers the current canonical core through the thin
  Claude adapter.
- shell, file-write, and selected MCP tools have explicit matchers.
- the current adapter is closest to the canonical wire format.

### Gaps and cautions

- matcher coverage is still an allowlist; a new mutating tool needs an explicit
  coverage decision;
- Claude-only events must not become required core inputs without a portable
  degradation rule;
- a plugin's native Tier A does not prove every optional hook is configured.

## Codex

### Upstream capability

- **Instructions:** `AGENTS.md`.
- **Skills:** `skills/<name>/SKILL.md`.
- **Packaging:** required `.codex-plugin/plugin.json`, optional skills,
  `hooks/hooks.json`, `.mcp.json`, registered app mappings, and assets.
- **Hooks:** native tool, permission, session, prompt, compaction, subagent, and
  stop lifecycle events.
- **Decisions:** native `allow` and `deny` on `PreToolUse`; separate
  `PermissionRequest` decision flow; no supported dynamic `ask` result on
  `PreToolUse` at this snapshot.
- **Tool coverage:** official hook coverage includes Bash, `apply_patch`, MCP,
  and other local function tools.
- **MCP:** native client and plugin-bundled servers.
- **Sandbox:** native read-only and workspace-write policy surfaces.
- **Packaging trust:** installing a plugin does not automatically trust its
  non-managed hooks; the current hook definition must be reviewed.
- **Enforcement:** upstream can provide Tier A for tested tools.

Primary sources:
[plugin packaging][codex-plugin] and [hook reference][codex-hooks].

### Agent current

- the shipped config points the shell tool to `codex-shell-wrap.sh`;
- the wrapper sends synthetic canonical events through the core;
- shell `deny` and `ask` both block at the wrapper;
- session lifecycle is simulated by a Codex session wrapper;
- native file-write tools are not intercepted by the shipped wrapper;
- no `.codex-plugin/plugin.json` is present.

Therefore current Agent coverage is:

- Tier B for the exclusive shell-wrapper route;
- Tier C for native file writes that bypass the wrapper;
- synthetic adapter parity, not native Codex end-to-end parity.

### Required target

XRH-02 adds the native Codex plugin and retains the wrapper only as a tested
compatibility fallback. The existing hook commands can reuse Codex's
`CLAUDE_PLUGIN_ROOT` compatibility environment, but the decision translator
must handle Codex's unsupported `ask` safely.

## Gemini CLI

### Distribution status

Google announced that individual Google AI Pro, Ultra, and free-tier Gemini CLI
requests moved to Antigravity on 2026-06-18. Enterprise Gemini Code Assist,
Google Cloud, and paid API-key paths remain distinct supported channels
([transition notice][gemini-transition]).

This row therefore describes the enterprise/API Gemini CLI distribution. It
must not be used to promise working individual OAuth.

### Upstream capability

- **Instructions:** `GEMINI.md`.
- **Skills:** extension-bundled `skills/`.
- **Packaging:** `gemini-extension.json`; extensions may bundle hooks, skills,
  subagents, commands, MCP servers, and policies.
- **Hooks:** `BeforeTool`, `AfterTool`, `BeforeAgent`, `AfterAgent`,
  `BeforeModel`, `AfterModel`, `BeforeToolSelection`, session events, and
  compression/notification events.
- **Decisions:** hook-level `allow` and `deny`; static policy rules can use
  `ask_user`.
- **Policy engine:** extension rules can restrict operations, but extension
  policy cannot silently grant `allow` or enable yolo mode.
- **MCP:** native client and extension-bundled servers.
- **Subagents:** documented as preview in the extension system.
- **Sandbox and permissions:** native host features.
- **Enforcement:** upstream can provide Tier A for tested tools.

Primary sources:
[hook reference][gemini-hooks], [extension reference][gemini-extensions], and
[policy engine][gemini-policy].

### Agent current

- the shipped config redirects only the shell tool to
  `gemini-shell-wrap.sh`;
- shell decisions pass through the canonical core;
- native `write_file` and replacement/edit tools are not intercepted;
- lifecycle hooks are simulated by a Gemini session wrapper;
- the external worker backend is disabled by default because the individual
  access path is unavailable and no paid credential is assumed.

Current Agent coverage is Tier B for shell and Tier C for uncovered writes.
XRH-03 replaces this with a native extension for distributions that pass
authentication and runtime end-to-end probes.

## Antigravity

### Upstream capability

- **Instructions and rules:** workspace and global customizations.
- **Skills:** plugin-bundled skills.
- **Packaging:** `plugin.json` with optional `skills/`, `rules/`,
  `mcp_config.json`, and `hooks.json`.
- **Installation:** workspace plugins under `.agents/plugins/` or the
  documented global location.
- **Hooks:** `PreToolUse`, `PostToolUse`, `PreInvocation`,
  `PostInvocation`, and `Stop`.
- **Decisions:** `allow`, `deny`, `ask`, and `force_ask`.
- **MCP:** native support across Antigravity surfaces.
- **Subagents:** native agent-first runtime capability.
- **Migration:** imports Gemini extensions, skills, and settings with partial
  rather than universal parity.
- **Enforcement:** upstream supports Tier A for documented and tested tools.

Primary sources:
[plugins][antigravity-plugins], [hooks][antigravity-hooks],
[MCP][antigravity-mcp], and [Gemini migration][antigravity-migration].

### Agent current

- no Antigravity plugin or adapter exists;
- the local `agy` binary was not installed on the snapshot date;
- no native enforcement or authentication probe has been run.

The correct status is planned, not supported. XRH-03 creates a separate plugin
instead of relabeling the Gemini shell wrapper.

## API, gateway, and local models

A model endpoint does not own local permissions by default.

| Connection | Default tier | Reason |
|---|---|---|
| provider API | D | returns model output; no local tool boundary |
| model gateway | D | routing does not imply effect control |
| local inference | D | process locality does not imply sandboxing |
| Agent-owned tool gateway | B | hard only for tools forced through it |
| full SDK host with hooks and sandbox | A candidate | requires separate runtime descriptor |

Agent currently treats external models as explicit worker backends:

- roles map to provider-relative tiers;
- calls require explicit cost approval;
- preflight, timeout, capture status, and failure are mechanical;
- model names stay outside deterministic hooks;
- a worker result informs a judge but does not replace the completion gate.

XRH-04 generalizes connection kinds while preserving this contract.

## Chat-only products

Products that expose only a conversational UI can consume a mission packet and
return text. Without a controlled effect path they are:

- Tier C when durable instructions influence the conversation;
- Tier D when used as manual reviewer or advisor;
- not eligible for hard-enforcement or unattended implementer claims.

Copying the same prompt into several chats is output comparison, not a shared
harness.

## Arena evidence snapshot

Arena is classified as an evaluation source.

On the snapshot date, the Text leaderboard exposed:

- overall and task-oriented categories such as expert, occupational, coding,
  math, instruction-following, creative-writing, and hard-prompt views;
- rank and rank spread;
- score with statistical uncertainty;
- vote counts;
- input/output price;
- context length;
- proprietary and open-source license filters;
- factuality as a separate correction/filter rather than the default score.

Arena describes the leaderboard as live and based on human head-to-head
preference votes. Public entries can be marked preliminary, and methodology
changes are logged
([Arena Text leaderboard][arena-text], [Arena policy][arena-policy]).

Routing consequences:

1. do not copy a live overall rank into the evergreen model-tier policy;
2. use the category that matches the role;
3. retain votes, uncertainty, availability, price, context, and license;
4. require an Agent-local role eval before promotion;
5. keep historical evidence immutable after a routing decision;
6. never infer runtime hooks, authentication, or sandbox support from a model
   score.

## Current Agent claim audit

| Claim | Verdict on 2026-07-28 |
|---|---|
| same core hook can return the same synthetic decision | verified by parity test |
| Claude native hooks enforce configured tool gates | supported and wired |
| Codex native hooks enforce Agent gates | upstream exists; Agent not wired |
| Gemini native hooks enforce Agent gates | upstream exists; Agent not wired |
| wrappers cover every mutating tool | false |
| Antigravity is supported | false; planned |
| Arena identifies the best harness | false; it evaluates model outputs |
| a backend model can mutate the repo directly | false by dispatcher contract |

This audit is the reason the adapter guide now distinguishes core parity,
translation parity, native enforcement, and mission completion.

## Re-verification triggers

Refresh this matrix:

- at each Agent minor release or quarterly, whichever comes first;
- when a runtime adds or removes a hook decision;
- when a tool name or package manifest changes;
- when authentication or entitlement changes;
- before enabling a previously disabled backend;
- before retaining Tier A after a major runtime release;
- when an Arena methodology change affects a routing signal in use.

Every refresh records the local version probe, official source date, changed
matrix cells, and tests rerun.

[antigravity-hooks]: https://www.antigravity.google/docs/hooks
[antigravity-mcp]: https://www.antigravity.google/docs/mcp
[antigravity-migration]: https://www.antigravity.google/docs/cli/gcli-migration
[antigravity-plugins]: https://antigravity.google/docs/ide/plugins
[arena-policy]: https://arena.ai/blog/policy
[arena-text]: https://arena.ai/leaderboard/text
[claude-hooks]: https://code.claude.com/docs/en/hooks
[claude-plugins]: https://code.claude.com/docs/en/plugins
[codex-hooks]: https://learn.chatgpt.com/docs/hooks
[codex-plugin]: https://developers.openai.com/plugins/build/plugins
[gemini-extensions]: https://geminicli.com/docs/extensions/reference/
[gemini-hooks]: https://geminicli.com/docs/hooks/reference/
[gemini-policy]: https://geminicli.com/docs/reference/policy-engine/
[gemini-transition]: https://github.com/google-gemini/gemini-cli/discussions/28017
