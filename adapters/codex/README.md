# Codex CLI Adapter

Bridge for [OpenAI Codex CLI](https://github.com/openai/codex).

## How it works

Codex CLI does not currently expose a native PreToolUse hook API the way
Claude Code does. This adapter therefore enforces gates **at the tool-call
boundary** by wrapping the shell tool with a script that:

1. Receives the shell command Codex wants to run.
2. Synthesises a canonical PreToolUse event JSON.
3. Pipes the event through the framework's core hooks
   (`pre-tool-guard.sh`, `r4-mutex-check.sh`, …).
4. **Blocks** the command (exit 100) if any hook returns
   `permissionDecision = "deny"` or `"ask"`.
5. Executes the original command via `bash -lc` on allow.

This is the same security posture as Claude Code's PreToolUse — the only
difference is that the enforcement is via a wrapper rather than a runtime
hook subscription.

## Files

| File | Purpose |
|---|---|
| `adapter.sh`               | Hook invoker (synthetic-mode or stdin-mode). |
| `adapter.py`               | Translator: Codex envelope → canonical event JSON. |
| `codex-shell-wrap.sh`      | Drop-in replacement for Codex's `bash` tool. |
| `codex-config.toml.template` | `~/.codex/config.toml` template. |
| `AGENTS.md.template`       | Project-level instructions Codex reads. |

## Install

```bash
# 1. Clone framework
git clone https://github.com/joymin5655/Agent.git ~/Agent

# 2. Put the wrapper on PATH
mkdir -p ~/bin
ln -sf ~/Agent/adapters/codex/codex-shell-wrap.sh ~/bin/codex-bash

# 3. Configure Codex to use the wrapper
cp ~/Agent/adapters/codex/codex-config.toml.template /tmp/codex-config.toml
sed -i.bak "s|{{FRAMEWORK_ROOT}}|$HOME/Agent|g" /tmp/codex-config.toml
mv /tmp/codex-config.toml ~/.codex/config.toml

# 4. Drop AGENTS.md into each repo where you use Codex
cp ~/Agent/adapters/codex/AGENTS.md.template /your/repo/AGENTS.md
```

Or run `setup.sh --codex` from the repo root, which automates the above.

## Test

```bash
# Synthetic deny — Codex tries to read secrets/
./adapter.sh pre-tool-guard.sh --tool Bash --command "cat secrets/foo.env"
# Expected: JSON with permissionDecision="deny"

# Wrapper simulation
./codex-shell-wrap.sh -lc "cat secrets/foo.env"
# Expected: stderr "[codex-shell-wrap] BLOCKED ..." and exit 100
```

See `tests/run.sh` for the full smoke-test suite.

## Limitations

- **No PostToolUse equivalent.** Codex doesn't expose post-execution hooks
  via the shell tool wrapper. Logging hooks (circuit-breaker, broadcast)
  must run via cron or wrapper subshells.
- **Session lifecycle hooks** are simulated by `core/infra/codex-session.sh`
  (start/heartbeat/stop wrapper around the `codex` binary).
- **File-write tools** (apply_patch, file_write) are not yet intercepted by
  this version of the wrapper — track the upstream Codex tool schema for
  changes and extend `codex-shell-wrap.sh` similarly.
