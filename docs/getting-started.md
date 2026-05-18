# Getting Started

5-minute install for the most common scenarios.

---

## Prerequisites

- `git` 2.30+
- `bash` 5.0+ (macOS 12+, any modern Linux)
- One of: Claude Code CLI / Codex CLI / Gemini CLI installed
- Optional: `gitleaks` 8+ (`brew install gitleaks` or download from releases)
- Optional: `gh` 2.0+ (for repo operations)

---

## 1. Install the framework

```bash
gh repo clone joymin5655/Agent ~/agent
# or
git clone https://github.com/joymin5655/Agent ~/agent
```

---

## 2. Configure your AI runtime(s)

### All 3 AIs at once

```bash
bash ~/agent/setup.sh
```

This installs adapter configs to:
- `~/.claude/settings.json` (Claude Code)
- `~/.codex/config.toml` (Codex CLI)
- `~/.gemini/settings.json` (Gemini CLI)

Existing configs are merged. Use `--force` to overwrite.

### Selective

```bash
bash ~/agent/setup.sh --claude
bash ~/agent/setup.sh --codex
bash ~/agent/setup.sh --gemini
```

### Hooks-only (no AI config, just git-hooks)

```bash
bash ~/agent/setup.sh --hooks-only
```

Useful if you only want secret-scan + check-staged in pre-commit/pre-push.

---

## 3. Verify install

```bash
# Hook protocol smoke test
bash ~/agent/core/tests/adapter-smoke/claude-code/run.sh
bash ~/agent/core/tests/adapter-smoke/codex/run.sh
bash ~/agent/core/tests/adapter-smoke/gemini/run.sh

# Each should print: "PASS — 4/4 cases"
```

---

## 4. Adopt into a project

```bash
cd /path/to/your/project
bash ~/agent/setup.sh --project
```

This scaffolds (skipping any existing files):

- `CLAUDE.md` — Claude Code instructions for your project
- `AGENTS.md` — generic AI instructions
- `GEMINI.md` — Gemini CLI instructions
- `gitleaks.toml` — secret scanner config (extending the base)
- `.claude/rules/` — generic policy docs
- `hook-config.yml` — YOUR risk areas, resources, policy patterns
- `.gitignore` additions — runtime state exclusions
- `.git/hooks/pre-commit` and `pre-push` — gitleaks + diff scan

After scaffolding:

1. Review `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` — fill in project-specific sections.
2. Edit `hook-config.yml` — define what counts as a risk area in your project.
3. Commit.

---

## 5. Verify the project install

```bash
cd /path/to/your/project

# gitleaks scan
gitleaks detect --no-git --source . --config gitleaks.toml

# Try a commit — should be blocked if it touches secrets
echo "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" > test.env
git add test.env
git commit -m "test"  # should be blocked by pre-commit hook
rm test.env
```

---

## 6. Run an AI session

### Claude Code

```bash
cd /path/to/your/project
claude
# Now Claude reads CLAUDE.md + applies hooks
```

### Codex CLI

```bash
cd /path/to/your/project
codex
# Reads AGENTS.md + applies hooks
```

### Gemini CLI

```bash
cd /path/to/your/project
gemini
# Reads GEMINI.md + applies hooks
```

When the AI tries something blocked by a hook (e.g., reading `secrets/`), you'll see:

```
🚫 Tool blocked: Direct secrets/ access blocked. Use environment variable.
```

---

## 7. Multi-session coordination

If you're running multiple AI sessions simultaneously, start each with:

```bash
bash ~/agent/core/infra/agent-session.sh start <task-slug>
```

To see what other sessions are active:

```bash
bash ~/agent/core/infra/agent-session.sh dashboard
```

To stop a session cleanly:

```bash
bash ~/agent/core/infra/agent-session.sh stop
```

See [`concepts/multi-session-worktree.md`](concepts/multi-session-worktree.md) for the full R1-R14 protocol.

---

## Next steps

- [`customization.md`](customization.md) — define your risk areas + resources
- [`hook-protocol.md`](hook-protocol.md) — write your own custom hooks
- [`architecture.md`](architecture.md) — understand the layer model
- [`../rules/`](../rules/) — read the policy docs

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `gitleaks: command not found` | `brew install gitleaks` (macOS) or download from https://github.com/gitleaks/gitleaks/releases |
| `Hooks not firing in Claude Code` | Check `~/.claude/settings.json` contains the `adapter.sh` registration. Restart Claude Code. |
| `permission denied` on `setup.sh` | `chmod +x ~/agent/setup.sh` |
| `command not found: claude/codex/gemini` | Install the AI's CLI first — this framework is the policy layer, not the AI itself. |
| Hook returns empty stdout but I expect a decision | That's correct — empty stdout = `allow`. See [`hook-protocol.md`](hook-protocol.md) § 3. |
