# Claude plugin installation lifecycle

- Snapshot: Agent v0.5.6 on 2026-07-28
- Runtime: Claude Code 2.1.220
- Scope: marketplace installation of `agent-harness@agent`

This document separates what Claude Code does during plugin installation from
what Agent does later during a session. It also records current limitations that
an installer or implementation agent must not hide.

## 1. Commands and identities

The recommended commands are:

```text
/plugin marketplace add joymin5655/Agent
/plugin install agent-harness@agent
/reload-plugins
```

The first command registers a marketplace. The second installs one plugin from
that marketplace.

| Identifier | Source |
|---|---|
| marketplace `agent` | `.claude-plugin/marketplace.json` |
| plugin `agent-harness` | `.claude-plugin/plugin.json` |
| source `./` | repository root, relative to the marketplace |
| version `0.5.6` | plugin and marketplace metadata |

The install UI asks for a scope:

| Scope | Declaration | Effect |
|---|---|---|
| user | `~/.claude/settings.json` | available in all projects for this user |
| project | `.claude/settings.json` | team-shareable project declaration |
| local | `.claude/settings.local.json` | project-only, normally gitignored |
| managed | administrator settings | centrally controlled |

Claude stores marketplace and versioned plugin content in its plugin cache.
The runtime loads the cached plugin root; it does not execute the user's GitHub
checkout in place. `CLAUDE_PLUGIN_ROOT` resolves the active cached version
([Claude plugin reference][claude-plugin-reference]).

## 2. What installation loads

Claude discovers components at the plugin root:

| Repository path | Loaded result |
|---|---|
| `.claude-plugin/plugin.json` | identity, version, description |
| `agents/*.md` | three namespaced specialist agents |
| `skills/*/SKILL.md` | nine namespaced skills |
| `commands/project-init.md` | `/agent-harness:project-init` command |
| `hooks/hooks.json` | automatic lifecycle handlers |
| `adapters/claude-code/adapter.sh` | bridge from Claude events to core hooks |
| `core/hooks/*` | deterministic policies and observers |

Plugin agents and skills are namespaced to prevent collisions. The current
specialists are:

- `agent-harness:code-reviewer`;
- `agent-harness:persona-review-orchestrator`;
- `agent-harness:security-reviewer`.

The plugin does not ship a root `.mcp.json`. Therefore marketplace installation
does not register Agent's optional brain MCP server. The alternative
`bash setup.sh --claude` path tries to register that MCP server separately; it
must not be combined with the plugin hook path without checking for duplicates.

## 3. What installation does not do

The two `/plugin` commands do not:

- edit the active project's source files;
- run `setup.sh`;
- create `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, or `hook-config.yml`;
- install `git`, Python, `gitleaks`, `jq`, or `sqlite3`;
- install Codex or Gemini integration;
- register the optional brain MCP server;
- create a worktree or start an Agent mission;
- run a model call merely because the plugin was downloaded.

Automatic behavior begins only when the plugin is enabled and its lifecycle
event fires. Users should inspect `hooks/hooks.json` and the referenced scripts
before enabling because command hooks execute with the user's local authority.

## 4. Activation

`/reload-plugins` reloads skills, agents, hooks, plugin MCP servers, and LSP
servers in the current session. Starting a new Claude Code session also loads
the enabled plugin. A full restart is not conceptually required when reload
succeeds, although a new session is the cleanest verification boundary
([Claude plugin guide][claude-plugin-guide]).

At activation:

1. Claude resolves the installed version in its cache.
2. It discovers standard component directories.
3. It registers namespaced skills, agents, and the project-init command.
4. It parses `hooks/hooks.json`.
5. Hook command paths expand from `CLAUDE_PLUGIN_ROOT`.
6. No hook runs until its matching lifecycle event occurs.

Claude runs all matching hook handlers in parallel and deduplicates identical
handlers. Array position is not execution order. Policy safety must therefore
come from decision precedence and independent hook behavior, not from
side-effect sequencing ([Claude hooks][claude-hooks]).

## 5. Session lifecycle

### Session start

On `SessionStart`, Claude launches:

- `agent-session-start.sh`;
- `session-init.py`.

The scripts are best-effort. They can clear stale temporary flags, inspect
dependencies, reconcile an agent registry, report active-session context, and
perform session garbage collection when the required project-local state is
available.

### Prompt submission

On every `UserPromptSubmit`, Claude launches:

- `agent-session-heartbeat.sh`;
- `supervisor.py`.

The heartbeat refreshes a registered session. The supervisor compares the
prompt with specialist-routing rules and records matching intent. It does not
run a specialist merely because the plugin was installed.

### Before a tool effect

`PreToolUse` is the enforcement boundary.

| Matcher | Registered core hooks |
|---|---|
| `Bash` | `pre-tool-guard.sh` |
| all tools | `r4-mutex-check.sh`, `context-mode-guard.sh` |
| `Write`, `Edit`, `MultiEdit` | hardcoding, secret, mutex, TDD, spec, supervisor, plan-scope hooks |
| selected WebFetch and MCP tools | `secret-content-scan.py` |

Each command goes through `adapters/claude-code/adapter.sh`. The adapter resolves
the named file under `core/hooks/`, forwards the event on stdin, and forwards
stdout, stderr, and the exit code back to Claude.

The result can:

- return no decision and leave normal permissions in place;
- allow the covered call;
- deny it before execution;
- ask the user;
- add context where the event supports it.

An `allow` from one parallel hook does not override a stricter result. Claude's
documented precedence is `deny > defer > ask > allow`.

### After a tool result

On matching `PostToolUse` events:

| Matcher | Registered core hooks |
|---|---|
| `ExitPlanMode`, `Task`, `Agent` | plan gate, supervisor, model-routing observer |
| `Bash` | circuit breaker, rubric commit observer |
| `Write`, `Edit`, `MultiEdit` | file-mutex registration |

These handlers record approvals, dispatch evidence, model-routing evidence,
command failures, rubric state, or the last file writer. A post-tool observer
cannot undo an external effect that already happened.

### Stop

When Claude attempts to stop, it launches:

- `session-quality-gate.py`;
- `brain-capture.py`;
- `session-close.sh`.

The quality gate may run project-declared completion commands and block the
first stop when objective completion tests fail. Brain capture records
uncommitted work only when its store is available. Session close clears
temporary state, broadcasts completion where possible, and may display a macOS
notification.

## 6. Explicit project initialization

Plugin installation makes `/agent-harness:project-init` available; it does not
run the command.

When the user explicitly invokes it, the command calls:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/setup.sh" --project
```

