# Project hook config — `.agent/hook-config.yml`

The generic `secret-content-scan.py` hook ships with a fixed set of built-in
secret patterns, exempt paths, and credential key names. A consuming project can
**specialize** the scan — adding its own token formats, whitelist paths, and
credential variable names — **without forking the plugin**, by dropping a config
file at its repo root:

- `.agent/hook-config.yml` (read only when PyYAML is importable), and/or
- `.agent/hook-config.json` (stdlib JSON — no extra dependency)

If both files exist, their lists are concatenated. The plugin core carries no
hard dependency on PyYAML; the `.yml` form is skipped if PyYAML is absent. One
exception: if that `.yml` declares `risk_areas`, the Bash guard fails closed and
denies read/copy/upload commands, plus any command containing one of those verbs as a
substring (e.g. `git add .`), until PyYAML is installed (P1-9).

## tdd-guard whitelist extension

`risk_areas.secrets.paths` also extends tdd-guard's whitelist (files exempt from RGR
enforcement). It is additive: the built-in secrets / migrations / edge-fn / billing
patterns always stay. The config root resolves like the Bash guard
(`AGENT_PROJECT_DIR`, then `CLAUDE_PROJECT_DIR`, then git toplevel).

Differences from the Bash guard, which uses the same field:

- The Bash guard uses the field to **block**; tdd-guard uses it to **exempt**. So
  tdd-guard honors only specific tokens (containing `/` or starting with `.`).
  Bare words such as `env`, `src` or `auth` are ignored with one stderr note.
- Matching is anchored at a path boundary (`(^|/)token`), with a right boundary
  unless the token ends in `/`. It is case-sensitive.
- Without PyYAML, a `.yml` config is skipped and tdd-guard falls back to the
  built-ins (fail-open). The Bash guard fails closed (P1-9). A `.json` config
  works without PyYAML.
- The PyYAML warning can print once per hook invocation, so once per Edit/Write.

## Risk-area patterns and mutex resources (T-4)

Both files also carry the following. They are read by one loader (`core/hooks/hook_config.py`)
and follow the same rule as everything else here: **extension-only**.

| Field | Read by | Effect |
|---|---|---|
| `risk_areas.data.pattern` | `pre-tool-guard.sh` (guard 15), `core/git-hooks/pre-push`, `core/infra/auto-ship.sh` | a regex or list (Python `re`, `search` on a repo-relative path), added to the built-in `^.*/migrations/.*\.sql$` |
| `risk_areas.deploy.pattern` | same three | added to the built-in `^.*/functions/.*/index\.ts$` |
| `risk_areas.payment.pattern` | same three | added to auto-ship's built-in payment pattern; pre-tool-guard and pre-push have none, so there it only takes effect when listed |
| `risk_areas.<area>.decision` | same three | `advisory` \| `ask` \| `deny`; effective = `max(consumer floor, declared)` |
| `resources.<name>.triggers` | `r4-mutex-check.sh` | regexes mapping a Bash command / MCP tool name to the mutex `<name>`; consulted only when no built-in trigger matched |

Consumer floors: `pre-tool-guard` **ask**, `pre-push` **advisory**, `auto-ship` **abort**. A
declared `deny` blocks the push (pre-push exit 12/13/14 for data/deploy/payment) and denies the
command (pre-tool-guard); it is the only way `deny` is reached. Built-in guards keep their own
fixed decisions (DROP/TRUNCATE TABLE stays `ask`, `data/artifacts/` add stays `deny`).

