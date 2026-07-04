# 2026-07-04 Usage Trim — Archived

This directory preserves shipped components removed from the active plugin
based on usage evidence from 7 weeks of session telemetry.

## What's here

| Path | What it was | Basis for removal |
|---|---|---|
| `agents/architect.md` | Plan-only agent for multi-file design work | Zero dispatches recorded |
| `agents/test-engineer.md` | Agent for writing/maintaining tests, TDD enforcement | Zero dispatches recorded |
| `agents/build-error-resolver.md` | Agent for minimal-diff build/type/lint fixes | Zero dispatches recorded |
| `skills/tdd/` | `/tdd` — Red-Green-Refactor cycle enforcement skill | Zero dispatches recorded |
| `skills/diagnose/` | `/diagnose` — root-cause analysis skill | Zero dispatches recorded |
| `codex-skills/` | Codex-native skill format (`code-explorer`, `code-reviewer`, `database-reviewer`, `planner`) | Zero usage recorded; the Codex CLI adapter (`adapters/codex/`) is unaffected and remains active |

## What's retained

- Agents: `agents/code-reviewer.md`, `agents/security-reviewer.md` — the
  benchmarked review pair (see `docs/benchmark/results.md`).
- Skills: `skills/supervise/`, `skills/wrap/`.
- All hooks, including `core/hooks/tdd-guard.py` — unrelated to the `tdd`
  skill above; it continues to run unchanged.
- The Codex/Gemini adapters in `adapters/` — unrelated to `codex-skills/`.

## Recovery procedure

To restore any item:

1. `git mv legacy/trim-2026-07-04/agents/<name>.md agents/` (or the
   equivalent path for a skill under `legacy/trim-2026-07-04/skills/`, or
   `git mv legacy/trim-2026-07-04/codex-skills codex-skills`).
2. For an agent: re-add its entry to `agents/master-registry.json` (the CI
   drift guard requires every registry entry to have a matching
   `agents/<id>.md` with the same `model:` frontmatter value).
3. For `codex-skills/`: restore the symlink-install block in `setup.sh`
   (`install_codex()`) and the `codex-skills/*` pattern in the scope glob
   of `core/git-hooks/post-commit`.
4. Re-add the item to the relevant catalog tables (`README.md`,
   `README.ko.md`, `skills/README.md`, `templates/CLAUDE.md.template`,
   `docs/`) and bump the counts back up.
5. Run `bash core/tests/sanitize-audit.sh` and the CI `validate-plugin`
   check before committing.
