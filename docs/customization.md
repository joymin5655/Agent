# Customization — `hook-config.yml`

Two different things currently share this name, at different maturity levels:

1. **The secret-scan extension loader** (`core/hooks/hook_config.py`) — small,
   dynamic, actually parsed at runtime by `secret-content-scan.py`.
2. **The project-scaffold template** (`templates/hook-config.yml.template`,
   installed by `setup.sh --project`) — documents the `risk_areas:` /
   `resources:` / `hardcoding:` shape. `risk_areas.secrets.paths`,
   `risk_areas.data/deploy/payment` and `resources.<name>.triggers` are read at
   runtime (extension-only); the rest (`secrets.keywords`, `domain-output`,
   `hardcoding:`) is documentation only.

This page documents both, and is explicit about which is which.

---

## 1. Secret-scan extensions (real, dynamic)

`core/hooks/secret-content-scan.py` is the only hook with a live project-config
loader. It is **additive only** — a project config can add patterns/exempts,
never remove or weaken a built-in, never flip `deny` to `allow`.

### Where it lives

- File: `.agent/hook-config.yml` (requires PyYAML; skipped if absent, except that
  a declared `risk_areas` makes the Bash guard fail closed)
  or `.agent/hook-config.json`, at the resolved repo root. Both are read if
  both exist; their lists are concatenated.
- `templates/hook-config.yml.template` (the file `setup.sh --project` scaffolds
  to your project root) now ships this exact schema as a commented
  `python_hooks:` example at its bottom, bracketed by
  `LIVE-SCHEMA-EXAMPLE-BEGIN`/`END` markers — uncomment it and copy the
  project-root file to `.agent/hook-config.yml` to activate. A drift-guard
  test (`core/tests/hook-config-test.sh` case h) round-trips that exact
  example through `hook_config.load_extensions()`, so the template and the
  loader can't silently fall out of sync.
- Repo root resolution: `$AGENT_PROJECT_DIR` env var, else `$CLAUDE_PROJECT_DIR`,
  else `git rev-parse --show-toplevel`. There is no `$AGENT_HOOK_CONFIG` env
  var and no upward directory walk (the same root resolution serves the live
  fields in part 2).
- Missing / unreadable / malformed file → silently degrades to built-ins only
  (fail-safe: a broken config can never crash a session or weaken detection).

### Schema (the only one `hook_config.py` actually parses)

```yaml
# .agent/hook-config.yml (or .agent/hook-config.json)
# Nest under `python_hooks:`, or omit the nesting and use these 3 keys
# at the top level — both are accepted.
python_hooks:
  secret_patterns:           # [regex, label] PAIRS — not {id, description, regex} objects
    - ["myservice_(live|test)_[a-zA-Z0-9_-]{32,}", "MyService API token"]
  exempt_paths:              # substring fragments; each needs >=1 alphanumeric run of 3+ chars
    - "vendor/fixtures/"
  credential_key_names:      # plain strings, folded into one extra KEY=value pattern
    - "MYSERVICE_TOKEN"
```

Each list is capped at 100 entries. A `secret_patterns` regex is dropped
before it ever reaches the scanner if it exceeds 200 chars, fails to compile,
or matches a nested-quantifier ReDoS heuristic (`(a+)+`-style) — built-in
patterns are trusted and exempt from these config-only screens.

**Shape warning:** entries must be a 2-element `[regex, label]` list, not an
object with `id`/`description`/`regex` keys — the loader silently drops
anything that isn't a 2-element list/tuple of strings, so an object-shaped
entry parses to nothing, with no error.

### Minimal example

```yaml
# .agent/hook-config.yml
secret_patterns:
  - ["myservice_(live|test)_[a-zA-Z0-9_-]{32,}", "MyService API token"]
exempt_paths:
  - "vendor/fixtures/"
credential_key_names:
  - "MYSERVICE_TOKEN"
```

### Validating a config

There is no `setup.sh --validate-config` flag. To sanity-check the loader,
run the real integration test:

```bash
bash core/tests/hook-config-test.sh
```

It drives `secret-content-scan.py` with a temporary `.agent/hook-config.json`
and asserts: built-ins still fire, a custom pattern denies, a custom exempt
allows, malformed config fails safe, MCP-shaped events are scanned, an
over-broad exempt can't blanket-allow everything, and a ReDoS-shaped config
pattern is time-bounded rather than hanging the hook.

---

## 2. `risk_areas:` / `resources:` / `hardcoding:` (partly live, extension-only)

`setup.sh --project` scaffolds a project-root `hook-config.yml` from
`templates/hook-config.yml.template`; **copy it to `.agent/hook-config.yml`** (or `.json`) —
the project-root copy is not read by any hook. That file documents a map-keyed shape, and the
fields marked LIVE below are read at runtime through `core/hooks/hook_config.py`:

