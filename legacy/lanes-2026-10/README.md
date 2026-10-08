# Legacy: grok, kiro and openrouter worker lanes, claude-ox launcher (retired 2026-10-08)

The harness now ships three vendor lanes: Claude Code (host), Codex (openai) and Gemini through
the Antigravity CLI `agy` (google). These lanes were retired by the maintainer's decision on
2026-10-08:

| Path | What it was | Why retired |
|---|---|---|
| `grok/` | xAI advisor lane (`advisor-third`, `/council-review --with-grok`) | Advisory only, billed per call. The CLI's own flags never enforced read-only, so the worker relied on `sandbox-exec`, and that table was measured on 0.2.118 only. |
| `kiro/` | Kiro gateway lanes (`kiro-openai`, `kiro-zhipu`, `kiro-anthropic`) | Wired to no role since the 2026-08-25 roster change; CLI not in use. |
| `openrouter/` | OpenRouter free-tier advisor (`advisor-free`, `--with-free`) | Advisory only; sends the diff to a third party. |
| `launchers/claude-ox.template` | Claude Code routed through the OpenRouter gateway | Depends on OpenRouter. |
| `tests/` | The three lane test batteries | Retired with their adapters; no longer run by `verify-all.sh`. |

None of these lanes held a council or gate vote, so review and gate outcomes are unchanged. The
files are kept for reference only: no `setup.sh` flag, `core/infra/backends.json` entry or skill
uses them; a few docs and code comments point here as history. To bring a lane back, restore its
directory under `adapters/`, its backend and role in `core/infra/backends.json`, its `setup.sh`
flag and doctor checks, and its runtime entry in `docs/runtime-registry.json` (see the removal
PR for the exact hunks).
