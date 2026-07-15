# Customization — `hook-config.yml`

Two different things currently share this name, at different maturity levels:

1. **The secret-scan extension loader** (`core/hooks/hook_config.py`) — small,
   dynamic, actually parsed at runtime by `secret-content-scan.py`.
2. **The project-scaffold template** (`templates/hook-config.yml.template`,
   installed by `setup.sh --project`) — documents an intended `risk_areas:` /
   `resources:` / `hardcoding:` shape, but as of this writing no hook reads
   that block dynamically. Each hook's actual matching is hardcoded in the
   script.

This page documents both, and is explicit about which is which.

---

## 1. Secret-scan extensions (real, dynamic)

`core/hooks/secret-content-scan.py` is the only hook with a live project-config
loader. It is **additive only** — a project config can add patterns/exempts,
never remove or weaken a built-in, never flip `deny` to `allow`.

### Where it lives

- File: `.agent/hook-config.yml` (requires PyYAML; skipped entirely if absent)
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
  var and no upward directory walk — those apply only to the aspirational
  block in part 2.
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

## 2. `risk_areas:` / `resources:` / `hardcoding:` (documented shape, not yet dynamic)

`setup.sh --project` scaffolds a project-root `hook-config.yml` from
`templates/hook-config.yml.template`. That file documents a map-keyed shape:

- `risk_areas:` — `data`, `secrets`, `deploy`, `payment`, `domain-output`
  (see `rules/policy/security-guards.md` for what each covers)
- `resources:` — `production-db`, `edge-function-deploy`, `production-deploy`
  (mutex resource names, distinct from the risk-area IDs above)
- `hardcoding:` — `exempt_globs`, `scan_extensions`
- session/worktree settings — `heartbeat_interval_seconds`, `lock_dir`,
  `log_dir`, etc.

**As of this writing, no hook reads this block at runtime.** `pre-tool-guard.sh`'s
risk-area path/command matching, `r4-mutex-check.sh`'s resource-trigger
matching, and `check-hardcoding.py`'s exempt-globs are each hardcoded
directly in the script — not loaded from your project's `hook-config.yml`.
Editing the yml file's `risk_areas:`/`resources:`/`hardcoding:` sections today
has no effect on hook behavior; to change what a hook matches, edit the
hardcoded patterns in the hook script itself. Treat
`templates/hook-config.yml.template` as documentation of the target shape for
a still-open gap, not a working config surface yet.

---

## How each hook actually behaves today

| Hook | Reads project config? | What it does |
|---|---|---|
| `secret-content-scan.py` | Yes — `.agent/hook-config.yml`/`.json` via `hook_config.py` (schema in part 1) | Built-in scan + additive config patterns/exempts/key-names |
| `pre-tool-guard.sh` | No — hardcoded in-script | Denies on hardcoded risk-area path/command patterns |
| `r4-mutex-check.sh` | No — hardcoded in-script | Matches hardcoded resource triggers against the lock file |
| `check-hardcoding.py` | No — hardcoded in-script | Flags hardcoded literals; hardcoded exempt-globs list |

---

## If you need project-specific risk areas or mutex resources today

Since `risk_areas:`/`resources:` aren't dynamically loaded yet: fork the
relevant hook (`pre-tool-guard.sh` for risk areas, `r4-mutex-check.sh` for
mutex resources) and edit its hardcoded patterns directly. Keep your
`hook-config.yml`'s `risk_areas:`/`resources:` blocks as a record of intent
even though nothing reads them yet — it keeps `rules/policy/security-guards.md`
and your fork in sync when the dynamic loader lands.

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
