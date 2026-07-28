# Gemini CLI Adapter

Bridge for [Gemini CLI](https://github.com/google-gemini/gemini-cli).

## How it works

Current Gemini CLI releases expose native hooks and extensions, but Agent has
not wired that path yet. This compatibility adapter uses the `tools` block in
`~/.gemini/settings.json` to point the shell tool at an external executable.
It intercepts that shell route, normalises the arguments into a canonical
PreToolUse event, pipes through the core hooks, and **blocks** the call
(exit 100) on `permissionDecision = "deny"` or `"ask"`.

Architecturally identical to the Codex adapter — see that README for the
rationale.

The native Gemini extension and separate Antigravity plugin are specified in
[`docs/cross-runtime-harness-design.md`](../../docs/cross-runtime-harness-design.md).

## Files

| File | Purpose |
|---|---|
| `adapter.sh`               | Hook invoker (synthetic-mode or stdin-mode). |
| `adapter.py`               | Translator: Gemini envelope → canonical event JSON. |
| `gemini-shell-wrap.sh`     | Drop-in replacement for Gemini's shell tool. |
| `gemini-settings.json.template` | `~/.gemini/settings.json` template. |
| `GEMINI.md.template`       | Project-level instructions Gemini reads. |

## Install

```bash
# 1. Clone framework
git clone https://github.com/joymin5655/Agent.git ~/Agent

# 2. Put the wrapper on PATH
mkdir -p ~/bin
ln -sf ~/Agent/adapters/gemini/gemini-shell-wrap.sh ~/bin/gemini-bash

# 3. Configure Gemini to use the wrapper
cp ~/Agent/adapters/gemini/gemini-settings.json.template /tmp/gemini-settings.json
sed -i.bak "s|{{FRAMEWORK_ROOT}}|$HOME/Agent|g" /tmp/gemini-settings.json
mkdir -p ~/.gemini
mv /tmp/gemini-settings.json ~/.gemini/settings.json

# 4. Drop GEMINI.md into each repo
cp ~/Agent/adapters/gemini/GEMINI.md.template /your/repo/GEMINI.md
```

Or run `setup.sh --gemini` from the repo root.

## Test

```bash
# Synthetic deny — Gemini tries to read secrets/
./adapter.sh pre-tool-guard.sh --tool Bash --command "cat secrets/foo.env"
# Expected: JSON with permissionDecision="deny"

# Wrapper simulation
./gemini-shell-wrap.sh -lc "cat secrets/foo.env"
# Expected: stderr "[gemini-shell-wrap] BLOCKED ..." and exit 100
```

See `tests/run.sh` for the full smoke-test suite.

## Limitations

- **No PostToolUse in this wrapper path.** Upstream Gemini `AfterTool` exists,
  but Agent does not register it yet.
- **File-write tools** (`write_file`, `replace`) are not yet intercepted
  by `gemini-shell-wrap.sh` — only `run_shell_command` is. To gate file
  writes, configure Gemini's `tools.write_file` and `tools.replace` to
  invoke `adapter.sh` with `--tool Write` / `--tool Edit` and an exec
  block similar to the shell wrapper.
- **Session lifecycle hooks** are simulated by `core/infra/gemini-session.sh`.
