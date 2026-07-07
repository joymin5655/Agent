# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.3] — 2026-07-08

### Changed
- **I-1 — secret-content-scan matcher consolidation.** The 6 non-edit matcher
  blocks (supabase ×3 tools, firecrawl ×5, WebFetch, Notion ×3, Google Drive
  ×2, stitch ×2) collapse into one union matcher; the registration inside the
  Write|Edit|MultiEdit chain stays to preserve chain order. 7→2 blocks, the
  19 covered tools verified unchanged, no double-fire (each tool matches
  exactly one block).

### Added
- **I-2 — doctor drift checks (10 & 11).** `setup.sh --doctor` now warns when
  the plugin install cache holds more than one agent-harness version (a stale
  cache re-exposing retired agents was a live incident), and reconciles a
  user-declared global-hook manifest (`AGENT_HOOK_MANIFEST`, default
  `~/.claude/LOCAL-LAYER.hooks`; `AGENT_GLOBAL_SETTINGS` for the live file)
  against the runtime settings in both directions (declared-but-not-live /
  live-but-undeclared). WARN-only — observers never block; no manifest → check
  skipped. Manifest lines are trusted substrings authored by the user (an
  over-broad line makes the check vacuous by choice). Fixtures:
  `setup-doctor-test.sh` 12 checks.

## [0.2.2] — 2026-07-08

> Cumulative since 0.2.0: the 0.2.1 plugin release (2026-07-07, model-routing
> policy + the P3-1/3/4/5 batch) was cut without sectioning this file, so the
> entries below span 0.2.1 and 0.2.2. Newly in 0.2.2: P3-2 (`/spec` +
> spec-gate), the freedom-vs-enforcement calibration audit, and the T/E +
> O/L/I backlog series.

### Added
- **Freedom-vs-enforcement calibration audit + new backlog series.**
  `docs/freedom-enforcement-calibration-2026-07.md` tiers every enforcement/
  freedom point (deny/ask/block/advisory/observe/aspirational) and grounds
  keep/promote/measure-first verdicts in 2026 external evidence. New backlog:
  T-1 teaching gates (WHY/FIX in every gate message), T-2 gate registry +
  fire-rate + expiry, T-3 negative skill-trigger examples, E-1 public eval
  harness promotion (Pass^3); O-1 supervise delegation-contract revision
  (4-part brief, fan-out cap 3–5, single-writer, isolated verify lane),
  O-2 generic `skills/loop` (fresh-context / one-task-per-iteration /
  file+git state), L-1 failure-mode-checklist grader redesign, L-2
  grader/tests write-ban + append-only ledger, I-1 secret-scan matcher
  consolidation, I-2 doctor cache/manifest drift checks
  (`docs/harness-improvement-plan.md` §4.8–4.9).
- **P3-1 — completion-gate test verification.** `core/hooks/session-quality-gate.py`
  (Stop hook) now runs a project's `session.completion_tests` (declared in
  `.agent/hook-config.yml|json`) on the first Stop; any command that exits
  non-zero, times out, or fails to spawn emits `{"decision":"block"}` so a
  session cannot end while the project's own tests fail. A second Stop passes
  (anti-loop) and `AGENT_QUALITY_GATE_BLOCK=0` is advisory; per-command bound is
  `AGENT_COMPLETION_TEST_TIMEOUT` (default 120s). New fail-safe/bounded loader
  `hook_config.load_session_config` (≤20 cmds, ≤500 chars each; malformed →
  empty). Trust model = the project's own scripts (docs/hook-config.md).
  Adversarial-review hardening of the always-exit-0 contract: the timeout env
  var is parsed at import behind a guard (a typo like `2m`/`30s` degrades to
  120 instead of crashing the Stop hook), and completion commands run with
  `start_new_session=True` so a process-group teardown idiom (`kill 0`,
  `trap 'kill 0' EXIT`) reaches only the command's own group, not the hook.
  Test: `core/tests/quality-gate-completion-test.sh` (21 checks incl. YAML
  path, advisory, anti-loop, malformed fail-safe, non-numeric timeout,
  process-group isolation, timeout→block, loader bounds).
