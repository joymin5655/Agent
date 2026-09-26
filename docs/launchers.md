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
| `claude-ox` | free/gateway | OpenRouter gateway (Keychain key, `OX_MODEL`, isolated `~/.claude-ox` config, empty MCP, `--permission-mode manual`) | isolated |

Rules of the set:

- **Tier launchers keep the full harness** (hooks, skills, MCP, memory).
  Only the gateway launcher isolates its config — measured necessity, not
  style: the full harness prompt (~950k chars of config surface) caused
  0-byte timeouts against an uncached OpenRouter gateway; isolation brought
  a probe to ~23k tokens (`claude-ox.template` header).
- **Sensitive paths are shared and local.** The gateway launcher and the
  openrouter worker lane read the same `~/.config/agent-harness/sensitive-paths`
  file (one path per line, installed from
  `adapters/openrouter/sensitive-paths.template` with generic defaults);
  personal entries are added locally and never committed.
- **Escalation stays explicit.** Inside any session, per-dispatch `model`
  overrides and the effort dial still apply (`docs/model-routing.md` — effort
  before tier-up). The launcher sets the session's center of gravity, not a
  ceiling.
- **`claude-ox` runs `--permission-mode manual`, not the harness's usual
  posture.** The gateway isolates `CLAUDE_CONFIG_DIR` (see below), which drops
  the harness's own deny rules and pre-tool hooks for that session — a
  third-party provider reached this way should not also inherit whatever
  looser permission mode the caller's own environment defaults to, so the
  launcher pins the native default explicitly instead of trusting an ambient
  setting.
- **Deploy**: `setup.sh --launchers` symlinks the tier launchers into
  `~/bin` and renders `claude-ox` copy-if-absent with a drift warning
  (a user-modified `~/bin/claude-ox` is never silently clobbered).

Adding a launcher: it must map to a rung (or a gateway) already documented in
`docs/model-routing.md`, and its README row here plus
`adapters/claude-code/launchers/README.md` must agree —
`core/tests/doc-reality` conventions apply.

See also: [`concepts/fable-5-prompting.md`](concepts/fable-5-prompting.md) —
what changes about the dispatch prompts these launchers' sessions write,
once the model behind a rung is Fable 5.1 class.
