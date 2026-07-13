# AGENTS.md

This file follows the [agents.md spec](https://agents.md) so any AI coding agent (Codex CLI, OpenAI Assistants, Cursor, etc.) can understand how to work in this repo.

For Claude Code, see also [`CLAUDE.md`](CLAUDE.md) (if present) or use this file as the primary instructions.

For Gemini CLI, see also [`GEMINI.md`](GEMINI.md) (if present) or use this file.

---

## What this repo is

An **AI-agnostic agent framework**: rules, hooks, agents, skills, and automation that work identically across Claude Code / Codex CLI / Gemini CLI.

The repo itself is the framework. Consumers `git clone` it and run `setup.sh` to install configs into their AI runtime (`~/.claude/`, `~/.codex/`, `~/.gemini/`) and optionally scaffold a target project.

---

## Operating mode for AI agents working IN this repo

When an AI agent works on improving the framework itself (this repo, not a consumer project):

### 1. Plan before code

For any change touching 3+ files or any change to `core/hooks/`, `adapters/`, or `rules/`: write a plan to `/tmp/agent-plan-<slug>.md` before editing. Discuss tradeoffs with the user before implementation.

### 2. Sanitize discipline

This repo MUST stay domain-neutral. The original maintainer ported it from a prior domain-specific project (the v0 mirror of it is preserved on the `archive/v0-mirror` tag, out of the shipped tree; later trim snapshots stay under `legacy/`). Before committing any file under `core/`, `rules/`, `agents/`, `skills/`, `templates/`, `docs/`, or root:

```bash
# Run the sanitize audit — must return zero matches outside legacy/
bash core/tests/sanitize-audit.sh
```

The audit script greps for known domain taint patterns (prior project name, prior-project domain terms, prior-project absolute paths). The pattern list lives in `core/tests/sanitize-audit.sh` — update it if you introduce a new project-specific term that needs guarding.

If you see any match outside `legacy/`, fix before commit.

### 3. Cross-AI parity

Any change to `core/hooks/<name>` must keep the canonical hook protocol intact:
- **stdin**: JSON with `ai`, `session_id`, `event`, `tool_name`, `tool_input`, `cwd`, `transcript_path`
- **stdout**: JSON with `hookSpecificOutput.{hookEventName,permissionDecision,permissionDecisionReason}`

See [`docs/hook-protocol.md`](docs/hook-protocol.md) for the schema.

After any core hook change, run:

```bash
bash core/tests/adapter-parity.sh
```

All 3 adapters must return the same decision for the same input event.

### 4. Test discipline (TDD)

For any new hook in `core/hooks/`, write a reproduce test in `core/tests/<name>-test.sh` FIRST. Make it fail. Then implement the hook. Then make it pass.

### 5. Commit hygiene

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`
- One logical change per commit
- Pre-commit hook runs `gitleaks` + `check-staged.py` automatically — don't bypass with `--no-verify`
- Co-author tag if you're an AI agent: `Co-Authored-By: <AI Name> <noreply@<provider>.com>`

### 6. PR discipline

- Branch naming: `<agent>/<task-slug>` (e.g., `codex/add-pre-pr-hook`, `claude/fix-supervisor-race`)
- Push to your own branch, never to `main`
- Open a PR with full description: what, why, how tested, before/after
- Wait for human review + merge (no auto-merge in this repo)

---

## Repository structure

(See `README.md` § "Layout" for the full tree.)

Key entry points:
- `setup.sh` — installer (4-mode)
- `core/hooks/` — the truth (AI-agnostic hook implementations)
- `adapters/{claude-code,codex,gemini}/` — AI-specific bridges
- `docs/hook-protocol.md` — canonical event schema
- `rules/` — generic policy docs (sanitized from prior project work)
- `templates/` — project scaffolds

---

## Multi-session coordination (when multiple AIs work in this repo)

If you're working in this repo alongside another AI session:

1. Run `bash core/infra/agent-session.sh start <your-task-slug>` at session start
2. Run `bash core/infra/agent-session.sh dashboard` to see active sessions
3. Check `core/infra/TIER-2-COORD-CONTRACT.md` for full coordination rules
4. Run `bash core/infra/agent-session.sh stop` at session end

See [`rules/multi-agent-worktree.md`](rules/multi-agent-worktree.md) for the full R1-R14 protocol.

---

## Quick commands

```bash
# Linting / type-check (Python hooks)
python3 -m ruff check core/

# Cross-AI parity (same event → same decision across all 3 adapters)
bash core/tests/adapter-parity.sh

# Sanitize audit
bash core/tests/sanitize-audit.sh

# Config parsing + autosync hook
bash core/tests/hook-config-test.sh
bash core/tests/post-commit-autosync-test.sh

# Full verification (all test scripts)
for t in core/tests/*.sh; do bash "$t" || exit 1; done
```

---

## Style

- Shell: `set -euo pipefail` at the top of every script. `shellcheck` clean.
  Counting idiom under strict mode: a zero-match `grep` exits 1, so guard
  count pipes as `{ grep -E pat file || true; } | wc -l` and count
  assignments as `n=$(grep -c pat file || true)` — enforced by
  `core/tests/pipefail-idiom-scan.sh` (W-7).
- Python: PEP 8, type hints, ruff clean. No `print` for hook stdout — use `json.dumps` with strict schema.
- Markdown: max 100 chars per line for prose. No trailing whitespace.
- Comments: only when WHY is non-obvious. Don't narrate WHAT — code says that.

---

## When in doubt

- Read [`rules/contributing.md`](rules/contributing.md) for coding rules
- Read [`rules/public-repo.md`](rules/public-repo.md) for repo safety
- Read [`rules/policy/evidence-first.md`](rules/policy/evidence-first.md) — verify
  present state before you assert it; never demand a provider you haven't confirmed exists
- Read [`docs/hook-protocol.md`](docs/hook-protocol.md) for the hook contract
- Open an issue or ask the human maintainer

The framework is opinionated about **session coordination**, **secret hygiene**, and **policy enforcement**. It's NOT opinionated about your project's domain or stack.