That operation is materially different from plugin installation. In the active
Git repository it can:

- render `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `hook-config.yml`, and
  `gitleaks.toml`;
- prompt before replacing a destination that differs;
- create `.git-hooks-framework` pointing into the cached plugin version;
- set Git's local `core.hooksPath` to that link;
- run the setup doctor's read-only validation afterward.

Because `CLAUDE_PLUGIN_ROOT` is a versioned cache path, an update can move the
target. Claude documents the plugin root as ephemeral across versions. Any
project symlink that points into it must be revalidated after updates.

## 7. Current reality gaps

These are current-state findings, not future design:

1. Some session and supervisor scripts resolve `core/infra` or the agent
   registry from the active project root. A normal external project scaffold
   does not copy those trees. Those portions can therefore no-op even though
   Claude loaded the plugin components successfully. `skills/council-review/SKILL.md`'s
   external-lane dispatch is resolved (2026-08-20): it resolves
   `core/infra/call-worker.sh` via `${CLAUDE_PLUGIN_ROOT:-$PWD}` rather than a
   bare cwd-relative path, so it works from a plugin install. Other consumers
   named in this item may still carry the gap — verify per-consumer, not by
   this one fix.
2. The Claude adapter silently passes when a named core hook is missing. This
   favors session availability but means installation health must be verified
   separately. The same fail-open stance holds in the Codex/Gemini shell
   wraps: a crashed hook's output is discarded and the wrapped command still
   executes (see `hook-protocol.md` § 4, exit code 1).
3. All matching Claude handlers run in parallel. Comments or documentation that
   depend on handler array order are not an enforcement guarantee.
4. Installing both the marketplace plugin and `setup.sh --claude` can register
   the same hook family twice. `bash setup.sh --doctor` reports that state.
5. Multiple cached versions can expose stale components. The doctor warns when
   it sees more than one cached version.
6. The plugin path does not install the optional dependencies that individual
   hooks may need. Missing tools can degrade observers or secret scanning.
7. The `.git-hooks-framework` symlink points at a **versioned** plugin-cache
   path. A plugin update that evicts that version leaves the link dangling,
   and `core.hooksPath` then names a dead directory — git skips all hooks
   (pre-commit gitleaks, staged-secret scan, pre-push scans) with no warning.
   Nothing currently repairs or detects this: `setup.sh`'s `-L` guard is true
   for a dangling link (so re-running project-init does not re-point it), and
   `setup.sh --doctor` has no hooksPath check. Until a doctor check lands,
   the project-init verify step's `test -e .git-hooks-framework` is the
   detection point — run it after every plugin update.

These gaps explain why the cross-runtime roadmap requires native installation
tests, a capability registry, and bypass fixtures instead of treating manifest
presence as proof of working enforcement.

## 8. Verification checklist

After installation:

1. Run `/plugin` and confirm `agent-harness@agent` is enabled in the intended
   scope.
2. Run `/reload-plugins` or start a fresh session.
3. Confirm the namespaced agents, skills, and project-init command appear.
4. Review hook trust and run a harmless session-start probe.
5. In a scratch repository, test one safe shell call and one denied secret-read
   fixture.
6. Test a denied `Write` fixture, not only Bash.
7. Run `bash setup.sh --doctor` from a stable checkout if using its diagnosis.
8. Check that only one Claude installation path is active.
9. Treat project initialization as a separate, explicit mutation.

The portable target architecture and other runtimes are documented in
[`cross-runtime-harness-design.md`](cross-runtime-harness-design.md).

[claude-hooks]: https://code.claude.com/docs/en/hooks
[claude-plugin-guide]: https://code.claude.com/docs/en/plugins
[claude-plugin-reference]: https://code.claude.com/docs/en/plugins-reference
