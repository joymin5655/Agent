# Master Agent Registry

The registry maps user-intent signals (keywords, file types, tool calls)
to specialist agents that should handle them. The orchestrator (`supervisor.py`
in `core/hooks/`) consults this registry to decide *which* agent to dispatch
for a given user request.

## Format

`master-registry.json.template` is the structural template. Each entry:

```json
{
  "id": "<agent-id>",
  "description": "<one-line role>",
  "matches": {
    "keywords":  ["regex1", "regex2"],
    "tools":     ["Bash", "Write"],
    "file_globs": ["*.sql", "src/api/*"]
  },
  "aliases": ["alternative-name"],
  "model": "sonnet | opus | haiku (optional)",
  "memory_scope": "local | project | user (default: local)"
}
```

## How the supervisor uses it

On every PreToolUse Write/Edit/Bash event, `supervisor.py`:

1. Extracts intent signals from the current event (keywords from the
   tool input, file path globs, tool name).
2. Looks up matching registry entries.
3. If a match exists and the work is non-trivial, returns
   `permissionDecision="ask"` with a hint:
   *"This work looks like X — consider dispatching specialist `<agent-id>`
   via the Agent tool first."*

The user can override by typing "proceed anyway" or by dispatching the
suggested specialist.

## Same-name resolution

When multiple sources register the same agent name:

```
local in-place (agents/) > context-mode > superpowers > third-party plug-in
```

Document deviations in `rules/policy/skill-adoption-comparison.md`.

## See also

- `agents/code-reviewer.md`, `agents/architect.md`, etc. — concrete
  agent definitions distributed with the framework.
- `core/hooks/supervisor.py` — the orchestrator.
- `master-registry.json.template` — registry skeleton.