- `risk_areas:` — `data`, `secrets`, `deploy`, `payment`, `domain-output`
  (see `rules/policy/security-guards.md` for what each covers).
  LIVE: `secrets.paths`; `data` / `deploy` / `payment` `.pattern` and `.decision`
  (read by `pre-tool-guard.sh`, `core/git-hooks/pre-push` and `core/infra/auto-ship.sh`).
  NOT wired: `secrets.keywords`, `domain-output`.
- `resources:` — `production-db`, `edge-function-deploy`, `production-deploy`
  (mutex resource names, distinct from the risk-area IDs above).
  LIVE: `<name>.triggers` (read by `r4-mutex-check.sh`). `auto_expire_minutes` was removed
  from the schema: an expiry would weaken the mutex.
- `hardcoding:` — `exempt_globs`, `scan_extensions`
- session/worktree settings — `heartbeat_interval_seconds`, `lock_dir`,
  `log_dir`, etc.

**Extension-only.** A live field can only ADD to a hook's built-in behaviour: patterns are
unioned with the built-ins, `decision` is `max(consumer floor, declared)` (it never lowers
anything, and `deny` appears only when you write it), and `resources.<name>.triggers` are consulted
only when no built-in trigger matched. Without PyYAML the `.yml` is skipped with a stderr warning
and the built-ins apply (`.json` still works); the one exception stays `risk_areas.secrets.paths`,
which fails closed (P1-9). A regex that is invalid, longer than 200 chars, nested-quantified or
matches the empty string is ignored with a warning, and matching is time-bounded. Schema and
per-consumer behaviour: [`hook-config.md`](hook-config.md). `check-hardcoding.py`'s exempt-globs
are still hardcoded in the script (`hardcoding:` is documentation only).

---

## How each hook actually behaves today

| Hook | Reads project config? | What it does |
|---|---|---|
| `secret-content-scan.py` | Yes — `.agent/hook-config.yml`/`.json` via `hook_config.py` (schema in part 1) | Built-in scan + additive config patterns/exempts/key-names |
| `pre-tool-guard.sh` | Yes — `risk_areas.secrets.paths` (deny, P1-8) and `risk_areas.data/deploy/payment` (ask; deny only if declared) | Built-in patterns first, project paths added on top |
| `r4-mutex-check.sh` | Yes — `resources.<name>.triggers` (extension-only) | Built-in resource triggers first; config adds resources; matches against the lock file |
| `core/git-hooks/pre-push`, `core/infra/auto-ship.sh` | Yes — `risk_areas.data/deploy/payment` | Built-in/env patterns unioned with config; pre-push advisory (block only on declared `deny`), auto-ship aborts |
| `check-hardcoding.py` | No — hardcoded in-script (patterns/exempts; wiring = backlog T-4) | Flags hardcoded design literals. Default **dryrun** (advisory + `.agent/logs/hardcoding.jsonl`); `AGENT_HARDCODING_MODE=off\|dryrun\|block` (block restores the pre-2026-07 deny). Note: `off` exits before any logging, so the telemetry digest shows the gate as DEAD while off — unenforced AND untelemetered |

---

## If you need project-specific risk areas or mutex resources

Declare `risk_areas.data/deploy/payment` patterns and `resources.<name>.triggers` in
`.agent/hook-config.yml|json` (see above). To change or remove a built-in pattern, or to add a
brand-new risk-area id, fork the hook script (`pre-tool-guard.sh`, `r4-mutex-check.sh`) — config
deliberately cannot weaken a built-in.

---

## Trust tiers — personal vs collab projects

`core/hooks/trust_tier.py` resolves a per-project trust tier that maps onto
the loop-engineering readiness ladder
([`concepts/loop-engineering.md`](concepts/loop-engineering.md)):

| Tier | Readiness posture | Behavior (v1 consumer: `plan-scope-allow.py`) |
|---|---|---|
| `personal` | ~L2/L3 — your own project, earned automation | Plan-approved sessions auto-allow in-workspace, non-risk Write/Edit (no native prompt); `--auto-push` workflows are reasonable |
| `collab` | ~L0/L1 — external/shared project, report-first | Ships dark: every edit keeps the native permission prompt; prefer report-only waves and user-confirmed pushes |

**Hard safeguards are tier-independent.** Risk-area aborts, R4 mutex, gitleaks,
and test-failure aborts bind identically in both tiers — a tier only adjusts
*prompt friction*, never *safety gates*.

### How a workspace earns `personal`

Detection order (first hit wins; everything unknown fails closed to `collab`):

1. **Repo-side downgrade** — a `.agent/trust-tier` file containing `collab`
   forces collab. Content `personal` is **ignored**: a repo file can only
   tighten, never escalate (same additive/stricter-only rule as all repo
   config).
2. **Owner match** — `git remote get-url origin`'s owner segment
   (case-insensitive; https/scp/ssh URL forms) appears as an `owner` line in
   the user-side trust list. A parseable remote owner decides alone: a
   foreign owner resolves to `collab` **even under a trusted path** — an
   external clone sitting in your personal projects directory is still
   collaboration.
