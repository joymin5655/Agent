---
description: Scaffold the current project with agent-harness project-level files (CLAUDE.md, project rules, gitleaks config, hook-config). Agents/skills/hooks already come from the installed plugin.
argument-hint: "[--dry-run]"
allowed-tools: Bash(bash:*), Bash(test:*), Bash(ls:*), Read, Edit
---

# /project-init

Initialize the **current repository** with the agent-harness project scaffold.

The plugin already provides agents, skills, and hooks globally (you installed it via
`/plugin install`). This command drops the *project-level* files that the harness expects:
a root `CLAUDE.md`, `.claude/rules/` policy docs, a `gitleaks.toml`, and `.gitignore`
additions — using the templates bundled with the plugin.

## Steps

1. **Confirm scope** with the user: project scaffold only (default), or also (re)install the
   global Claude Code setup. Most users want project-only here.

2. **Run the project scaffold** from the repo root (idempotent — existing files are skipped;
   it never touches `.env*`, `secrets/`, or local state):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/setup.sh" --project
   ```

   Templates applied (from `${CLAUDE_PLUGIN_ROOT}/templates/`):
   `CLAUDE.md.template` · `project-rules.md.template` · `gitleaks.toml.template` ·
   `hook-config.yml.template` (+ `AGENTS.md`/`GEMINI.md` if the user also uses Codex/Gemini).

3. **Customize** the generated files for this project — read the new `CLAUDE.md` and
   `hook-config.yml`, then ask the user which project risk areas (production DB, deploy,
   payments, etc.) and which agents/keywords to enable.

4. **Verify** no local-only or secret files were scaffolded:

   ```bash
   test ! -f .claude/settings.local.json && test ! -d .claude/logs && test ! -d .claude/locks && echo "clean"
   ```

5. **Summarize** what was created, what was skipped (already existed), and the next
   verification commands (`gitleaks detect`, hook smoke test).

If `--dry-run` was passed, show what *would* be created without running `setup.sh`.
