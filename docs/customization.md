# Customization — `hook-config.yml`

Every project that adopts this framework gets a `hook-config.yml` that defines what counts as a risk area, a shared resource, or a sensitive command in YOUR project.

The same `core/hooks/*` scripts work for all projects — what differs is the config they read.

---

## Where it lives

`hook-config.yml` sits at the **project root** (next to `CLAUDE.md`).

Hook scripts look up:
1. `$AGENT_HOOK_CONFIG` env var if set
2. `<cwd>/hook-config.yml`
3. `<cwd>/../hook-config.yml` (walk up to project root)
4. Skip (assume permissive defaults — log warning to stderr)

---

## Schema

```yaml
# ============================================================================
# hook-config.yml — project-specific risk and resource policy
# ============================================================================
version: "1.0"

# ---------------------------------------------------------------------------
# Risk areas — patterns that trigger ask/deny in PreToolUse
# ---------------------------------------------------------------------------
risk_areas:

  - id: data
    description: "Production database migrations and direct SQL"
    paths:
      - "migrations/*.sql"
      - "supabase/migrations/*.sql"
      - "db/migrations/*"
    commands:
      - "psql .* production"
      - "alembic upgrade"
      - "knex migrate:latest"
      - "supabase db push"
    mcp_tools:
      - "mcp__supabase__apply_migration"
      - "mcp__supabase__execute_sql"
    decision: ask
    abort_code: 12

  - id: secrets
    description: "Direct access to secrets/ or .env files"
    paths:
      - "secrets/**"
      - ".env"
      - ".env.*"
    commands:
      - "cat secrets/"
      - "source .env"
      - "head secrets/"
    decision: deny
    abort_code: 15

  - id: deploy
    description: "Server-side function deployment"
    paths:
      - "supabase/functions/*/index.ts"
    commands:
      - "supabase functions deploy"
      - "wrangler publish"
      - "vercel deploy --prod"
    mcp_tools:
      - "mcp__supabase__deploy_edge_function"
    decision: ask
    abort_code: 13

  - id: payment
    description: "Live payment library / Stripe / Polar / IAP"
    paths:
      - "**/billing/**"
      - "**/payments/**"
    decision: ask
    abort_code: 14

  - id: domain-output
    description: "User-facing domain output that must include uncertainty"
    paths:
      - "src/components/forecasts/**"
      - "apps/web/src/widgets/**"
    decision: ask  # require human review
    abort_code: 16

# ---------------------------------------------------------------------------
# Shared resources — multi-session mutex
# ---------------------------------------------------------------------------
resources:

  - id: production-db
    description: "Production database write access"
    matches:
      mcp_tools: ["mcp__*__apply_migration", "mcp__*__execute_sql"]
      commands: ["supabase db push", "alembic upgrade .* production"]
    timeout_hours: 1

  - id: production-deploy
    description: "Production deploy commands"
    matches:
      commands: ["wrangler pages deploy", "fly deploy", "vercel --prod"]
    timeout_hours: 1

  - id: edge-function-deploy
    description: "Edge function deploy"
    matches:
      mcp_tools: ["mcp__*__deploy_edge_function"]
      commands: ["supabase functions deploy"]
    timeout_hours: 1

# ---------------------------------------------------------------------------
# Secret patterns — extend the built-in regex catalog
# ---------------------------------------------------------------------------
secret_patterns:
  # Built-in patterns are always active. Add project-specific tokens here.
  - id: my-service-token
    description: "MyService API token"
    regex: 'myservice_(live|test)_[a-zA-Z0-9_-]{32,}'

  - id: my-internal-jwt
    description: "Internal JWT shape"
    regex: 'eyJhbGciOi[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'

# ---------------------------------------------------------------------------
# Memory protected paths — Claude-Mem or similar plug-ins should NOT auto-edit
# ---------------------------------------------------------------------------
memory_protected_paths:
  - "CLAUDE.md"
  - "AGENTS.md"
  - "GEMINI.md"
  - "docs/**/*.md"
  - "rules/**/*.md"

# ---------------------------------------------------------------------------
# Plan-tier classifier
# ---------------------------------------------------------------------------
plan_tier:
  # When the user prompt matches these patterns, classify as 'autonomous' tier
  autonomous_triggers:
    - "/wrap"
    - "/supervise"
    - "전부 진행"
    - "auto merge"
  # 'interactive' = default. 'autonomous' = skip clarifying questions
  default_tier: interactive
```

---

## How each hook consumes it

| Hook | Field it reads | What it does |
|---|---|---|
| `pre-tool-guard.sh` | `risk_areas[].paths`, `commands` | Deny on path/command match |
| `secret-content-scan.py` | `secret_patterns[].regex` | Add to built-in regex set |
| `r4-mutex-check.sh` | `resources[]` | Match tool_input against resource.matches; check lock file |
| `claude-mem-watch.py` | `memory_protected_paths[]` | Watch list of paths for unauthorized edit |
| `classify-prompt.py` | `plan_tier.autonomous_triggers` | Tag prompt with tier |

---

## Minimal example (security-focused, no risk areas yet)

```yaml
version: "1.0"

risk_areas:
  - id: secrets
    description: "Secrets and env files"
    paths: ["secrets/**", ".env*"]
    decision: deny
    abort_code: 15

resources: []

secret_patterns: []

memory_protected_paths:
  - "CLAUDE.md"

plan_tier:
  default_tier: interactive
```

---

## Validation

A schema check is built into setup.sh:

```bash
bash ~/agent/setup.sh --validate-config /path/to/project/hook-config.yml
# OK or prints schema errors
```

Each hook validates on load and skips silently with a stderr warning if config is malformed (fail-safe: better to under-enforce than crash AI sessions).

---

## Migration from hardcoded policy

If you're moving from a previous setup where risk areas were hardcoded in hook scripts:

1. List your hardcoded paths/commands.
2. Add them to `risk_areas[]` here.
3. Remove the hardcoded lookup from your fork of `core/hooks/`.
4. Verify with smoke test: `core/tests/hook-config-loader-test.sh`.

The benefit: hook code stays portable. Only `hook-config.yml` is project-specific.
