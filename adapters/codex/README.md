# Codex CLI Adapter

Bridge for [OpenAI Codex CLI](https://github.com/openai/codex).

## How it works

Codex CLI (measured 2026-09-27 on 0.157.0) exposes native hooks, and this is
the shipped enforcement path — no compatibility wrapper is required:

1. Codex loads hook config from `~/.codex/hooks.json`, `~/.codex/config.toml`,
   or a trusted project's `.codex/`, and (for a plugin install) the plugin's
   own `hooks/codex-hooks.json`.
2. For each matching event, Codex runs the hook and pipes it Claude-shaped
   stdin (`hook_event_name`, `tool_name`, `tool_input`, `tool_use_id`,
   `session_id`, `cwd`, `transcript_path`, `model`, `turn_id`).
3. `adapter.sh --run <hook>` (invoked from the hooks file) hands that stdin to
   `adapter.py`'s native mode, which runs the named core hook
   (`pre-tool-guard.sh`, `r4-mutex-check.sh`, …) and translates the result.
4. `apply_patch` carries the patch **text** in `tool_input.command` (the same
   field Bash uses). The adapter parses it into one canonical `Write`
   (Add File, and the destination of a `Move to`) or `Edit` (Update/Delete
   File) event per file, with absolute paths resolved from `cwd`, runs the
   hook once per file, and aggregates deny > ask > advisory > allow across
   them. A patch with no recognizable file operation is denied fail-closed.
5. On `PreToolUse`, a canonical `ask` — and any hook failure (non-zero exit
   other than `2`, a timeout, or unparseable output) — becomes an explicit
   `deny` JSON on stdout (exit `0`): Codex itself only supports `allow`/`deny`
   from a hook and **continues the tool call** on an unsupported `ask` or a
   failed hook, so the adapter must not let either through unchanged. Other
   events (`PostToolUse`, `SessionStart`, `Stop`, …) stay fail-open by design:
   an adapter or hook error there is warned on stderr and dropped rather than
   blocking an observation.
6. Codex runs a hook only after you review and trust it with `/hooks` in a
   Codex session (trust is tracked per hook hash; a changed hook needs
   re-review). `[features] hooks = false` disables all hooks, and
   project-local `.codex/` hooks load only in a trusted project.

This is the same deterministic core policy as Claude Code, for the same
matchers (`Bash`, `apply_patch`, `mcp__server__tool`). Beyond the fixtures, this was
live-verified 2026-09-27 on codex-cli 0.157.0: one `codex exec` session with these
hooks as a project-local `.codex/hooks.json` denied a Bash read of a `secrets/` file and
an `apply_patch` that wrote code reading one, allowed a clean `apply_patch`, and reported
the tool names `Bash` and `apply_patch` (patch text in `tool_input.command`).
MCP tool calls are fixture-tested only.

Decision-mapping detail: [`docs/ai-adapters.md`](../../docs/ai-adapters.md#codex).
Design background:
[`docs/cross-runtime-harness-design.md`](../../docs/cross-runtime-harness-design.md).

## Files

| File | Purpose |
|---|---|
| `adapter.sh`               | Hook invoker (native, synthetic, or legacy stdin mode). |
| `adapter.py`               | Translator + native-mode runner: Codex envelope/hook stdin → canonical event(s), runs the core hook. |
| `hooks.json.template`      | Source of truth for Agent's Codex hook wiring; rendered into `~/.codex/hooks.json`. |
| `merge-hooks.py`           | Merges the rendered template into an existing `hooks.json` without touching other tools' entries. |
| `codex-config.toml.template` | `~/.codex/config.toml` template (sandbox + brain MCP; hooks live in `hooks.json`). |
| `quick.config.toml.template` | LOW-tier profile, installed beside `config.toml` as `quick.config.toml`. |
| `deep.config.toml.template` | TOP-tier profile, installed beside `config.toml` as `deep.config.toml`. |
| `AGENTS.md.template`       | Project-level instructions Codex reads. |

`legacy/codex-shell-wrap/codex-shell-wrap.sh` is the retired compatibility
wrapper — see [Limitations](#limitations) for when it still applies.

## Install

```bash
# 1. Clone framework
git clone https://github.com/joymin5655/Agent.git ~/Agent

# 2. Render the baseline config (merge for an existing one)
cp ~/Agent/adapters/codex/codex-config.toml.template /tmp/codex-config.toml
sed -i.bak "s|{{FRAMEWORK_ROOT}}|$HOME/Agent|g" /tmp/codex-config.toml
mv /tmp/codex-config.toml ~/.codex/config.toml

# 3. Merge Agent's native hooks into ~/.codex/hooks.json (keeps other tools' entries)
python3 ~/Agent/adapters/codex/merge-hooks.py \
  ~/Agent/adapters/codex/hooks.json.template ~/Agent ~/.codex/hooks.json

# 4. Drop AGENTS.md into each repo where you use Codex
cp ~/Agent/adapters/codex/AGENTS.md.template /your/repo/AGENTS.md
```

`setup.sh --codex` runs steps 2-4 for you (via `merge-hooks.py`) and asks
before replacing a differing file. For policy updates alone use
`setup.sh --instructions-only`, which preserves personal text. The full Codex
install also installs the `quick`/`deep` tier profiles (`docs/model-routing.md`)
beside `~/.codex/config.toml` — invoke them with `codex --profile quick` or
`codex --profile deep`.

**After installing, start a Codex session and review the new/changed hooks
with `/hooks`.** Codex does not enforce a hook until you trust it there —
installing `hooks.json` alone changes nothing.

**Plugin alternative:** `codex plugin marketplace add joymin5655/Agent` then
`codex plugin add agent-harness@agent` installs the same hooks (via the root
`plugin.json` → `hooks/codex-hooks.json`) plus the framework's skills. Do not
run both the `setup.sh --codex`-installed `~/.codex/hooks.json` entries and
the plugin at the same time — each fires independently, so every gate would
run twice.

Do not overwrite an existing `config.toml` or `hooks.json` wholesale; preserve
other tools' providers, permissions, plugins, and hook entries.

### Codex CLI itself

If the `codex` CLI isn't installed yet: `npm install -g @openai/codex`
(universal), `brew install --cask codex` (macOS), or
`curl -fsSL https://chatgpt.com/codex/install.sh | sh`. Auth is a browser
login flow: `codex login`. `codex login status` is the auth-aware health
probe — measured 2026-08-20 on codex 0.147.0: logged out exits 1 and prints
"Not logged in"; logged in exits 0. It is a local check (reads cached auth
state, no network call) and not billable, which is why
`core/infra/backends.json` uses it as the codex backend's `preflight`
instead of `codex --version` (which says nothing about auth).

## Test

```bash
# Synthetic deny — Codex tries to read secrets/
./adapter.sh pre-tool-guard.sh --tool Bash --command "cat secrets/foo.env"
# Expected: JSON with permissionDecision="deny"

# Native-mode deny — the same command as a native PreToolUse hook stdin
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash",
       "tool_input":{"command":"cat secrets/foo.env"},"cwd":"'"$PWD"'"}' \
  | ./adapter.sh pre-tool-guard.sh
# Expected: JSON with permissionDecision="deny"
```

`core/tests/codex-native-hooks-test.sh` is the full native-mode battery (41
checks: fail-closed `ask`/hook-failure handling, `apply_patch` per-file
splitting, MCP pass-through, fail-open observation events, and hooks.json /
plugin hooks file wiring). `adapters/codex/tests/run.sh` covers the translator
plus the legacy wrapper (T5/T6 — kept so that fallback path does not rot); the
wrapper itself now lives at `legacy/codex-shell-wrap/codex-shell-wrap.sh`.

## Limitations

- **MCP coverage is fixture-tested only.** Bash and `apply_patch` were checked in
  a live `codex exec` session; an MCP tool call through the hooks was not.
- **`setup.sh --doctor` doesn't yet distinguish a plugin install.** It checks
  the `setup.sh --codex` merge target (`~/.codex/hooks.json`) for a trust
  record; a plugin-only install isn't separately detected.
- **The legacy shell wrapper** (`legacy/codex-shell-wrap/codex-shell-wrap.sh`)
  is a fallback only for `[features] hooks = false` builds or an admin
  `requirements.toml` that allows managed hooks only. It gates shell commands
  only (`apply_patch` and MCP tools bypass it) and maps a canonical `ask` to a
  block (exit 100) instead of the native adapter's `deny` JSON. See
  `legacy/codex-shell-wrap/README.md`.
