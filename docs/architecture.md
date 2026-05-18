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
1. Receives a native AI event (Claude Code stdin JSON, Codex event, Gemini callback)
2. Translates to canonical event JSON (per [`hook-protocol.md`](hook-protocol.md))
3. Pipes to a `core/hooks/<name>` script
4. Reads canonical decision JSON
5. Translates back to the AI's native enforcement (deny → stop tool, ask → prompt user, allow → continue)

For Claude Code, the native event JSON ≈ canonical event JSON, so the adapter is a thin pass-through.

For Codex CLI and Gemini CLI, the adapter does real translation (their event formats differ).

Each adapter also provides a `settings.template` or `config.template` showing how a user registers hooks in that AI's config file.

## Layer 3: Templates + project scaffolding

`templates/` + `setup.sh`.

`setup.sh --project` scaffolds the following into a target project:
- `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` (project-aware AI instructions)
- `gitleaks.toml` (extends the base from `templates/gitleaks.toml.template`)
- `.claude/rules/` (sanitized generic policy)
- `hook-config.yml` (project's risk areas + resources)
- `.gitignore` additions
- `.git/hooks/{pre-commit, pre-push}` (link to `core/git-hooks/`)

Idempotent. Existing files skipped unless `--force`.

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
[AI runtime fires PreToolUse hook]
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

The same `pre-tool-guard.sh` script is invoked by all 3 AIs. The adapter handles the translation.

---

## Tests by layer

| Layer | Test type | Location |
|---|---|---|
| 1 | Unit (synthetic event JSON → decision JSON) | `core/tests/<hook>-test.sh` |
| 2 | Adapter smoke (native event → adapter → core → decision → enforcement) | `core/tests/adapter-smoke/<ai>/run.sh` |
| 2 | Cross-AI parity (same logical event → same decision across all 3) | `core/tests/cross-ai-parity.sh` |
| 3 | Bootstrap (fresh project → setup.sh → expected files) | `core/tests/bootstrap-test.sh` |

Layer 4 is the project's responsibility.

---

## What's NOT in the framework

- Application logic
- Domain-specific rules (e.g., "any user-facing prediction must include confidence intervals") — those go in your project's `hook-config.yml` + custom hooks
- AI runtime binaries (you bring your own `claude`, `codex`, `gemini`)
- Secret values (gitleaks scans for them; framework never stores them)
- Project-specific paths (everything is `$REPO_ROOT`-relative)
