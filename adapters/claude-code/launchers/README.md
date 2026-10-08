# Purpose Launchers — session-start rung entry points

Three thin wrappers around `claude`, each naming a session-start human
allocation decision instead of leaving it to a bare `claude --model X`
invocation typed from memory.

| Launcher | Rung | What it runs |
|---|---|---|
| `claude-build` | TOP | `claude` unchanged — full harness, default model selection. Exists for set symmetry: every rung gets a name, even the plain one. Pass `--effort high` yourself for a harder session; not forced. |
| `claude-quick` | LOW | `claude --model haiku` — mechanical/routine work. |
| `claude-research` | MID | `claude --model sonnet --effort medium` — general implementation/investigation work. |

## Policy note

Choosing a launcher at the start of a session is a **human, visible,
auditable decision** — exactly the side of the line
`docs/model-routing.md` § *What this policy deliberately does not do*
allows: "no runtime model-switching hooks", "no automatic tier escalation".
A launcher is not a classifier or a switch; it is a named door a person
walks through once, at the top of a session. Nothing in this directory picks
a model per-prompt or overrides that choice mid-session.

All three launchers keep the full harness (hooks, skills, plugin config) —
only the model changes.

## Installation

```bash
ln -sf "$PWD/adapters/claude-code/launchers/claude-build"    ~/bin/claude-build
ln -sf "$PWD/adapters/claude-code/launchers/claude-quick"    ~/bin/claude-quick
ln -sf "$PWD/adapters/claude-code/launchers/claude-research" ~/bin/claude-research
```

(or `setup.sh --launchers`, which does the same three `ln -sf` links.)

The `claude-ox` launcher (Claude Code routed through the OpenRouter gateway) was retired
2026-10-08 with the OpenRouter lane; see `legacy/lanes-2026-10/README.md`.
