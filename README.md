# Agent Harness Starter Kit

Portable AI-agent operating harness extracted from production AirLens patterns and generalized for other projects.

It installs conservative rules, hook runtimes, multi-agent worktree coordination, Claude/Codex adapter assets, and configurable supervisor routing. AirLens-specific material is preserved under `examples/airlens/` and is not installed by default.

## Install

```bash
bash setup.sh --profile minimal
bash setup.sh --profile claude --project
bash setup.sh --profile multi-agent --project
bash setup.sh --profile full --project --backup
bash setup.sh --profile airlens-example --project
bash setup.sh --dry-run --profile claude
```

Profiles:

| Profile | Installs |
|---|---|
| `minimal` | `.agent-harness/*.json`, core rules, `gitleaks.toml`, `.gitignore` safety entries, basic secret guards |
| `claude` | minimal + Claude agents, `/project-init`, settings template, supervisor hooks |
| `codex` | minimal + portable Codex skills |
| `multi-agent` | minimal + worktree/session infra, heartbeat, mutex hooks |
| `full` | Claude + Codex + multi-agent |
| `airlens-example` | AirLens example assets only |

Options:

```bash
--dry-run --backup --force --no-hooks --no-global --target <dir>
```

The installer never writes `.claude/settings.local.json`; it writes `.claude/settings.local.template.json` so each project can opt in locally.

## Runtime Config

Generated project files:

```text
.agent-harness/config.json
.agent-harness/agent-registry.json
.agent-harness/domains.json
.agent-harness/risk-rules.json
```

Supervisor defaults:

| Field | Default |
|---|---|
| domains | `frontend`, `backend`, `database`, `security`, `testing`, `docs`, `ops`, `ml`, `general` |
| risk | `LOW`, `MEDIUM`, `HIGH` |
| mode | `advisory` |
| strict | off |

Strict mode can be enabled with `AGENT_HARNESS_STRICT=true` or by setting `.agent-harness/config.json` mode to `strict`.

## Layout

| Path | Purpose |
|---|---|
| `core/rules/` | Portable operating policies |
| `core/hooks/` | Generic hook runtimes and tests |
| `core/infra/` | Worktree/session/mutex helpers |
| `core/config/` | Default `.agent-harness` config templates |
| `adapters/claude/` | Claude agents, command, and settings templates |
| `adapters/codex/` | Portable Codex skills |
| `adapters/gemini/` | Gemini session wrapper |
| `templates/` | Project templates |
| `examples/airlens/` | AirLens-specific mirror and domain policies |
| `docs/` | Starter-kit operations and policy design docs |

## Verification

```bash
python3 core/hooks/test_supervisor_routing.py
python3 core/hooks/test_hooks_dynamic_root.py
gitleaks detect --no-git --source . --config gitleaks.toml
```
