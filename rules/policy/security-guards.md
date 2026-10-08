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
{"ts":"2026-…","risk":"secrets","hook":"pre-tool-guard.sh","reason":"…","session_id":"…","decision":"deny","reproduce_test":false,"origin":"session","schema_version":"2.0.0"}
```

`origin` (`session` by default, or the value of `AGENT_LOG_ORIGIN` — test runners export
`test`) tells a real-session record from a battery's. `reproduce_test: true` marks synthetic
events. `telemetry-digest.sh --gates` counts only `origin` absent/`session` and reports the
rest as `fixture-rows-excluded`. Test runners also set `AGENT_GATE_SINK_DIR` so their records
never reach the live sink; never set it in a real session.

Audit at T+30d to find bypass patterns and false-positive trends.

## Supply-chain integrity — the harness's OWN shipped files (P3-4)

The five risk areas above guard a *consumer* project. A separate concern is the
harness itself: its shipped skills, agents, rules, and hooks are **auto-loaded**
into every consuming project, so a careless or hostile directive in one of them
is an indirect prompt-injection that rides everywhere. (The ECC public audit of a
226k-star harness found 513 auto-load instruction files, 49 of 64 agents wired to
Bash, and an unattended "observer-loop" — the archetype of this class.)

`core/tests/supply-chain-scan.sh` statically scans the shipped, auto-loaded
instruction files (`agents/`, `skills/`, `commands/`, `rules/`, `templates/`,
`AGENTS.md`, `AI_BOOTSTRAP.md`, `CLAUDE.md` — as `*.md`, `*.template`, and `*.json`
so scaffolding templates and the agent registry are covered) for the three prose
classes, and the auto-fired AI-decision hooks (`core/hooks/`, every file — a hook
may be extensionless) for the daemon class, and **fails CI** on any hit:

1. **prompt-injection override** (prose) — "ignore previous instructions",
   "disregard your instructions", "you have no choice".
2. **unattended persistence** (prose) — "observer loop", "run forever", "while
   true", "keep running indefinitely", "re-invoke yourself".
3. **no-confirmation coercion** (prose) — "without confirmation", "skip approval",
   "never ask for permission" (anchored on confirmation/permission/approval so a
   routing rule like "do not ask for a phantom agent" is not matched).
4. **background-daemon spawn** (hooks) — `nohup` / `setsid` / `disown` /
   `crontab -`.
5. **fetch-and-execute** — a fetch (`curl`/`wget`) piped into, substituted into or
   eval'd by an interpreter: `… | sh`, `| /bin/sh`, `| env bash`, `| python3`,
   `bash <(curl …)`, `eval "$(curl …)"`, `bash -c "$(curl …)"`. Always a hit in
   auto-fired hooks and in the code-wiring manifests (`hooks/*.json`, `.mcp.json`).
   In prose, a segment (split on `;`, `&&`, `||`) is tolerated only when it names
   a URL and every URL host in that segment is in
   `core/tests/supply-chain-allowlist.txt`. This allows the vendor installers that
   `/worker-setup` documents for the user to run by hand. Prose is also matched
   on a whitespace-flattened copy, so a pipe wrapped across lines cannot evade.
6. **unpinned remote runner** (hooks + manifests) — `npx`/`npm exec` with `--yes`
   or `--package`, and `bunx`, `pnpm dlx`, `yarn dlx`, `uvx`, `pipx run`, whose
   package is not pinned to an exact version. Text form and the MCP
   `{"command":…,"args":[…]}` form are both checked. A range (`^2.1.0`, `~1`, `2`)
   or a dist-tag (`@latest`, `@next`) is not a pin. Every run would execute
   whatever the registry serves that day.
7. **off-allowlist URL host** (hooks + manifests) — any http(s) host that is not in
   the allowlist. This includes IP literals (dotted, decimal, hex, IPv6),
   `localhost` and single-label names; only known documentation placeholders
   (`https://host/…`) are skipped. A URL with userinfo
   (`https://allowed.com@evil.example`) never matches the allowlist. An auto-fired
   hook gains a network destination only through a reviewed allowlist edit.

Classes 5–7 adapt ECC v2.2's `pi/core` build checks (a URL host allowlist plus
pipe-to-shell detection). They run in `core/tests/supply-chain-remote.py`, because
URL authorities, interpreter forms and runner arguments need real parsing.
`plugin.json` and `.claude-plugin/*.json` are metadata
(homepage, repository, `$schema`) and wire no code, so they are out of scope.

**Threat model.** Classes 5–7 are a tripwire for the ordinary shapes a careless
or copy-pasted directive takes: line continuations, redirects, quoting, JSON
escaping and repeated flags are handled. They are not a shell interpreter. A
deliberately obfuscated payload (a URL assembled from variables, base64, `eval` of
a computed string) can still pass. Human review of every diff that touches
`core/hooks/`, `hooks/*.json` or `.mcp.json` remains the backstop.

The three prose classes are matched **both line-by-line and against a
whitespace-flattened copy** of each file, so an injection wrapped across soft
line breaks (deliberately, or by an 80-column reflow) cannot evade a line-oriented
grep.

**Decision**: CI gate (`deny`-equivalent — the scan must pass before merge). It is
the self-integrity analogue of `sanitize-audit.sh` (which guards prior-project
taint). Run locally with `bash core/tests/supply-chain-scan.sh`.

### Sanctioned async primitives (deliberately out of the daemon scope)

Class 4 scans only the **auto-fired** AI-decision hooks — surfaces that run inside
the agent loop, where daemonizing is never acceptable. Two shipped daemons are
**explicitly invoked** or **git-lifecycle** controlled, are one-shot rather than a
persistent loop, and are therefore out of scope by design:

- `core/git-hooks/post-commit` (autosync) backgrounds a **one-shot** push + PR
  (`… & disown`) so a commit isn't blocked — fire-and-forget, not a loop.
- `core/infra/agent-session.sh subscribe <name>` launches a **user-authored**
  subscriber (`nohup …`) on explicit invocation, the same way `npm run dev`
  starts a dev server.

Adding a new background primitive to an auto-fired hook (rather than to this
explicitly-invoked plumbing) will — and should — fail the scan.