- **P3-2 — `/spec` upstream-planning discipline + spec-gate enforcer.** New skill
  `skills/spec/SKILL.md` walks brainstorm → `.agent/plans/<slug>/spec.md` + `plan.md`
  → ExitPlanMode approval, borrowing the superpowers methodology as CONTENT while the
  ENFORCEMENT is a tool boundary. New PreToolUse hook `core/hooks/spec-gate.py` is the
  consumer of the plan-approval flag that `plan-gate.py` already writes (and
  session-init/close already clear): when no plan is approved this session and a
  Write/Edit targets substantive impl code (scope covers `src`/`app`/`pages`/`lib`/
  `server`/`components`, extension-gated), it acts per `AGENT_SPEC_GATE_MODE` —
  `off` no-op, `dryrun` (default) advisory-only, `block` emits `permissionDecision:
  "ask"`. The approval flag is the dedup (approve once via ExitPlanMode → every edit
  passes; the two escapes — ExitPlanMode approval and `AGENT_SPEC_GATE_MODE=off` —
  are named in the reason). `ask` not `deny`, per the reversible-gate escalation
  principle. Fail-open (any exception → exit 0, empty stdout); mirrors `tdd-guard.py`.
  Wired into the `Write|Edit|MultiEdit` chain (after tdd-guard, before supervisor).
  Adversarial-review hardening (13-agent refute-by-default; 6 confirmed): SKIP dir
  tokens are now ANCHORED (`(^|/)(types|config|…)/` so `src/subtypes/` no longer
  inherits the `types/` exemption — a MAJOR false-allow), the flag path is the shared
  hardcoded `/tmp/agent-plan-approved` with NO env override (a per-consumer override
  would decouple the reader from plan-gate's writer), the default scope was broadened
  past `src/` to real app layouts, and matching is case-insensitive (so `src/Pay.TS`
  can't evade on a case-insensitive FS). Test: `core/tests/spec-gate-test.sh`
  (42 checks incl. anchored-skip, absolute paths, broadened scope + harness-not-gated,
  case-insensitive ext, fail-open, and the ask-not-deny + both-escapes assertions).
- **P3-3 — verification-gate-bypass + linter-tamper guards.**
  `core/hooks/pre-tool-guard.sh` now `ask`s on `git commit/push --no-verify`
  (and `git commit -n`), which skip the repo's own gitleaks+sanitize commit
  gate, and on Bash edits to linter/formatter/gate configs (eslint, prettier,
  ruff, flake8, biome, golangci, pre-commit, gitleaks) — the "disable the check
  instead of fixing the code" anti-pattern. `git push -n` (dry-run) and normal
  commits pass; reading a config passes. `ask` (not deny) per the escalation
  principle. Adversarial-review hardening: the no-verify guard now also catches
  git's bundled short-flag forms (`-nm`, `-vn`; git parses `-nm` as `-n -m`),
  a `-c key=val` global option before the subcommand, and inline
  `core.hooksPath=` — while a commit whose *message* merely mentions `-n` no
  longer false-asks (the message is stripped before matching); the linter-tamper
  rule no longer false-asks on a read that redirects elsewhere
  (`cat .eslintrc.json > backup.txt`) by requiring the config to be the mutate
  target. First test for this hook: `core/tests/pre-tool-guard-test.sh` (28
  checks, incl. regression coverage of the existing destructive/secret rules).
- **P3-4 — self supply-chain scan.** `core/tests/supply-chain-scan.sh` statically
  scans the harness's OWN shipped, auto-loaded instruction files (`agents/`,
  `skills/`, `commands/`, `rules/`, `templates/`, `AGENTS.md`, `AI_BOOTSTRAP.md`,
  `CLAUDE.md`) for three prose classes — prompt-injection override, unattended
  observer-loop persistence, no-confirmation coercion — and the auto-fired
  AI-decision hooks (`core/hooks/`) for a background-daemon-spawn class
  (nohup/setsid/disown/crontab), failing on any hit. Patterns are calibrated to
  zero hits on the clean tree; the no-confirm class is anchored on
  confirmation/permission/approval so a routing rule like "do not ask for a
  phantom agent" is not flagged. Explicitly-invoked plumbing with sanctioned
  one-shot async (autosync post-commit push, `agent-session.sh subscribe`) is out
  of scope and documented in `rules/policy/security-guards.md`. This is the
  self-integrity analogue of `sanitize-audit.sh`. Wired as a **new CI job** (4th).
  Adversarial-review hardening (13-agent refute-by-default pass) closed real
  detection gaps: instruction files are now scanned as `*.md` **plus**
  `*.template` (scaffolding copied verbatim into consumers) and `*.json` (the
  agent registry); hooks are scanned as **every file** (a hook may be
  extensionless); each prose class is matched against a **whitespace-flattened**
  copy so an injection wrapped across soft line breaks can't evade line-oriented
  grep; and the self-reference exemption is anchored to **exact paths** (a file
  merely named `security-guards.md` elsewhere no longer inherits it). Test:
  `core/tests/supply-chain-scan-test.sh` (20 checks: 4-class detection incl.
  templates, extensionless hooks, wrapped/multi-line, JSON registry, all four
  daemon tokens + clean-tree pass + false-positive guards for the phantom rule,
  start_new_session, infra-scope daemons, and the path-anchored exemption).
- **P3-5 — independent completion-claim verifier (eval-harness seed).** A
  builder-validator layer that re-checks a completion claim from a separate
  context, so "the builder says it's done" is never the last word.
  `core/infra/completion-verify.py` is the deterministic core: given a claim
  (`.agent/claims/<slug>.yml|json` declaring cited files / tests / assertions)
  it mechanically checks each file exists (and contains its declared substring),
  each test exits 0, and each assertion holds, then emits a shared-convention
  verdict JSON (`{verdict, score, dimensions, refutations}`). Refute-by-default:
  a missing file, a failing test, a malformed/empty claim, or an over-cap claim
  all resolve to `REFUTED` (exit 1) — never a crash, never a silent pass; exit 0
  iff `CONFIRMED`, so it doubles as a CI/wave GATE. Bounded (≤50 files, ≤20
  tests/assertions) and hardened with the same `start_new_session=True` +
  guarded-timeout-parse lessons as P3-1. `skills/verify-completion/SKILL.md` is
  the semantic layer on top — an independent-context judge that adds the
  "does the code actually do what the claim says / are the tests meaningful"
  review scripts can't make, emitting the same schema. New shared spec
  `docs/scoring-convention.md` unifies the verdict shape across the verifier,
  the H-3 skill A/B harness, and the `supervisor-goal-audit.sh` 25-point scorer.
  Adversarial-review hardening (11-agent refute-by-default pass): a present-but-
  non-list section (`"files":"x"`) now REFUTES instead of being silently dropped
  into a false CONFIRMED; command output is discarded to DEVNULL and the
  `contains` read is bounded (5 MB) so a chatty command or a huge file can't OOM
  the verifier. Test: `core/tests/completion-verify-test.sh` (25 checks incl.
  false-claim→refuted, consistent→confirmed, malformed/non-list-section
  fail-safe, YAML, process-group isolation, over-cap refutation, bare-string
  file entry, --root default, timeout degrade, partial score).
- `core/infra/telemetry-digest.sh` (P1-5) — pillar④ janitor step 1: reads
  `.agent/logs/supervisor.jsonl` (path arg, or `$AGENT_TELEMETRY_LOG`, or
  `<repo-root>/.agent/logs/supervisor.jsonl`) and reports action counts, a
  per-specialist funnel (match → ask → dispatched, with conversion %), top
  keywords by match count, and a rule-candidate section with three heuristics
  derived only from what `supervisor.py` already logs: `NO-ACCEPT` (a
  specialist was asked `ask-intent`+`ask-security` ≥3 times but never
  `dispatched` — specialist-routing.md Lesson 1), `GHOST` (a specialist logged
  `action=="ghost"` — registry references an agent id with no sibling
  `agents/<id>.md`), and `OVER-GENERAL` (a single keyword accounts for >70% of
  all `match` records, once total matches ≥3). `--window <days>` (default 30)
  scopes records by `ts`; `--json` emits a machine-parseable JSON blob instead
  of the human report. Known limitation, documented in the header: NO-ACCEPT
  can't fire under `AGENT_SUPERVISOR_MODE=observe` (it logs
  `observe-intent`/`observe-security` instead, which aren't counted).
  Dependencies are bash + python3 only — no `jq` (an earlier draft used `jq`,
  which contradicts `setup.sh --doctor`'s own WARN-tier/optional stance on
  it; JSON parsing runs through an embedded python3 heredoc instead). Always
  exits 0 (observer, not a gate) — a malformed line, a missing file, or an
  internal error degrades to a zeroed/"inactive" report rather than failing.
  Reproduce suite: `core/tests/telemetry-digest-test.sh` (21 checks:
  action-count accuracy, funnel notation, all three rule candidates,
  malformed-line skip counting, `--window` filtering, missing-log handling,
  `--json` output validity, legacy v0.1-record degradation).
- `core/hooks/supervisor.py` v0.2 — minimal **dispatch-not-advise** router (P1-4).
  Replaces the observation-only v0.1 stub. On `UserPromptSubmit` it word-boundary
  matches the prompt against each registry agent's `matches.keywords` and records a
  30-min TTL intent in `.agent/state/supervisor-intent.json`; the next
  Write/Edit/MultiEdit then returns `permissionDecision: "ask"` naming the specialist
  (once per intent — no repeat nag), and dispatching that specialist via Task/Agent
  (namespace-agnostic: `x:code-reviewer` resolves `code-reviewer`) clears the intent.
  A separate security matcher `ask`s on `matches.file_globs` for the tool, independent
  of intent, once per path. Ghost specialists (a registry id with no sibling `<id>.md`)
  never `ask` — stderr hint + `{"action":"ghost"}` log only (specialist-routing Lesson 2).
  `AGENT_SUPERVISOR_MODE=observe` downgrades every `ask` to stderr; any exception is
  fail-open (exit 0, empty stdout). Wired into `hooks/hooks.json` on all three events.
  Reproduce suite: `core/tests/supervisor-dispatch-test.sh` (10 scenarios).
- `session-init` now warns (stderr only) when `gitleaks` or `git` is missing from
  PATH — a mini env-doctor surfacing a degraded secret-scan setup at session start.
  Silent when both are present; never blocks the session or writes stdout.
- `setup.sh --doctor` (P1-7) — full environment diagnosis, read-only, zero install
  side effects. Checks: `git` present; `python3` >= 3.9 (README-declared floor,
  with version + path); `gitleaks` present (WARN if not — secret-scan git hook
  skips); `jq` present only if a `core/hooks/*.sh` script actually shells out to
  it (WARN if used-but-missing); every `core/hooks/*.sh`/`*.py` has its
  executable bit (`hook_config.py` exempt — a library module imported by
  `secret-content-scan.py`, never invoked directly); every `adapters/*/adapter.sh`
  is executable; `agents/master-registry.json` parses and every entry's `model`
  matches its sibling `agents/<id>.md` frontmatter (same drift guard as CI);
  `hooks/hooks.json` parses and every referenced hook script exists and is
  executable; `~/.agent/plans` exists (WARN + `mkdir` hint if not). Prints a
  `[PASS|WARN|FAIL]` row per check plus a `doctor: N pass, N warn, N fail`
  summary line; exits 1 iff any check FAILs. Reproduce suite:
  `core/tests/setup-doctor-test.sh` (clean-repo exit 0, gitleaks WARN under a
  restricted PATH, exit 1 + named FAIL line when a hook loses its executable
  bit — exercised against a throwaway `mktemp` copy, never the real tree).
- `templates/hook-config.yml.template` (P1-8 partial) — ships the real,
  dynamically-loaded `python_hooks:` schema (`core/hooks/hook_config.py`) as a
  commented example, bracketed by `LIVE-SCHEMA-EXAMPLE-BEGIN`/`END` markers,
  clearly labeled as the ONE block in the file actually read at runtime —
  distinct from the `risk_areas:`/`resources:`/`hardcoding:` blocks above it,
  which remain declarative-only (docs/customization.md part 2). New drift-guard
  case in `core/tests/hook-config-test.sh` (case h) extracts and uncomments
  that example into a real `.agent/hook-config.yml` and round-trips it through
  `hook_config.load_extensions()`, so template and loader can't silently drift
  apart. `docs/customization.md` cross-references the new template section.
- `.github/workflows/ci.yml` — CI: gitleaks secret scan + plugin manifest/hook/agent validation + sanitize gate
- README portfolio polish: badges, Mermaid architecture diagram, agent/skill/hook catalog
- `README.ko.md` — Korean mirror of the README (same sections, localized prose)
- `docs/harness-improvement-plan.md` — audit scorecard + prioritized backlog + autonomous
  improvement-loop design (Korean)
- `gitleaks.toml` — detect NVIDIA NIM API keys (`nvapi-` prefix; built-in rules miss it)
- `docs/architecture.md` — "Determinism and model-invariance" section: the hooks (gates)
  are model-invariant and machine-proven so via `core/tests/adapter-parity.sh`; risk-area
  denial is a real enforced gate while plan-mode/TDD enforcement is not yet wired (flag is
  recorded but unconsumed — see P1-4/P1-8); generated content (plans, code, prose) is
  honestly NOT guaranteed identical across models

### Changed
- `docs/harness-improvement-plan.md` — added §4.7 P3 series (5 items) from a
  2026-07-06 benchmark audit of 8 top personal harnesses (superpowers, ECC,
  karpathy-skills, gstack, revfactory, hooks-mastery, Chachamaru, showcase):
  completion-gate test
  verification (P3-1), upstream spec/plan discipline (P3-2), `--no-verify`/linter-
  tamper blocking (P3-3), self-supply-chain scan (P3-4), independent
  completion-claim verifier (P3-5). Adoptions ranked by demonstrated mechanism
  value, not stars; catalog-maximalism, prompt-coercion, and unattended
  instinct-persistence explicitly rejected as design-principle conflicts. §7
  backlog count 24 → 29 (P3 pattern `P[0-3]`).
- `agents/master-registry.json` — supervisor keyword matchers hardened to domain
  anchors (review follow-up, MAJOR-1; specialist-routing Lesson 1). code-reviewer
  drops bare `review`/`look over` for multi-word phrases (`code review`,
  `review this diff`, …); security-reviewer drops bare `security`/`auth` for
  `security review`/`security audit`/`owasp`/… — generic tokens a consumer writes as
  often as an author (`review my plan`, `the auth flow`) no longer false-route a
  specialist. `security-reviewer.matches.tools` gains `MultiEdit` (aligns with the
  `Write|Edit|MultiEdit` hook wiring); `file_globs` (path anchors) unchanged. Default
  mode stays `dispatch` — only the match surface narrowed, not the enforcement.
- `core/hooks/README.md` — `supervisor.py` moved from the deferred-roadmap "generic
  stub" row to the shipped-hooks table as the v0.2 minimal dispatcher; the roadmap row
  now scopes the remaining deferral to the full 54KB registry-aware orchestrator
- README rewritten for first-time readers: concept primer table, install-path chooser
  (plugin vs shell), prerequisites section (incl. previously undocumented `python3`
  dependency), "See it work" example, 4-layer architecture summary, trimmed layout tree
- Hook count corrected everywhere: 17 executable hooks + 1 shared module
  (`hook_config.py`) — previous "~25" claim was stale
- README.md/README.ko.md's "Why AI-agnostic?" section now cross-links to
  `docs/architecture.md`'s new "Determinism and model-invariance" section

### Fixed
- `plan-gate` was wired to `UserPromptSubmit` in `hooks/hooks.json` but is a
  `PostToolUse` hook (its docstring and logic key off `tool_name`, a field absent
  from `UserPromptSubmit` events). Result: every invocation was a silent no-op and
  the `/tmp/agent-plan-approved` flag was never written. Rewired to `PostToolUse`
  with matcher `ExitPlanMode|Task|Agent`, and broadened the plan-class check to
  accept the `Task` tool name (subagent dispatch differs by Claude Code version).
  READMEs' hook tables corrected to match.
- `session-quality-gate` wrote its violations log to `parents[2]` of the hook
  file — the plugin install cache when installed as a plugin — instead of the
  user's project. Log destination is now resolved at runtime: stdin event `cwd`
  → `CLAUDE_PROJECT_DIR` → `os.getcwd()`. Detection and block logic unchanged.
- `session-init` crashed at load on Python 3.9 — its `pathlib.Path | None` return
  annotation (PEP 604) is evaluated at def-time and raises `TypeError` before 3.10.
  Added `from __future__ import annotations` so annotations are treated as strings;
  the annotation itself is unchanged. Supported Python floor is 3.9 (now documented
  in README Prerequisites).
- Phantom test paths removed from `README.md`, `AGENTS.md`, `docs/architecture.md`,
  `docs/getting-started.md` — `core/tests/adapter-smoke/*/run.sh`, `cross-ai-parity.sh`,
  `verify-all.sh`, `bootstrap-test.sh`, and a pytest invocation never existed; docs now
  reference the 4 real test scripts (`sanitize-audit`, `adapter-parity`, `hook-config-test`,
  `post-commit-autosync-test`)
- Documented overwrite behavior corrected: `setup.sh` has no `--force` flag — replacements
  prompt interactively, or set `AGENT_SETUP_YES=1`
- `README.md` infra path corrected: `scripts/infra/agent-session.sh` → `core/infra/agent-session.sh`
- `AI_BOOTSTRAP.md` Step 5 pledge now names the generic 5 risk areas (per `hook-config.yml`
  / `rules/policy/security-guards.md`) instead of prior-project domain terms; the removed
  terms were added to the sanitize-audit token list (failure → new rule)
- `core/tests/sanitize-audit.sh` now scans git-visible content only (tracked +
  untracked-unignored via `git grep --untracked`), mirroring the CI job's excludes —
  runtime state and gitignored local files no longer cause permanent false FAILs;
  CI sanitize job additionally runs the full token-set audit as a superset step
- `core/hooks/secret-content-scan.py` plan-file comment corrected to the canonical
  `~/.agent/plans/` path
- Docs drift sweep: removed phantom hook/file references (`memory-explore-verify.py`,
  `claude-mem-watch.py`, `rules/policy/skill-adoption-comparison.md`) that described
  tooling never implemented; standardized risk-area vocabulary to the canonical
  `data` / `secrets` / `deploy` / `payment` / `domain-output` IDs across README,
  README.ko, `docs/customization.md`, and `docs/concepts/security-guards-generic.md`;
  corrected the security-guard layer count from 5 to 6 (matches `hooks.json`'s
  "6-layer secret hardening"); canonicalized stale `.claude/` path references to the
  runtime's actual `.agent/` and `rules/`/`skills/` locations in
  `docs/concepts/multi-session-worktree.md`, `AI_BOOTSTRAP.md`, and
  `docs/concepts/plan-mode.md`; and removed the `.claude/rules/` scaffold
  over-claim from `docs/architecture.md`, `README.md`, and `README.ko.md`
  (`setup.sh --project` never creates it)
- Docs drift sweep follow-up: removed the two remaining phantom
  `rules/policy/skill-adoption-comparison.md` references (`docs/master-registry.md`,
  `skills/README.md`); removed the phantom `classify-prompt.py` hook citation from
  `docs/concepts/plan-mode.md` (no `UserPromptSubmit` hook exists beyond
  `agent-session-heartbeat.sh` — tier classification is the AI applying the
  documented heuristics itself, not an automated hook). Rewrote
  `docs/customization.md` end to end after discovering its documented
  `hook-config.yml` schema doesn't match what any hook actually loads: only
  `core/hooks/hook_config.py` (used by `secret-content-scan.py`) reads a config
  file dynamically, from `.agent/hook-config.yml`/`.json` — a `[regex, label]`-pair
  `secret_patterns`/`exempt_paths`/`credential_key_names` schema, optionally
  nested under `python_hooks:`. The previously-documented `risk_areas:`/`resources:`/
  `hardcoding:` map (from `templates/hook-config.yml.template`) is not read by
  any hook at runtime — `pre-tool-guard.sh`, `r4-mutex-check.sh`, and
  `check-hardcoding.py` each match against patterns hardcoded in the script, not
  a project's `hook-config.yml`. The doc's old `secret_patterns` example
  (`{id, description, regex}` objects) was also independently confirmed to
  silently parse to an empty list under the real loader, which expects
  `[regex, label]` pairs — verified by running `hook_config._coerce_pattern_list`
  directly against both shapes. `README.md`/`README.ko.md`'s customization
  section and other doc mentions of a dynamically-loaded `risk_areas:`/`resources:`
  still describe the same not-yet-implemented mechanism and were out of scope for
  this sweep — flagged for a follow-up pass.
- Docs drift sweep, final pass: closed out the flagged follow-up above.
  `README.md`/`README.ko.md`'s Customization section no longer claims
  `core/hooks/r4-mutex-check.sh` "reads [`hook-config.yml`] and enforces it" —
  the `risk_areas:` block is now described as declarative (a documented policy
  record), with today's actual enforcement attributed to each hook script's own
  hardcoded patterns and the one dynamically-loaded mechanism (secret-scan
  extensions via `.agent/hook-config.yml`) called out, linking to
  `docs/customization.md` for the full real-vs-documented split.
  `AI_BOOTSTRAP.md`'s Step 5 pledge softened from "definitions live in
  `hook-config.yml`" (implies runtime consumption) to "declared in
  `hook-config.yml`; enforcement currently lives in the hook scripts."
  Same fix applied to the last two remaining spots the gate caught:
  `docs/concepts/security-guards-generic.md`'s "How to extend" section no
  longer claims "the same `pre-tool-guard.sh` reads this and enforces it" or
  shows a fabricated `abort_code` key — the example is now framed as
  declarative intent requiring a `pre-tool-guard.sh` fork to enforce, with a
  link to `docs/customization.md`. `rules/multi-agent-worktree.md`'s R4
  mutex-resource list dropped the phantom `payment-live` entry —
  `core/hooks/r4-mutex-check.sh` only ever claims `production-db`,
  `production-deploy`, or `edge-function-deploy`; there is no payment mutex.

### Removed
- *(recorded retroactively — the trim shipped before 0.2.0 but was never logged)*
  Shipped agent set reduced 10 → 5 (`architect`, `code-reviewer`, `security-reviewer`,
  `test-engineer`, `build-error-resolver`) and skills 16 → 4 (`supervise`, `tdd`,
  `diagnose`, `wrap`); the removed items remain available in `legacy/`
- Shipped agent set reduced 5 → 2: `architect`, `test-engineer`, and
  `build-error-resolver` archived to `legacy/trim-2026-07-04/agents/`. Basis:
  7 weeks of session telemetry showed zero dispatches for these three, and
  their roles are covered by other tooling. `code-reviewer` and
  `security-reviewer` are retained (they form the benchmarked review pair —
  see `docs/benchmark/results.md`). Recoverable via `git mv` from the
  archive plus re-adding the entries to `agents/master-registry.json`.
- Shipped skill set reduced 4 → 2: `tdd` and `diagnose` archived to
  `legacy/trim-2026-07-04/skills/`. Basis: 7 weeks of session telemetry
  showed zero dispatches for either skill. `supervise` and `wrap` are
  retained. The `tdd-guard` hook is unrelated to the `tdd` skill and
  continues to run unchanged. Recoverable via `git mv` from the archive.
- `codex-skills/` retired to `legacy/trim-2026-07-04/codex-skills/`. Basis:
  zero usage recorded in 7 weeks of session telemetry. The Codex CLI
  adapter (`adapters/codex/`) is unrelated and remains active; `setup.sh`
  no longer offers the `~/.codex/skills` symlink install step. See
  `legacy/trim-2026-07-04/ARCHIVE-NOTE.md` for the full recovery procedure.

## [0.2.0] — 2026-06-15

### Added
- **Claude Code plugin packaging** — `.claude-plugin/plugin.json` + `marketplace.json` make
  the harness installable via `/plugin marketplace add joymin5655/Agent` →
  `/plugin install agent-harness@agent`. One install, every project.
- `hooks/hooks.json` — plugin hook wiring (SessionStart / Stop / UserPromptSubmit /
  PreToolUse / PostToolUse) dispatching through the Claude Code adapter to `core/hooks/`
  via `${CLAUDE_PLUGIN_ROOT}`.
- `commands/project-init.md` — `/project-init` slash command to scaffold project-level files.
- `LICENSE` — MIT (was TBD).

### Changed
- README now leads with the Claude Code plugin install path; shell `setup.sh` remains for
  Codex/Gemini or non-plugin use.

## [0.1.0] — 2026-05-18

### Added
- Initial AI-agnostic agent framework structure
- 3-AI adapter layer: Claude Code, Codex CLI, Gemini CLI
- Canonical hook protocol (`docs/hook-protocol.md`): stdin JSON event + stdout decision JSON
- Core hooks (`core/hooks/`): ~25 portable hooks for security, session coordination, plan-mode, TDD enforcement, drift detection
- Core infra (`core/infra/`): multi-session worktree coordination (`agent-session.sh`), commit/PR automation (`auto-ship.sh`), session store, supervisor goal mode
- Core git-hooks (`core/git-hooks/`): pre-commit (gitleaks + hardcoding scan) + pre-push (gitleaks + secret diff scan)
- Generic policy rules (`rules/`): 7 critical + 12 lazy-loaded archive
- Generic agents (`agents/`): code-reviewer / architect / build-error-resolver / security-reviewer / performance-optimizer / test-engineer / docs-writer / refactor-cleaner / tdd-guide / copy-humanizer
- Generic skills (`skills/`): wrap, supervise, tdd, diagnose, grill-me, grill-with-docs, improve-codebase-architecture, caveman, api-and-interface-design, incremental-implementation, source-driven-development, deprecation-and-migration, design-variant-mockup, hook-reproduce-test, triage-external-draft, weekly-digest
- Codex-native skills (`codex-skills/`): code-explorer, code-reviewer, database-reviewer, planner
- Templates (`templates/`): generic CLAUDE.md / AGENTS.md / GEMINI.md / RTK.md / karpathy.md / hook-config.yml / project-rules.md / gitleaks.toml
- `setup.sh` 4-mode installer: `--claude` / `--codex` / `--gemini` / `--project` / `--hooks-only`
- GitHub Actions workflow templates (`github/workflows.template/`): secret scan + lint

### Changed
- N/A (first release)

### Archived
- `legacy/v0-mirror-2026-05-12/` — original mirror skeleton + domain-specific assets from the prior project version. See `legacy/v0-mirror-2026-05-12/ARCHIVE-NOTE.md` for migration guide.

### Security
- Base `gitleaks.toml` with 100+ built-in patterns + extensible per-project allowlist
- Generic content-scan hook with 7 default patterns covering Python/Node secret-file readers, hardcoded credentials, OpenAI-style `sk-...` tokens, JWT literals, Bash secret-readers, and exfiltration via `find -exec` (see `core/hooks/secret-content-scan.py` for full pattern list)
- Project-configurable risk-area abort codes via `templates/hook-config.yml.template`

[Unreleased]: https://github.com/joymin5655/Agent/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/joymin5655/Agent/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/joymin5655/Agent/releases/tag/v0.1.0
