# Architecture

The framework has 4 layers. Higher layers depend on lower; lower layers don't know about higher.

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 4: Project consumer code                                  │
│ (your app, your rules, your hook-config.yml)                    │
└─────────────────────────────────────────────────────────────────┘
                              ↑ depends on
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3: Templates + project scaffolding                        │
│ (templates/*.template, setup.sh --project mode)                 │
└─────────────────────────────────────────────────────────────────┘
                              ↑ depends on
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: AI adapters                                            │
│ (adapters/claude-code/, adapters/codex/, adapters/gemini/)      │
└─────────────────────────────────────────────────────────────────┘
                              ↑ depends on
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: AI-agnostic core                                       │
│ (core/hooks/, core/infra/, core/git-hooks/)                     │
└─────────────────────────────────────────────────────────────────┘
```

## Layer 1: AI-agnostic core (the truth)

`core/hooks/`, `core/infra/`, `core/git-hooks/`.

This layer:
- Has zero AI-specific code
- Reads canonical JSON from `stdin`, writes canonical JSON to `stdout`
- Cares about: secret hygiene, resource locks, session coordination, plan discipline, drift detection
- Does NOT care about: which AI invoked it, what runtime config it was registered under

A hook here is testable in isolation: `echo '{...event JSON...}' | bash core/hooks/<name>` returns a decision.

## Layer 2: AI adapters (the translators)

`adapters/claude-code/`, `adapters/codex/`, `adapters/gemini/`.

Each adapter:
1. Receives a native hook event or an event from an exclusive controlled wrapper.
2. Translates to canonical event JSON (per [`hook-protocol.md`](hook-protocol.md))
3. Pipes to a `core/hooks/<name>` script
4. Reads canonical decision JSON
5. Translates back to the AI's native enforcement (deny → stop tool, ask → prompt user, allow → continue)

For Claude Code, the native event JSON ≈ canonical event JSON, so the adapter is a thin pass-through.

The shipped Codex and Gemini adapters currently translate events from shell
wrappers. Their upstream runtimes now expose native hooks, but Agent has not yet
wired those paths. File-write tools outside the wrappers are therefore not
covered. See [`ai-adapters.md`](ai-adapters.md) for current versus target support.

Each adapter also provides a `settings.template` or `config.template` showing how a user registers hooks in that AI's config file.

## Layer 3: Templates + project scaffolding

`templates/` + `setup.sh`.

`setup.sh --project` scaffolds the following into a target project:
- `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` (project-aware AI instructions)
- `gitleaks.toml` (extends the base from `templates/gitleaks.toml.template`)
- `hook-config.yml` (project's risk areas + resources)
- `.gitignore` additions
- `.git/hooks/{pre-commit, pre-push}` (link to `core/git-hooks/`)

Idempotent. Existing files prompt "Overwrite?" before replacing — there is no `--force` flag; set `AGENT_SETUP_YES=1` to auto-confirm.

## Layer 4: Project consumer code

Your application code. The framework doesn't know or care about this layer's structure, language, or framework. It coordinates AI sessions, scans secrets, and enforces policy from below.

---

## Why this layering matters

Decisions belong in the lowest layer where they're meaningful:

| Decision | Right layer | Why |
|---|---|---|
| "Is `cat secrets/foo` safe?" | Layer 1 (core hook) | Universal — every AI, every project |
| "How does Codex send me PreToolUse?" | Layer 2 (adapter) | AI-specific |
| "What's a risk area in MY project?" | Layer 4 (hook-config.yml) | Project-specific |
| "Should I auto-merge?" | Layer 4 (user invocation) | User-specific |

If you find yourself adding AI-specific code to a `core/hooks/*` file, push it up to the adapter. If you find yourself adding project-specific values to a `core/hooks/*` file, push it up to `hook-config.yml`.

---

## Hook execution flow (PreToolUse example)

```
User: "run cat secrets/db.env"
       │
       ▼
[Claude Code / Codex / Gemini] (Layer 4 of consumer = AI runtime)
       │
       │ wants to invoke Bash tool with command "cat secrets/db.env"
       │
       ▼
[AI runtime fires a native hook OR an exclusive wrapper intercepts the effect]
       │ ──► native AI event format
       ▼
[adapters/<ai>/adapter.sh]                (Layer 2)
       │ ──► canonical JSON (stdin to core hook)
       ▼
[core/hooks/pre-tool-guard.sh]            (Layer 1)
       │ pattern match: command matches "secrets/"
       │ ──► {"hookSpecificOutput":{"permissionDecision":"deny",...}}
       ▼
[adapters/<ai>/adapter.sh]                (back to Layer 2)
       │ ──► native AI deny mechanism
       ▼
[AI runtime cancels the Bash tool, shows reason to user]
```

The same `pre-tool-guard.sh` script is invoked by each shipped adapter route.
The adapter handles translation; the capability matrix records which native
tools actually reach that route.

---

## Determinism and model-invariance

Two different guarantees live in this framework, and they don't mix.

**Deterministic gates (the hooks) are model-invariant.** `core/hooks/*` scripts are plain
code — same event JSON in, same decision JSON out, regardless of which AI or model fired
the event. `core/tests/adapter-parity.sh` feeds one logical synthetic event through all
three translators and asserts an identical decision. This proves core/translation parity,
not that every native tool call reaches an adapter. Native registration, bypass coverage,
and mission completion are separate test layers in the
[cross-runtime design](cross-runtime-harness-design.md#11-implementation-backlog-for-claude).

**Process enforcement is real for covered risk-area routes, not yet wired for plan/TDD.**
When a tool route reaches the adapter, `pre-tool-guard.sh` runs before the effect and can
return `permissionDecision: deny` — a model that ignores the policy still cannot use that
route. Uncovered native tools do not inherit this guarantee; see the
[capability matrix](benchmark/runtime-capability-matrix-2026-07.md).

Plan-mode and TDD gates ship in observation mode. `plan-gate.py` is a `PostToolUse` hook —
it *records* plan approval (writes `/tmp/agent-plan-approved` after `ExitPlanMode` or a
plan-class `Agent`/`Task` dispatch) — and the flag has two wired consumers:
`spec-gate.py` (`PreToolUse` on `Write|Edit|MultiEdit`) short-circuits its gate when the
flag exists, and `plan-scope-allow.py` reads the same flag to auto-allow `Write`/`Edit`
permission prompts for plan-approved work. Both `spec-gate.py` and `tdd-guard.py` default to `dryrun`
(`AGENT_SPEC_GATE_MODE` / `AGENT_TDD_GUARD_MODE`), which logs would-block verdicts as
advisory only; each returns a real deny only when explicitly set to `block` — see
`docs/harness-improvement-plan.md` P1-4/P1-8.

**What's honestly NOT model-invariant: generated content.** The plan a model writes, the
code it produces, the prose in a commit message — these vary by model and prompt. The
framework guarantees the same gates fire and the same process is enforced; it does not
guarantee byte-identical output. Two different models running the same mission through the
same hooks will produce different diffs that both pass the same gates — same enforcement,
not same output.

See [`core/tests/adapter-parity.sh`](../core/tests/adapter-parity.sh) for the machine proof.

---

## Tests by layer

| Layer | Test type | Location |
|---|---|---|
| 1 | Unit (config parsing, hook behavior) | `core/tests/hook-config-test.sh`, `core/tests/post-commit-autosync-test.sh` |
| 1 | Domain-neutrality gate | `core/tests/sanitize-audit.sh` |
| 2 | Cross-AI parity (same logical event → same decision across all 3 adapters) | `core/tests/adapter-parity.sh` |
| 3 | Bootstrap (fresh project → setup.sh → expected files) | *(planned)* |

Layer 4 is the project's responsibility.

---

## What's NOT in the framework

- Application logic
- Domain-specific rules (e.g., "any user-facing prediction must include confidence intervals") — those go in your project's `hook-config.yml` + custom hooks
- AI runtime binaries (you bring your own `claude`, `codex`, `gemini`)
- Secret values (gitleaks scans for them; framework never stores them)
- Project-specific paths (everything is `$REPO_ROOT`-relative)
