# Agent Harness Starter Kit

Portable AgentOps starter kit extracted from AirLens production patterns and generalized for other projects.

It installs project-local operating rules, JSON config, optional Claude/Codex adapter assets, hook runtimes, and multi-agent worktree coordination. By default it does not write `~/.claude`, does not create `.claude/settings.local.json`, and does not install AirLens-specific assets.

## 60-Second Install

From the root of a git repository:

```bash
bash setup.sh --profile minimal
```

For Claude project hooks:

```bash
bash setup.sh --profile claude --project
cp .claude/settings.local.template.json .claude/settings.local.json
```

The template copy is the opt-in switch for local hooks. Review it before enabling it, because local settings are machine-specific and intentionally gitignored.

## Common Profiles

```bash
bash setup.sh --profile minimal
bash setup.sh --profile claude --project
bash setup.sh --profile multi-agent --project
bash setup.sh --profile full --project
bash setup.sh --profile full --project --global
bash setup.sh --profile airlens-example --project
bash setup.sh --dry-run --profile claude --project
```

| Profile | Installs |
|---|---|
| `minimal` | `.agent-harness/*.json`, core rules, `gitleaks.toml`, `.gitignore` safety entries, basic secret guards |
| `claude` | minimal + Claude agents, `/project-init`, settings template, supervisor hooks |
| `codex` | minimal + portable Codex skills |
| `multi-agent` | minimal + worktree/session infra, heartbeat, mutex hooks |
| `full` | minimal + Claude + Codex + multi-agent assets |
| `airlens-example` | AirLens example assets only |

Useful options:

```bash
--target <dir>   install into another git repository
--dry-run        print actions without writing
--no-hooks       skip hook runtime/template files
--force          overwrite existing files
--backup         with --force, keep *.bak.<timestamp> copies
--global         also install Claude baseline files into ~/.claude
--no-global      compatibility alias for the default project-only behavior
```

## What It Writes

Project config:

```text
.agent-harness/config.json
.agent-harness/agent-registry.json
.agent-harness/domains.json
.agent-harness/risk-rules.json
```

Local hook template:

```text
.claude/settings.local.template.json
```

The installer never creates `.claude/settings.local.json`. Copy the template yourself when you want the hooks active in that local checkout.

## Runtime Defaults

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
| `schemas/` | JSON schemas for public config files |
| `adapters/claude/` | Claude agents, command, and settings templates |
| `adapters/codex/` | Portable Codex skills |
| `adapters/gemini/` | Gemini session wrapper |
| `templates/` | Project templates |
| `examples/airlens/` | AirLens-specific example assets |
| `docs/` | Starter-kit operations and policy design docs |
| `scripts/ci/` | Config and installer verification |

## Verification

```bash
python3 scripts/ci/validate-configs.py
python3 core/hooks/test_supervisor_routing.py
python3 core/hooks/test_hooks_dynamic_root.py
bash scripts/ci/installer-smoke.sh
gitleaks detect --no-git --source . --config gitleaks.toml
```

If `gitleaks` is not installed, CI reports an explicit skip instead of failing the job.
