# Skills

Skills are user-invocable workflows (typically via slash-command). Each
skill is a single `SKILL.md` file under `skills/<name>/`.

## Format

```markdown
---
name: <skill-name>
description: <one-line, used for skill discovery>
when_to_use: <triggers>
tools: <comma-separated, optional>
---

# <skill-name>

<Skill body — what to do, in what order. The runtime reads this and
follows it as instructions to the AI.>
```

## Included skills

| Slash | Purpose |
|---|---|
| `/wrap` | Commit + PR creation with security guard checks. |
| `/supervise` | Multi-wave plan dispatch with audit + risk-area abort. |

## Adding a skill

1. Create `skills/<your-skill>/SKILL.md` with frontmatter + body.
2. Test in your AI runtime: ensure the slash-command resolves to it.
3. Document trigger keywords in your project's `CLAUDE.md` / `AGENTS.md` /
   `GEMINI.md`.

## Same-name resolution

When multiple sources define the same skill name (this framework + a
plug-in + a third-party skill bundle), the precedence is:

```
local in-place (skills/) > context-mode > superpowers > plug-in
```

Override per-project in `rules/policy/skill-adoption-comparison.md`.
