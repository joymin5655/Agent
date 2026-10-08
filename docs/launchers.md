# Purpose launchers — session-start model allocation

The launcher set in `adapters/claude-code/launchers/` is the harness's answer
to "pick the model for the purpose, automatically" without crossing the line
`docs/model-routing.md` § What this policy deliberately does not do draws:
no classifier, no hook, no runtime switch. A launcher presets the model
BEFORE the session exists — the human's choice of entry point IS the
allocation decision, made once, visible, and auditable.

| Launcher | Rung | What it presets | Harness |
|---|---|---|---|
| `claude-build` | TOP | nothing (session default model) — exists so the set is self-documenting; pass `--effort high` yourself for a harder TOP-rung session, not forced here since this rung's point is "no opinion beyond the default" | full |
| `claude-quick` | LOW | `--model haiku` — mechanical work, lookups, cleanup | full |
| `claude-research` | MID | `--model sonnet --effort medium` — reading, research, routine implementation; effort is pinned alongside the model so the rung doesn't silently drift with a session default | full |

Rules of the set:

- **Launchers keep the full harness** (hooks, skills, MCP, memory); only the
  model changes.
- **Escalation stays explicit.** Inside any session, per-dispatch `model`
  overrides and the effort dial still apply (`docs/model-routing.md` — effort
  before tier-up). The launcher sets the session's center of gravity, not a
  ceiling.
- **Deploy**: `setup.sh --launchers` symlinks the launchers into `~/bin`.

Adding a launcher: it must map to a rung already documented in
`docs/model-routing.md`, and its README row here plus
`adapters/claude-code/launchers/README.md` must agree —
`core/tests/doc-reality` conventions apply.

`claude-ox` (Claude Code routed through the OpenRouter gateway) was retired
2026-10-08 with that lane; see `legacy/lanes-2026-10/README.md`.

See also: [`concepts/fable-5-prompting.md`](concepts/fable-5-prompting.md) —
what changes about the dispatch prompts these launchers' sessions write,
once the model behind a rung is Fable 5.1 class.
