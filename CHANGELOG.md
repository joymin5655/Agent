# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `session-init` now warns (stderr only) when `gitleaks` or `git` is missing from
  PATH — a mini env-doctor surfacing a degraded secret-scan setup at session start.
  Silent when both are present; never blocks the session or writes stdout. A full
  `--doctor` subcommand remains future work.
- `.github/workflows/ci.yml` — CI: gitleaks secret scan + plugin manifest/hook/agent validation + sanitize gate
- README portfolio polish: badges, Mermaid architecture diagram, agent/skill/hook catalog
- `README.ko.md` — Korean mirror of the README (same sections, localized prose)
- `docs/harness-improvement-plan.md` — audit scorecard + prioritized backlog + autonomous
  improvement-loop design (Korean)
- `gitleaks.toml` — detect NVIDIA NIM API keys (`nvapi-` prefix; built-in rules miss it)
- `docs/architecture.md` — "Determinism and model-invariance" section: the hooks (gates)
  are model-invariant and machine-proven so via `core/tests/adapter-parity.sh`; risk-area
  denial is a real enforced gate while plan-mode/TDD enforcement is not yet wired (flag is
  recorded but unconsumed — see P1-4/P1-8); generated content (plans, code, prose) is
  honestly NOT guaranteed identical across models

### Changed
- README rewritten for first-time readers: concept primer table, install-path chooser
  (plugin vs shell), prerequisites section (incl. previously undocumented `python3`
  dependency), "See it work" example, 4-layer architecture summary, trimmed layout tree
- Hook count corrected everywhere: 17 executable hooks + 1 shared module
  (`hook_config.py`) — previous "~25" claim was stale
- README.md/README.ko.md's "Why AI-agnostic?" section now cross-links to
  `docs/architecture.md`'s new "Determinism and model-invariance" section

### Fixed
- `plan-gate` was wired to `UserPromptSubmit` in `hooks/hooks.json` but is a
  `PostToolUse` hook (its docstring and logic key off `tool_name`, a field absent
  from `UserPromptSubmit` events). Result: every invocation was a silent no-op and
  the `/tmp/agent-plan-approved` flag was never written. Rewired to `PostToolUse`
  with matcher `ExitPlanMode|Task|Agent`, and broadened the plan-class check to
  accept the `Task` tool name (subagent dispatch differs by Claude Code version).
  READMEs' hook tables corrected to match.
- `session-quality-gate` wrote its violations log to `parents[2]` of the hook
  file — the plugin install cache when installed as a plugin — instead of the
  user's project. Log destination is now resolved at runtime: stdin event `cwd`
  → `CLAUDE_PROJECT_DIR` → `os.getcwd()`. Detection and block logic unchanged.
- `session-init` crashed at load on Python 3.9 — its `pathlib.Path | None` return
  annotation (PEP 604) is evaluated at def-time and raises `TypeError` before 3.10.
  Added `from __future__ import annotations` so annotations are treated as strings;
  the annotation itself is unchanged. Supported Python floor is 3.9 (now documented
  in README Prerequisites).
- Phantom test paths removed from `README.md`, `AGENTS.md`, `docs/architecture.md`,
  `docs/getting-started.md` — `core/tests/adapter-smoke/*/run.sh`, `cross-ai-parity.sh`,
  `verify-all.sh`, `bootstrap-test.sh`, and a pytest invocation never existed; docs now
  reference the 4 real test scripts (`sanitize-audit`, `adapter-parity`, `hook-config-test`,
  `post-commit-autosync-test`)
- Documented overwrite behavior corrected: `setup.sh` has no `--force` flag — replacements
  prompt interactively, or set `AGENT_SETUP_YES=1`
- `README.md` infra path corrected: `scripts/infra/agent-session.sh` → `core/infra/agent-session.sh`
- `AI_BOOTSTRAP.md` Step 5 pledge now names the generic 5 risk areas (per `hook-config.yml`
  / `rules/policy/security-guards.md`) instead of prior-project domain terms; the removed
  terms were added to the sanitize-audit token list (failure → new rule)
- `core/tests/sanitize-audit.sh` now scans git-visible content only (tracked +
  untracked-unignored via `git grep --untracked`), mirroring the CI job's excludes —
  runtime state and gitignored local files no longer cause permanent false FAILs;
  CI sanitize job additionally runs the full token-set audit as a superset step
- `core/hooks/secret-content-scan.py` plan-file comment corrected to the canonical
  `~/.agent/plans/` path
