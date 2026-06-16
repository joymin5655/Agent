# Project hook config — `.agent/hook-config.yml`

The generic `secret-content-scan.py` hook ships with a fixed set of built-in
secret patterns, exempt paths, and credential key names. A consuming project can
**specialize** the scan — adding its own token formats, whitelist paths, and
credential variable names — **without forking the plugin**, by dropping a config
file at its repo root:

- `.agent/hook-config.yml` (read only when PyYAML is importable), and/or
- `.agent/hook-config.json` (stdlib JSON — no extra dependency)

If both files exist, their lists are concatenated. The plugin core carries no
hard dependency on PyYAML; the `.yml` form is simply skipped if PyYAML is absent.

## Schema

All keys live under a top-level `python_hooks:` mapping (a bare top-level mapping
is also accepted). Every key is optional; a missing or empty key contributes
nothing.

```yaml
python_hooks:
  # Extra secret regexes. Each entry is a [regex, label] pair.
  secret_patterns:
    - ["myco_secret_[A-Za-z0-9]{20,}", "MyCo internal service token"]
    - ["myco_(live|test)_[A-Za-z0-9_-]{32,}", "MyCo API key"]

  # Extra path fragments. A scanned file whose path CONTAINS any fragment is
  # skipped (substring match, same semantics as the built-in exempt list).
  exempt_paths:
    - "vendor/fixtures/"
    - "docs/examples/"

  # Extra credential variable names. These are folded into ONE additional
  # pattern that matches  NAME = "value-of-20+-chars".
  credential_key_names:
    - "MYCO_SERVICE_TOKEN"
    - "MYCO_WEBHOOK_SECRET"
```

The JSON form is identical in shape:

```json
{
  "python_hooks": {
    "secret_patterns": [
      ["myco_secret_[A-Za-z0-9]{20,}", "MyCo internal service token"]
    ],
    "exempt_paths": ["vendor/fixtures/"],
    "credential_key_names": ["MYCO_SERVICE_TOKEN"]
  }
}
```

## Security guarantee — ADDITIVE ONLY

The loader (`core/hooks/hook_config.py`) can **only make the scan stricter**:

- Config can **append** secret patterns, exempt paths, and credential key names.
- Config **cannot** remove, disable, override, or reorder any built-in pattern.
- Config **cannot** flip any decision from `deny` to `allow`. The only way a
  config affects an allow is by adding an `exempt_path`, which simply skips
  scanning for a file path the project explicitly whitelists — it never turns a
  detected secret into an allow.
- **Exempt paths are bounded — they cannot exempt the universe.** An exempt
  fragment is dropped unless at least one of its alphanumeric segments is
  >= 3 chars. Over-broad fragments such as `/`, `.`, `..`, `./`, `.ts`, `.js`
  are rejected (under substring matching they would skip scanning EVERY file and
  silently flip built-in `deny` into `allow`). Specific whitelists like `.env`,
  `/src/`, `secrets/`, `config/`, `.test.` are kept.
- Built-in patterns and exempts always remain and run **first**.

This means a careless or hostile config is bounded: at worst it adds noise
(extra denials) or whitelists a *specific* path; it can never weaken the secret
defense or exempt everything.

### Fail-safe

The loader **never raises**. Any problem — missing file, unreadable file,
invalid YAML/JSON, wrong top-level shape, non-list values, non-string entries,
or malformed `[regex, label]` pairs — causes that bad input to be silently
dropped, degrading to empty extensions. A broken config therefore reduces the
hook to its built-in behavior; it can never crash the hook. The number of
accepted config patterns, exempts, and key names is each capped (100) to bound
scan cost.

#### Config regex safety (ReDoS defense in depth)

`re.compile()` validates regex **syntax only** — it does **not** detect
catastrophic backtracking, so syntactic validity alone is **not** a ReDoS guard.
A config-supplied secret regex is instead screened in layers:

1. **Syntax** — must compile via `re.compile()` (uncompilable regexes dropped).
2. **Length cap** — config regexes longer than 200 chars are dropped.
3. **Nested-quantifier heuristic** — a config regex whose group or character
   class itself contains a quantifier immediately followed by another quantifier
   (`(a+)+`, `(a*)*`, `(.+)+` style) is dropped at load time.
4. **Runtime timeout** — any config regex that survives the above is still
   bounded at scan time by a **2-second `SIGALRM` watchdog** (where `SIGALRM` is
   available; on platforms without it — e.g. Windows — layers 1–3 apply). On
   timeout the scanner abandons the remaining config patterns and proceeds with
   the built-in findings already collected.

Built-in patterns are trusted and are **not** subject to the config-only screens
(2/3) or the timeout — they always run **first** and are never lost. So a
catastrophic-backtracking config pattern is time-bounded, never hangs the
session, and never affects built-in detection.

## What the hook scans

With the MCP/WebFetch matchers wired in `hooks.json`, the scan fires not only on
`Write|Edit|MultiEdit` but also on database, crawler, cloud-storage, and fetch
tool calls (recursively walking nested URL/content fields). So a project's
custom patterns apply across all of those surfaces automatically.

## Consumer transition

A hardened monorepo that today maintains its **own duplicate copies** of these
core hooks (a private `secret-content-scan` with project-specific token regexes
baked in, a private exempt whitelist, and its own MCP matcher wiring) can drop
the duplicates and rely on this plugin core instead:

1. Install / depend on this plugin so `core/hooks/secret-content-scan.py` and
   its `hooks.json` MCP matcher wiring run as the single source of truth.
2. Move the project-specific token regexes, whitelist paths, and credential
   variable names out of the forked hook and into `.agent/hook-config.yml`
   (or `.json`) under `python_hooks:`.
3. Delete the duplicate hook scripts and the duplicate matcher blocks the
   project was maintaining by hand.

The result: one maintained, audited scanner core (with the full MCP/WebFetch
coverage) plus a small, declarative project config that carries only what is
genuinely project-specific. Built-in coverage is inherited automatically, and
the additive-only guarantee means the project config can only tighten — never
loosen — the inherited defense.

## Related

- `core/hooks/secret-content-scan.py` — the scanner (built-ins + integration).
- `core/hooks/hook_config.py` — the additive, fail-safe loader.
- `core/tests/hook-config-test.sh` — runnable proof of (a) built-in fires,
  (b) config pattern added, (c) config exempt honored, (d) malformed config is
  fail-safe, (e) MCP input is scanned.
- `rules/security-guards.md` — the secret-defense risk area this layer serves.
