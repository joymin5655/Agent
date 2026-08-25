# Purpose Launchers — session-start rung entry points

Four thin wrappers around `claude`, each naming a session-start human
allocation decision instead of leaving it to a bare `claude --model X`
invocation typed from memory.

| Launcher | Rung | What it runs |
|---|---|---|
| `claude-build` | TOP | `claude` unchanged — full harness, default model selection. Exists for set symmetry: every rung gets a name, even the plain one. |
| `claude-quick` | LOW | `claude --model haiku` — mechanical/routine work. |
| `claude-research` | MID | `claude --model sonnet` — general implementation/investigation work. |
| `claude-ox` | gateway | `claude` routed through the OpenRouter gateway (`ANTHROPIC_BASE_URL` override), isolated config dir, sensitive-cwd guarded. See `claude-ox.template` and `adapters/openrouter/README.md`. |

## Policy note

Choosing a launcher at the start of a session is a **human, visible,
auditable decision** — exactly the side of the line
`docs/model-routing.md` § *What this policy deliberately does not do*
allows: "no runtime model-switching hooks", "no automatic tier escalation".
A launcher is not a classifier or a switch; it is a named door a person
walks through once, at the top of a session. Nothing in this directory picks
a model per-prompt or overrides that choice mid-session.

`claude-build`/`claude-quick`/`claude-research` all keep the full harness
(hooks, skills, plugin config) — only the model changes. `claude-ox` is the
one exception: it isolates `CLAUDE_CONFIG_DIR` and strips MCP servers by
default (see the template's own comments for why — the harness's system
prompt alone exceeds the OpenRouter gateway's usable context without a
prompt cache), so an ox session runs bare Claude Code, not the harness.

## Installation

```bash
ln -sf "$PWD/adapters/claude-code/launchers/claude-build"    ~/bin/claude-build
ln -sf "$PWD/adapters/claude-code/launchers/claude-quick"    ~/bin/claude-quick
ln -sf "$PWD/adapters/claude-code/launchers/claude-research" ~/bin/claude-research
# claude-ox is rendered (copy-if-absent, drift-confirmed on redeploy), not symlinked —
# it is meant to be edited locally (OX_MODEL, etc.):
```

(or `setup.sh --launchers`, which does all four — the first three via
`ln -sf`, `claude-ox` via `setup.sh`'s existing `apply_template` helper, the
same copy-if-absent / drift-confirm pattern used for `CLAUDE.md`,
`settings.json`, and the codex config templates.)

`claude-ox` additionally needs an OpenRouter API key in the macOS Keychain
and the shared sensitive-cwd guard file — both covered by
`setup.sh --openrouter` (see `adapters/openrouter/README.md`).
