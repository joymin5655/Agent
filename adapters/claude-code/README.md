# Claude Code Adapter

Thin pass-through adapter for [Claude Code](https://claude.com/claude-code).

## Why so thin?

Claude Code's native hook protocol (stdin event JSON + stdout decision JSON)
**is** the canonical protocol that this framework was designed around. The
adapter exists only to:

1. Resolve `<hook-name>` → `core/hooks/<hook-name>` absolute path.
2. Exec the hook with stdin/stdout/stderr/exit-code untouched.
3. Silently no-op if the hook file is missing (never block Claude Code on
   infra glitches — only block on actual policy violations).

## Install

```bash
# 1. Clone framework somewhere stable, e.g.
git clone https://github.com/joymin5655/Agent.git ~/Agent

# 2. Copy the template + replace placeholder
cp ~/Agent/adapters/claude-code/settings.json.template /tmp/claude-settings.json
sed -i.bak "s|{{FRAMEWORK_ROOT}}|$HOME/Agent|g" /tmp/claude-settings.json
rm /tmp/claude-settings.json.bak

# 3. Merge into ~/.claude/settings.json
#    (or copy directly if you have no existing config)
```

Or run `setup.sh --claude` from the repo root, which automates the above.

## Test

```bash
# Synthetic deny event — secrets/ Bash access
echo '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat secrets/foo.env"}}' \
  | ./adapter.sh pre-tool-guard.sh

# Expected stdout JSON: permissionDecision="deny"
```

See `tests/` for the full smoke-test suite.

## Hook coverage

The `settings.json.template` wires up:

| Event | Matcher | Hook |
|---|---|---|
| SessionStart | `*` | `agent-session-start.sh`, `session-init.py` |
| Stop | `*` | `session-quality-gate.py`, `brain-capture.py`, `session-close.sh` |
| UserPromptSubmit | `*` | `agent-session-heartbeat.sh`, `plan-gate.py` |
| PreToolUse | `Bash` | `pre-tool-guard.sh` |
| PreToolUse | `*` | `r4-mutex-check.sh`, `context-mode-guard.sh` |
| PreToolUse | `Write\|Edit\|MultiEdit` | `check-hardcoding.py`, `secret-content-scan.py`, `r4-file-mutex-check.sh`, `tdd-guard.py`, `supervisor.py` |
| PostToolUse | `Bash` | `circuit-breaker.py` |
| PostToolUse | `Write\|Edit\|MultiEdit` | `r4-file-mutex-register.sh` |

Adapt per-project by editing `hook-config.yml` (paths, risk areas, exempt
globs) — the core hooks read it.