- Docs drift sweep: removed phantom hook/file references (`memory-explore-verify.py`,
  `claude-mem-watch.py`, `rules/policy/skill-adoption-comparison.md`) that described
  tooling never implemented; standardized risk-area vocabulary to the canonical
  `data` / `secrets` / `deploy` / `payment` / `domain-output` IDs across README,
  README.ko, `docs/customization.md`, and `docs/concepts/security-guards-generic.md`;
  corrected the security-guard layer count from 5 to 6 (matches `hooks.json`'s
  "6-layer secret hardening"); canonicalized stale `.claude/` path references to the
  runtime's actual `.agent/` and `rules/`/`skills/` locations in
  `docs/concepts/multi-session-worktree.md`, `AI_BOOTSTRAP.md`, and
  `docs/concepts/plan-mode.md`; and removed the `.claude/rules/` scaffold
  over-claim from `docs/architecture.md`, `README.md`, and `README.ko.md`
  (`setup.sh --project` never creates it)
- Docs drift sweep follow-up: removed the two remaining phantom
  `rules/policy/skill-adoption-comparison.md` references (`docs/master-registry.md`,
  `skills/README.md`); removed the phantom `classify-prompt.py` hook citation from
  `docs/concepts/plan-mode.md` (no `UserPromptSubmit` hook exists beyond
  `agent-session-heartbeat.sh` — tier classification is the AI applying the
  documented heuristics itself, not an automated hook). Rewrote
  `docs/customization.md` end to end after discovering its documented
  `hook-config.yml` schema doesn't match what any hook actually loads: only
  `core/hooks/hook_config.py` (used by `secret-content-scan.py`) reads a config
  file dynamically, from `.agent/hook-config.yml`/`.json` — a `[regex, label]`-pair
  `secret_patterns`/`exempt_paths`/`credential_key_names` schema, optionally
  nested under `python_hooks:`. The previously-documented `risk_areas:`/`resources:`/
  `hardcoding:` map (from `templates/hook-config.yml.template`) is not read by
  any hook at runtime — `pre-tool-guard.sh`, `r4-mutex-check.sh`, and
  `check-hardcoding.py` each match against patterns hardcoded in the script, not
  a project's `hook-config.yml`. The doc's old `secret_patterns` example
  (`{id, description, regex}` objects) was also independently confirmed to
  silently parse to an empty list under the real loader, which expects
  `[regex, label]` pairs — verified by running `hook_config._coerce_pattern_list`
  directly against both shapes. `README.md`/`README.ko.md`'s customization
  section and other doc mentions of a dynamically-loaded `risk_areas:`/`resources:`
  still describe the same not-yet-implemented mechanism and were out of scope for
  this sweep — flagged for a follow-up pass.
- Docs drift sweep, final pass: closed out the flagged follow-up above.
  `README.md`/`README.ko.md`'s Customization section no longer claims
  `core/hooks/r4-mutex-check.sh` "reads [`hook-config.yml`] and enforces it" —
  the `risk_areas:` block is now described as declarative (a documented policy
  record), with today's actual enforcement attributed to each hook script's own
  hardcoded patterns and the one dynamically-loaded mechanism (secret-scan
  extensions via `.agent/hook-config.yml`) called out, linking to
  `docs/customization.md` for the full real-vs-documented split.
  `AI_BOOTSTRAP.md`'s Step 5 pledge softened from "definitions live in
  `hook-config.yml`" (implies runtime consumption) to "declared in
  `hook-config.yml`; enforcement currently lives in the hook scripts."
  Same fix applied to the last two remaining spots the gate caught:
  `docs/concepts/security-guards-generic.md`'s "How to extend" section no
  longer claims "the same `pre-tool-guard.sh` reads this and enforces it" or
  shows a fabricated `abort_code` key — the example is now framed as
  declarative intent requiring a `pre-tool-guard.sh` fork to enforce, with a
  link to `docs/customization.md`. `rules/multi-agent-worktree.md`'s R4
  mutex-resource list dropped the phantom `payment-live` entry —
  `core/hooks/r4-mutex-check.sh` only ever claims `production-db`,
  `production-deploy`, or `edge-function-deploy`; there is no payment mutex.

### Removed
- *(recorded retroactively — the trim shipped before 0.2.0 but was never logged)*
  Shipped agent set reduced 10 → 5 (`architect`, `code-reviewer`, `security-reviewer`,
  `test-engineer`, `build-error-resolver`) and skills 16 → 4 (`supervise`, `tdd`,
  `diagnose`, `wrap`); the removed items remain available in `legacy/`
