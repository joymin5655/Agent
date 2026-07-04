# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `.github/workflows/ci.yml` — CI: gitleaks secret scan + plugin manifest/hook/agent validation + sanitize gate
- README portfolio polish: badges, Mermaid architecture diagram, agent/skill/hook catalog
- `README.ko.md` — Korean mirror of the README (same sections, localized prose)
- `docs/harness-improvement-plan.md` — audit scorecard + prioritized backlog + autonomous
  improvement-loop design (Korean)
- `gitleaks.toml` — detect NVIDIA NIM API keys (`nvapi-` prefix; built-in rules miss it)

### Changed
- README rewritten for first-time readers: concept primer table, install-path chooser
  (plugin vs shell), prerequisites section (incl. previously undocumented `python3`
  dependency), "See it work" example, 4-layer architecture summary, trimmed layout tree
- Hook count corrected everywhere: 17 executable hooks + 1 shared module
  (`hook_config.py`) — previous "~25" claim was stale

### Fixed
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