3. **Path match** — reached only when there is no parseable remote owner:
   the workspace root sits under a `path` line (realpath prefix; covers
   personal directories with no remote).
4. Otherwise — `collab`. No trust list, unparseable lines, unknown remotes,
   no remote, and any error all land here.

### The trust list is user-side by design

`~/.agent/trust.list` (template: `templates/trust.list.template`; test seam:
`AGENT_TRUST_FILE`) lives **outside every workspace**. `plan-scope-allow.py`
never auto-allows writes outside the workspace root, so an agent trying to
edit the trust list always faces the native permission prompt — the
env-only-weakening principle is preserved by mechanism, not convention.

Line format (stdlib parsing, no YAML):

```
# comments and blank lines ignored
owner your-github-username
path /home/you/personal-projects/
```

**Accepted risk (documented):** a Bash-capable agent could spoof
`git remote add origin` to a trusted owner. Bash is already a full-power
surface with its own gates; the threat model here is *durable repo-file
self-weakening*, the same accepted-risk class as the `/tmp/agent-plan-approved`
flag. Tier consumption by `auto-ship.sh`/`supervise` (blocking `--auto-merge`
in collab) is backlog LE-2.

---

## Shipped defaults vs a personal profile

The repo's shipped gate defaults are conservative by design — every mode
env var this doc's sibling hooks read defaults to `dryrun` (or an
equivalent observe-only state): `AGENT_SPEC_GATE_MODE`, `AGENT_TDD_GUARD_MODE`,
and `AGENT_VERIFY_BLOCKING` all ship `dryrun`, `AGENT_SUPERVISOR_MODE` ships
`dispatch` (its own observe-only escape hatch is `observe`). A fresh clone or
a collaborator's checkout must never fail hooks it never asked to enforce —
that is what "deploy-safe" means here.

A solo-daily working profile overrides those defaults through ordinary env
layering, never by editing a shipped hook script:

- **Global** (`~/.claude/settings.json` `env`): `AGENT_VERIFY_BLOCKING=block`,
  `AGENT_SPEC_GATE_MODE=dryrun` (stay in dryrun until you've confirmed the
  gate's scope actually matches how you work — promote to `block` only
  after that check), `AGENT_SUPERVISOR_MODE=observe`, `AGENT_LOG_ORIGIN=session`.
- **Per-repo** (`.claude/settings.local.json` `env`, this repo only):
  `AGENT_SPEC_GATE_MODE=block`, `AGENT_TDD_GUARD_MODE=block` — this repo's
  own AGENTS.md §1 ("plan before code") and §4 (TDD discipline) are stricter
  than the shipped default, so working *on* the harness enforces on itself
  what the harness ships off for everyone else.

**Personal settings files are never committed.** `settings.local.json` is
gitignored by convention and `~/.claude/settings.json` lives outside any
repo — the layering exists precisely so a maintainer's own working posture
never becomes another consumer's forced default. See the `update-config`
skill for the mechanics of editing these files safely.

**The council's Google lane stays vendor-pinned.** `core/infra/backends.json`'s
`third-opinion-review` role dispatches its `gemini` backend (the
Antigravity-bridged lane, see `docs/model-routing.md` § Cross-vendor
second-opinion lane), and that backend's own comment records the constraint
`backends-schema-test.sh` checks: its model pin (owned by
`adapters/antigravity/antigravity-tiers.json.template`, not the registry —
no-model-ids) must stay Google-vendor (`gemini-*`) models only — because
Antigravity itself can also serve other vendors' models, an unpinned lane
would silently duplicate another lane's vendor instead of giving council a
genuine second vendor's read. This is a vendor-identity constraint, not a
tier or effort one; it does not change with a personal profile.

## Telemetry env seams

| Variable | Used by | Meaning |
|---|---|---|
| `AGENT_GATE_SINK_DIR` | gate hooks writing `security-violations.jsonl` | Write records here instead of `<repo>/.agent/logs`. For test runners (`verify-all.sh` sets it); in a real session it hides every gate firing from the digest, which then shows the gates as DEAD |
| `AGENT_GATE_PROJECTS` | `telemetry-digest.sh --gates` | Colon-separated project roots (or `.agent/logs` dirs) summed into the sweep; merged with `--projects`, deduped by realpath |
| `AGENT_LOG_ORIGIN` | gate hooks | `origin` tag on each record (`session` default; test runners use `test`) |
| `AGENT_BRAIN_CAPTURE` | `brain-capture.py` (Stop hook) | `off`, `0` or `false` (any case) opts out: the hook exits at once and leaves no breadcrumb in the brain's `raw/` quarantine. Unset or any other value keeps the default (on). Explicit MCP `brain_capture` calls are not affected |
| `AGENT_SECRETS_SCAN_BUDGET` | `pre-tool-guard.sh` guard 5 (stage 2) | Seconds, a test seam: it can only shorten the built-in 2 s wall-clock alarm of the secrets scan, never lengthen it. A scan the alarm ends prints no answer, which is a deny. The pathological-input fixtures use it. |