- Shipped agent set reduced 5 → 2: `architect`, `test-engineer`, and
  `build-error-resolver` archived to `legacy/trim-2026-07-04/agents/`. Basis:
  7 weeks of session telemetry showed zero dispatches for these three, and
  their roles are covered by other tooling. `code-reviewer` and
  `security-reviewer` are retained (they form the benchmarked review pair —
  see `docs/benchmark/results.md`). Recoverable via `git mv` from the
  archive plus re-adding the entries to `agents/master-registry.json`.
- Shipped skill set reduced 4 → 2: `tdd` and `diagnose` archived to
  `legacy/trim-2026-07-04/skills/`. Basis: 7 weeks of session telemetry
  showed zero dispatches for either skill. `supervise` and `wrap` are
  retained. The `tdd-guard` hook is unrelated to the `tdd` skill and
  continues to run unchanged. Recoverable via `git mv` from the archive.
- `codex-skills/` retired to `legacy/trim-2026-07-04/codex-skills/`. Basis:
  zero usage recorded in 7 weeks of session telemetry. The Codex CLI
  adapter (`adapters/codex/`) is unrelated and remains active; `setup.sh`
  no longer offers the `~/.codex/skills` symlink install step. See
  `legacy/trim-2026-07-04/ARCHIVE-NOTE.md` for the full recovery procedure.

## [0.2.0] — 2026-06-15

### Added
- **Claude Code plugin packaging** — `.claude-plugin/plugin.json` + `marketplace.json` make
  the harness installable via `/plugin marketplace add joymin5655/Agent` →
  `/plugin install agent-harness@agent`. One install, every project.
- `hooks/hooks.json` — plugin hook wiring (SessionStart / Stop / UserPromptSubmit /
  PreToolUse / PostToolUse) dispatching through the Claude Code adapter to `core/hooks/`
  via `${CLAUDE_PLUGIN_ROOT}`.
- `commands/project-init.md` — `/project-init` slash command to scaffold project-level files.
- `LICENSE` — MIT (was TBD).

### Changed
- README now leads with the Claude Code plugin install path; shell `setup.sh` remains for
  Codex/Gemini or non-plugin use.

## [0.1.0] — 2026-05-18

### Added
- Initial AI-agnostic agent framework structure
- 3-AI adapter layer: Claude Code, Codex CLI, Gemini CLI
- Canonical hook protocol (`docs/hook-protocol.md`): stdin JSON event + stdout decision JSON
- Core hooks (`core/hooks/`): ~25 portable hooks for security, session coordination, plan-mode, TDD enforcement, drift detection
- Core infra (`core/infra/`): multi-session worktree coordination (`agent-session.sh`), commit/PR automation (`auto-ship.sh`), session store, supervisor goal mode
- Core git-hooks (`core/git-hooks/`): pre-commit (gitleaks + hardcoding scan) + pre-push (gitleaks + secret diff scan)
- Generic policy rules (`rules/`): 7 critical + 12 lazy-loaded archive
- Generic agents (`agents/`): code-reviewer / architect / build-error-resolver / security-reviewer / performance-optimizer / test-engineer / docs-writer / refactor-cleaner / tdd-guide / copy-humanizer
- Generic skills (`skills/`): wrap, supervise, tdd, diagnose, grill-me, grill-with-docs, improve-codebase-architecture, caveman, api-and-interface-design, incremental-implementation, source-driven-development, deprecation-and-migration, design-variant-mockup, hook-reproduce-test, triage-external-draft, weekly-digest
- Codex-native skills (`codex-skills/`): code-explorer, code-reviewer, database-reviewer, planner
- Templates (`templates/`): generic CLAUDE.md / AGENTS.md / GEMINI.md / RTK.md / karpathy.md / hook-config.yml / project-rules.md / gitleaks.toml
- `setup.sh` 4-mode installer: `--claude` / `--codex` / `--gemini` / `--project` / `--hooks-only`
- GitHub Actions workflow templates (`github/workflows.template/`): secret scan + lint

### Changed
- N/A (first release)

### Archived
- `legacy/v0-mirror-2026-05-12/` — original mirror skeleton + domain-specific assets from the prior project version. See `legacy/v0-mirror-2026-05-12/ARCHIVE-NOTE.md` for migration guide.

### Security
- Base `gitleaks.toml` with 100+ built-in patterns + extensible per-project allowlist
- Generic content-scan hook with 7 default patterns covering Python/Node secret-file readers, hardcoded credentials, OpenAI-style `sk-...` tokens, JWT literals, Bash secret-readers, and exfiltration via `find -exec` (see `core/hooks/secret-content-scan.py` for full pattern list)
- Project-configurable risk-area abort codes via `templates/hook-config.yml.template`

[Unreleased]: https://github.com/joymin5655/Agent/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/joymin5655/Agent/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joymin5655/Agent/releases/tag/v0.1.0
