# Codex Skills

Skills for [Codex CLI](https://github.com/openai/codex), organised in the
`~/.codex/skills/<name>/SKILL.md` layout that Codex's skill loader expects.

## Install

Either:

```bash
ln -sf /path/to/Agent/codex-skills ~/.codex/skills
```

Or copy specific ones:

```bash
cp -r /path/to/Agent/codex-skills/code-explorer ~/.codex/skills/
```

`setup.sh --codex` automates the symlink approach.

## Included

| Skill | Purpose |
|---|---|
| `code-explorer` | Survey codebase structure before making changes. |
| `code-reviewer` | Independent diff review with severity buckets. |
| `database-reviewer` | SQL / schema / migration / RLS review. |
| `planner` | Plan-mode for non-trivial multi-file work. |

These are Codex-native versions of the agents under `agents/`. The
behavior is the same; the format is what Codex expects.
