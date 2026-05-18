---
description: Bootstrap a new project with Karpathy global setup + .claude/ scaffold from joymin5655/Agent.git
---

# /project-init

Claude-invocable bootstrap. Drops the Karpathy 4-principle global setup into `~/.claude/` and (optionally) scaffolds `.claude/rules/`, `CLAUDE.md`, and `gitleaks.toml` in the current project.

## Installation

Copy this file to `~/.claude/commands/project-init.md`:

```bash
mkdir -p ~/.claude/commands
cp ~/agent/claude/commands/project-init.md ~/.claude/commands/project-init.md
```

After install, `/project-init` is available in any Claude Code session.

## Behavior

When the user invokes `/project-init`:

1. **Verify Agent.git checkout** — clone to `~/agent` if absent:
   ```bash
   [ -d ~/agent ] || gh repo clone joymin5655/Agent ~/agent
   git -C ~/agent pull --ff-only
   ```

2. **Confirm scope with the user** via `AskUserQuestion`:
   - Global only (`~/.claude/` Karpathy setup)
   - Global + project scaffold (current project root)
   - Cancel

3. **Run setup.sh** based on choice:
   ```bash
   bash ~/agent/setup.sh           # global only
   bash ~/agent/setup.sh --project # global + project scaffold
   ```

4. **Verify**:
   - `cat ~/.claude/CLAUDE.md` — should show `@RTK.md` + `@karpathy.md`
   - If `--project`: list `.claude/rules/` and remind user that AirLens-specific paths (`Obsidian-airlens/...`, `apps/web/...`) need adaptation.

5. **Report next steps** — point to `claude/global/README.md` for the 8-layer inheritance doc and project-level override pattern.

## Safety

- Never overwrite existing `~/.claude/CLAUDE.md`, project `CLAUDE.md`, or `gitleaks.toml` — `setup.sh` is idempotent and skips existing files unless `--force`.
- Never touches `.env*`, `secrets/`, or runtime state (`.claude/locks/`, `.claude/logs/`).
- Surface AirLens-specific path references after copy so the user can adapt them.

## Why a slash command instead of an auto-hook

Auto-bootstrap on every `SessionStart` is risky — it would fire in sandbox projects, worktrees, and unrelated repos. A user-invoked slash command keeps the action explicit and reversible (per Karpathy §3 Surgical Changes).
