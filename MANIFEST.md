# Agent Repository Manifest

Last updated: 2026-04-30

## Included Asset Groups

- Claude root registry: `.claude/agents/master-registry.{json,md}`
- Web agents: `AirLens-web/.claude/agents/*`
- Models agents: `AirLens-models/.claude/agents/*`
- Claude rules and commands from root, web, and models scopes
- AirLens Codex skills under `AirLens-web/.codex/skills/*`
- Obsidian operations docs: `AGENT_HARNESS.md`, `AGENT_REGISTRY.md`, `master-registry.json`
- Obsidian concepts docs for agent dispatch, runtime separation, collaboration, and harness architecture

## Exclusion Policy

- No secrets or credential inventories
- No hook logs or session JSONL
- No application source code unless it is part of an agent/rule/skill definition
- No generated build outputs or dependency folders

## Verification Performed Before Import

```bash
PYTHONPYCACHEPREFIX=/tmp python3 scripts/hooks/test_supervisor_routing.py
PYTHONPYCACHEPREFIX=/tmp python3 scripts/sync_agent_registry.py --check
node scripts/harness-audit.js repo --format text --root "$PWD"
```
