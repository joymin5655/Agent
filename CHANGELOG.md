# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- (placeholder for next release)

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
