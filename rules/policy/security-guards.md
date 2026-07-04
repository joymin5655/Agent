# Security Guards — Risk Areas SOT

5 risk areas that the framework's automation **must never act on
unilaterally**. The user is always in the loop. The patterns here are
defaults; consumers override via `hook-config.yml`.

## 1. Production Data (`data`)

- **Default pattern**: `^.*/migrations/.*\.sql$`
- **Risk**: irreversible data modification or loss.
- **Gate hook**: `core/hooks/r4-mutex-check.sh` claims the
  `production-db` resource (a mutex resource name, not a risk-area ID —
  see `templates/hook-config.yml.template`'s `resources:` section);
  concurrent sessions block.
- **Decision**: `ask` (user must explicitly confirm).

## 2. Secrets (`secrets`)

- **Default scope**: `secrets/**`, `.env*` (excluding `.env.example`),
  and any literal that looks like a secret (sk-…, eyJ…, hardcoded `KEY=`).
- **Risk**: credential leak, account compromise.
- **Gate layers**:
  - Layer 1 — gitleaks (pre-commit)
  - Layer 2 — CI secret-scan workflow
  - Layer 3 — `core/hooks/pre-tool-guard.sh` blocks `cat`/`tail`/`grep`
    on these paths
  - Layer 4 — `core/hooks/secret-content-scan.py` blocks Write/Edit
    containing the patterns
  - Layer 5 — `core/hooks/context-mode-guard.sh` blocks sandbox bypass
  - Layer 6 — `core/git-hooks/pre-push` rescans on push
- **Decision**: `deny` (no `ask` escape; user must remove the secret
  from the diff, then retry).

## 3. Deploy (`deploy`)

- **Default pattern**: `^.*/functions/.*/index\.ts$` (also configurable
  for other framework deploy bundles).
- **Risk**: production endpoint change without review.
- **Gate hook**: `core/hooks/r4-mutex-check.sh` claims
  `production-deploy` resource.
- **Decision**: `ask`.

## 4. Payment (`payment`)

- **Default pattern**: `(billing/|stripe|polar|iap|revenue-cat)`
- **Risk**: live payment-system change.
- **Gate**: skill-level safeguard in `/wrap` and `/supervise`;
  no automatic hook (this area requires user judgement).
- **Decision**: skill aborts; user must explicitly authorise.

## 5. Domain Output (`domain-output`)

- **Project-specific**: e.g., uncertainty / confidence intervals for
  ML outputs, quality grades, signed prediction fields.
- **Risk**: removing transparency or trust signals from user-facing
  output.
- **Gate**: PostToolUse advisory hook
  (a project-supplied `domain-output-check.py` that scans for net removal
  of uncertainty / quality fields) when configured.
- **Decision**: advisory only — never blocks. Reviewer enforces
  in PR review.

## Overriding defaults

Edit `hook-config.yml`:

```yaml
risk_areas:
  data:
    pattern: '^db/migrations/.*\.sql$'
  deploy:
    pattern: '^workers/.*\.ts$'
  domain-output:
    pattern: '(uncertainty|confidence_p\d+|grade_letter)'
```

## Violation log

Each block writes one record to `.agent/logs/security-violations.jsonl`:

```json
{"ts":"2026-…","risk":"secrets","hook":"pre-tool-guard.sh","reason":"…","session_id":"…","decision":"deny"}
```

Audit at T+30d to find bypass patterns and false-positive trends.