- **What pre-tool-guard matches.** The paths a Bash command would *modify*, found with a small
  shell tokenizer (quotes, heredoc bodies and comments are data; `;` `&&` `||` `|`, redirects and
  `$(...)` / backtick bodies are interpreted): `git add|rm|mv` arguments (honouring `git -C DIR`),
  `git restore <path>` and `git checkout -- <path>`, the arguments of `rm unlink touch truncate
  tee`, the destination of `cp install ln` (a destination directory also yields `dir/<basename>`;
  `-t DIR` works) plus the sources of `mv`, `sed|perl -i` / `--in-place[=SUF]` file operands (the
  script operand is skipped), `dd of=`, write redirects (`>` `>>` `>|` `&>` `&>>` `N>` `<>`), and
  the bodies of `sh|bash|zsh|dash -c '...'` and `eval`, plus command substitutions anywhere —
  `$(...)`, backticks (a backslash-escaped backtick nests, as in the shell), the same inside double
  quotes and inside an UNQUOTED heredoc body (a quoted `<<'EOF'` body is data). `$((...))` is
  arithmetic, not a command, but a `$(...)` nested inside it still counts. Relative paths are resolved against the
  event's `cwd` (default: the hook's), `..` is normalised, and paths outside the project are
  ignored. It runs last, so a built-in deny/ask always wins. A project that declared an area
  evaluates EVERY Bash command (one extra python start, ~30 ms; there is deliberately no verb
  pre-filter, which could not be a safe superset of the tokenizer: `to\uch`, `git -c 'x=;' add`);
  a project that declared none never starts python for this. A command over ~100 KB is cut by
  bytes for the hand-off to python and reported as truncated (fail-closed, below).
- **What it does not see (limits).** `git add .` / `-A` and globs (no file names), `rsync`,
  `find -delete|-exec`, `patch`, `git apply`, `git stash`, `awk -i inplace`, an interpreter
  one-liner that writes (`python -c "open(...)"`), a script body fed through a heredoc or a pipe
  (`bash <<EOF`), variables and command results (`"$F"`), and anything past the analysis caps. The
  caps are never silent: a command over 64 KiB / 512 simple commands / 2000 paths, or a file list
  over 20000 entries, produces a warning and a fail-closed hit on every area that declares a
  pattern (pre-tool-guard asks, auto-ship aborts, pre-push blocks only if that area declares
  `deny`). pre-push, which sees the real changed-file list, is the backstop for what the Bash guard
  cannot see.
- **Over-asking.** The extraction is a heuristic. Where a project declares `decision: deny`, a
  residual false positive (for example a quoted path inside a `-c` string the tokenizer cannot
  tell from code, or a path written through an unusual option form) becomes a false BLOCK, not
  just an extra prompt. Prefer `ask` unless the area is truly never edited by automation.
- **PyYAML missing.** The `.yml` is skipped with ONE stderr line, `hook_config: PyYAML not installed
  ...`, and the built-ins apply — no new refusal. `.json` still works. (`risk_areas.secrets.paths`
  keeps its P1-9 fail-closed behaviour.)
- **Bad entries and the deadline.** A regex that is invalid, over 200 chars, nested-quantified
  (`(a+)+`, or a character class followed by `+`/`*`) or that matches the empty string is ignored
  with `hook_config: ignored ...`; siblings still apply. At most 20 patterns per area and 20
  resources x 20 triggers; matching sees at most 1024 chars per path. Every regex execution, the
  empty-string screen included, runs under a 0.25 s watchdog and ONE process-wide 1.5 s deadline
  shared by all areas and resources. A single pattern that overruns is ignored with a warning. So a
  config can delay a guard by at most ~1.5 s (pre-tool-guard additionally wraps the evaluation in a
  5 s `timeout` where available), and the secrets check (11b) and every other built-in verdict are
  settled before the config is evaluated. A resource name must match `[a-z0-9][a-z0-9_.-]*`;
  `decision` is case-insensitive and is read from EVERY config file before any regex runs.
- **Exhausted budget and truncation fail closed.** When the 1.5 s deadline is spent before the
  patterns of a declared area were all run, that area is treated as *not evaluated* — exactly like
  an input over an analysis cap — never as "no match" (a slow `.yml` therefore cannot lower a `deny`
  declared in the `.json`). The consumer then acts on its own rule: pre-push blocks only if that
  area declares `deny` (otherwise an advisory says "not fully evaluated"), auto-ship aborts, and
  pre-tool-guard asks. In pre-tool-guard such synthetic hits are capped at `ask`: `deny` is reserved
  for a real path match, and the message names the area(s) that reached the decision. `resources`
  triggers are the exception: an exhausted budget skips the remaining triggers with a warning
  (no resource can be named from an unevaluated trigger). Projects that declare no area see none of
  this (no warning, no extra hit).
