# Legacy: Codex shell wrapper

`codex-shell-wrap.sh` was the Codex enforcement path before Codex CLI shipped native
hooks. It gates **shell commands only** and must be invoked explicitly (on PATH as
`codex-bash`); `apply_patch` file edits and MCP tools bypass it.

The supported path is now Codex native hooks — `setup.sh --codex` merges
`adapters/codex/hooks.json.template` into `~/.codex/hooks.json` (see
`adapters/codex/README.md`).

Use this wrapper only when native hooks are disabled (`[features] hooks = false` in
`~/.codex/config.toml`, or an admin `requirements.toml` that allows managed hooks only).
It maps a canonical `ask` to a block (exit 100). `adapters/codex/tests/run.sh` still
exercises it (T5/T6) so the fallback does not rot.
