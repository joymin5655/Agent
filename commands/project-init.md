---
description: >-
  Scaffold runtime instructions, hook policy, secret scanning, and Git-hook
  wiring. Agents, skills, and runtime hooks come from the plugin.
argument-hint: "[--dry-run]"
allowed-tools: Bash(bash:*), Bash(test:*), Bash(ls:*), Read, Edit
---

# Project init

Initialize the **current repository** with the agent-harness project scaffold.

The plugin already provides agents, skills, and runtime hooks. This command adds
the project-level files and Git-hook wiring that `setup.sh --project` currently
implements.

## Steps

1. **Confirm scope** with the user: project scaffold only (default), or also (re)install the
   global Claude Code setup. Most users want project-only here.

2. **Run the project scaffold** from the repo root. A byte-identical file is
   unchanged; a differing destination prompts before replacement. The script
   never touches `.env*` or `secrets/`:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/setup.sh" --project
   ```

   Templates applied from `${CLAUDE_PLUGIN_ROOT}/templates/`:
   `CLAUDE.md.template`, `AGENTS.md.template`, `GEMINI.md.template`,
   `hook-config.yml.template`, and `gitleaks.toml.template`.

   The setup also creates `.git-hooks-framework`, points it at the plugin
   cache's `core/git-hooks`, and sets the repository's local
   `core.hooksPath`.

3. **Customize** the generated files for this project — read the new `CLAUDE.md` and
   `hook-config.yml`, then ask the user which project risk areas (production DB, deploy,
   payments, etc.) and which agents/keywords to enable.

4. **Verify** no secret files were scaffolded and inspect the Git-hook wiring:

   ```bash
   test ! -f .claude/settings.local.json
   git config --local --get core.hooksPath
   ls -l .git-hooks-framework
   ```

5. **Summarize** what was created, what was skipped (already existed), and the next
   verification commands (`gitleaks detect`, hook smoke test).

If `--dry-run` was passed, show what *would* be created without running `setup.sh`.