- **Not read.** `resources.<name>.auto_expire_minutes` (an expiry would shorten a lock's hold, so it
  would weaken the mutex; stale locks are `agent-session.sh gc`'s job), `secrets.keywords`,
  `domain-output`, and a `hook-config.yml` at the project root.

```yaml
# .agent/hook-config.yml
risk_areas:
  data:    {pattern: '^db/migrations/.*\.sql$', decision: ask}
  payment: {pattern: ['(billing/|stripe)', '^pay/']}
resources:
  ship-it: {triggers: ['make ship', '^release\.sh']}
```

Tests: `bash core/tests/risk-area-config-test.sh`.

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

## Completion tests — `session.completion_tests` (P3-1)

The Stop gate (`core/hooks/session-quality-gate.py`) can run project-declared
verification commands before a response is allowed to end — so an agent cannot
claim "done" while the project's own tests fail. Declare them under a top-level
`session:` mapping (not under `python_hooks:`):

```yaml
session:
  completion_tests:
    - "npm test --silent"
    - "npx tsc --noEmit"
```

Behavior:

- Commands run on the **first Stop** of a response, in the project root. If any
  exits non-zero, times out, or fails to spawn, the hook emits
  `{"decision":"block"}` and the session cannot end until it passes. (Stop hooks
  cannot emit `ask` — that verb is PreToolUse-only — so the enforcement verb is
  `block`.)
- A **second Stop** passes automatically (intentional-override anti-loop), and
  `AGENT_QUALITY_GATE_BLOCK=0` makes the whole gate advisory. Each command is
  bounded by `AGENT_COMPLETION_TEST_TIMEOUT` seconds (default 120).
- **Style scan is advisory** (2026-07-27 guard-trim): the same hook's
  subjective style checks (inline types, hardcoded hex colors, `console.log`)
  are reported and logged but never block by default — only `completion_tests`
  failures drive the `block` decision. Opt back into the old style-blocking
  behavior with `AGENT_QUALITY_STYLE_BLOCK=1`.
- **Trust model:** these commands run at the project's OWN trust level — the
  same as its `package.json` scripts or Makefile. The loader bounds count (≤20)
  and length (≤500 chars) but does not sandbox execution; an agent that could
  add a `completion_tests` entry could already run the command directly, so this
  adds enforcement, not new capability. Unset/empty ⇒ the gate does nothing.
- Fail-safe: a missing / malformed config degrades to no completion tests; the
  hook always exits 0 (an internal error never crashes the Stop event). The
  per-command timeout is parsed defensively — a non-numeric `AGENT_COMPLETION_TEST_TIMEOUT`
  (e.g. `2m`) degrades to 120s rather than crashing the hook at import.
- Process isolation: each command runs in its **own** process group/session
  (`start_new_session`), so a teardown idiom that signals its group
  (`kill 0`, `trap 'kill 0' EXIT`) reaches only the command, never the Stop
  hook. Residual boundary: this isolates the group, not parentage, so a command
  that reads `$PPID` and signals the hook's own pid with an uncatchable signal
  (`kill -9 $PPID`) cannot be defended in-process — that is a deliberate
  self-attack at the project's own trust level, and its outcome is a fail-open
  non-blocking stop, never corruption or a weakened gate.

## Unverified-session advisory (no config required)

"Unset/empty ⇒ the gate does nothing" above is a real hole: a project that never
declares `completion_tests` can have a session rewrite code from end to end, run
nothing, and end clean. The gate registry recorded the consequence — the
`quality-completion` gate shows zero local firings precisely because no consumer
declares the key.

`core/hooks/verify-observer.py` (PostToolUse, Bash) closes the unconditional half
and needs **no project config at all**. It records that a verification command was
*invoked* — family label only (`tests`, `battery`, `typecheck`, `lint`, `build`) —
into `.agent/logs/verify-observed.jsonl`. Layer 3 of the Stop gate reads those
records and, when the session diff carries changed **code** files and no
verification was invoked in that session, emits an advisory.

Behavior:

- **Scoped to this session's own edits.** The diff is intersected with the files
  the session actually edited, read off `transcript_path` (Edit/Write/MultiEdit/
  NotebookEdit tool calls, sidechain included). Before this, the gate read the
  whole dirty work tree and called it "changed this session": on 2026-09-02 a
  file left uncommitted by a *concurrent* session was reported to five unrelated
  sessions as their own change. With no transcript the note falls back to the
  work-tree list and says so, rather than claiming an attribution it cannot
  support.
- **Emitted once per file set.** `stop_hook_active` gates blocking only, so
  layer 3 — advisory, computed every Stop — used to re-fire on every Stop for
  the rest of the session, and since it is re-injected as model-visible context
  it fed the turn that produced the next Stop (measured: 80 firings in 7m22s,
  and 79 in a second session). It is now suppressed once recorded for the same
  (session, changed-file set); a *new* unverified file changes the fingerprint
  and the gate speaks again. Same shape as `council-escalation-gate.py`'s
  same-diff-hash single-deny.
- **Observe-only by default.** It reports and logs; it never blocks. Opt into
  blocking with `AGENT_VERIFY_OBSERVER_BLOCK=1`. The registry entry is `observe`
  so `telemetry-digest --gates` can measure the fire-rate *before* anyone argues
  for enforcement (see `docs/gate-registry.md` → "Is the gate worth its noise?").
- **It never claims a verification passed.** Claude Code's PostToolUse payload
  carries no exit status — measured 2026-07-30 with a probe pair: `exit 3` with
  quiet output went unrecorded by `circuit-breaker.py` while `exit 0` printing
  "0 errors" was recorded as a failure. Inferring pass/fail from output text is
  that same misclassification, so the signal is deliberately presence-only and
  the advisory wording asserts no outcome.
- **No command text is stored.** A command line can carry a token or a URL with
  credentials; the family label is all the Stop gate needs, so the raw string is
  never written and there is no redaction path to get wrong.
- **Code-only, allowlisted.** Only known code extensions count as a change
  (docs/config edits stay silent). An allowlist rather than a docs-denylist means
  an unrecognised extension fails silent instead of firing.
- **Family patterns match at invocation position only.** Containing a runner
  name is not enough: `pip install pytest-mock`, `which eslint`, and
  `cat core/tests/verify-all.sh` all contain one while running nothing. The
  command is split on shell separators and normalised to `<program> <rest>`
  (leading `VAR=val` assignments and wrapper prefixes such as `npx` / `uv run`
  stripped, program reduced to its basename), and every pattern is anchored to
  that. A false negative here can only produce the advisory that is already the
  default posture; a false positive hides the gap the layer exists to find, so
  exotic invocation forms are left unmatched rather than covered loosely.
- Anti-loop and fail-safe follow the rest of the gate: a second Stop passes, and
  an unreadable/unwritable sink degrades to silence rather than crashing Stop.
- **The sink must be a regular file, and is opened without blocking.** A plain
  append blocks forever on a FIFO with no reader, and the default sink path
  reaches that with no environment variable at all — a project shipping a FIFO
  at `.agent/logs/verify-observed.jsonl` hung every Bash tool call *and* the
  Stop hook, so the session could not end (measured 2026-07-30). Both halves now
  open with `O_NONBLOCK` and verify `S_ISREG` on the descriptor, which also
  closes the stat-then-open race a symlink swap would otherwise win. A
  non-regular sink records nothing and the advisory still fires — unwritable is
  never read as verified.
- Seams: `AGENT_VERIFY_OBSERVED_SINK` (override path, confined by realpath to the
  project's `.agent/logs` or the system temp dir), `AGENT_REPRODUCE_TEST=1`
  (marks battery-fed records `reproduce_test:true` so they never inflate the
  measured fire-rate).

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
- `rules/policy/security-guards.md` — the secret-defense risk area this layer serves.
