# Legacy: grok, kiro, openrouter and Gemini CLI adapters, claude-ox launcher (retired 2026-10)

The harness now ships three vendor lanes: Claude Code (host), Codex (openai) and Gemini through
the Antigravity CLI `agy` (google). These were retired by the maintainer's decision: the first
four rows on 2026-10-08, the direct Gemini CLI adapter on 2026-10-09:

| Path | What it was | Why retired |
|---|---|---|
| `grok/` | xAI advisor lane (`advisor-third`, `/council-review --with-grok`) | Advisory only, billed per call. The CLI's own flags never enforced read-only, so the worker relied on `sandbox-exec`, and that table was measured on 0.2.118 only. |
| `kiro/` | Kiro gateway lanes (`kiro-openai`, `kiro-zhipu`, `kiro-anthropic`) | Wired to no role since the 2026-08-25 roster change; CLI not in use. |
| `openrouter/` | OpenRouter free-tier advisor (`advisor-free`, `--with-free`) | Advisory only; sends the diff to a third party. |
| `launchers/claude-ox.template` | Claude Code routed through the OpenRouter gateway | Depends on OpenRouter. |
| `gemini/` | Direct Gemini CLI adapter: shell wrap, hook translator, `gemini-worker`/`gemini-preflight` lane, settings and tiers templates, `gemini-session.sh` (`setup.sh --gemini`) | Individual access ended upstream 2026-06-18 and the google lane runs through Antigravity (`adapters/antigravity/`), so only enterprise, Google Cloud and paid API-key users still benefited. |
| `tests/` | The lane test batteries (grok, kiro, openrouter, gemini preflight) | Retired with their adapters; no longer run by `verify-all.sh`. |

None of these lanes held a council or gate vote, so review and gate outcomes are unchanged (the
live `gemini` backend in `core/infra/backends.json` dispatches through `antigravity-worker`, not
through `gemini/`). The files are kept for reference only: no `setup.sh` flag,
`core/infra/backends.json` entry or skill uses them; a few docs and code comments point here as
history. To bring a lane back, restore its directory under `adapters/`, its backend and role in
`core/infra/backends.json`, its `setup.sh` flag and doctor checks, and its runtime entry in
`docs/runtime-registry.json` (see the removal PR for the exact hunks). For `gemini/` that also
means `core/infra/gemini-session.sh`, `core/tests/gemini-preflight-test.sh` and the `gemini-cli`
registry entry.
