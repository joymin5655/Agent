# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- **`legacy/trim-2026-07-04/` removed from the shipped tree — the last `legacy/`
  payload is gone (preserved on tag `archive/legacy-trim-2026-07`).** The plugin
  package *is* the git tree (no exclusion manifest), so these 44K of retired
  agents/skills rode into every release. The six `legacy/`-scoped exclusion
  rules (`gitleaks.toml`, `sanitize-audit.sh`, `supply-chain-scan.sh`,
  `doc-reality.sh`, `check-hardcoding.py`, `secret-content-scan.py`) stay
  unchanged: CHANGELOG entries
  still reference historical `legacy/…` paths, and doc-reality needs the
  exclusion to keep ignoring them. Recover anything with
  `git show archive/legacy-trim-2026-07:legacy/trim-2026-07-04/<path>`.
  (Benchmark input: netwaif/multi-agent-starter ships a deliberately minimal
  generated tree — our tree-is-the-package model makes git removal + archive
  tag the only diet mechanism.)

### Changed
- **`setup.sh` installs now end in post-install validation.** Every install
  path auto-runs the existing read-only `--doctor` diagnosis and the script
  exits non-zero on FAIL rows, so a broken install fails loudly at install
  time instead of at first use (`AGENT_SETUP_NO_DOCTOR=1` skips — test seam /
  air-gapped bootstrap). Install paths also self-heal lost exec bits on
  `core/hooks/*` and `adapters/*/adapter.sh` before validating, so
  exec-bit-hostile distribution paths (ZIP download) don't hard-fail a check
  the script never remediated. Pattern adopted from multi-agent-starter's
  generate→`validate.py` PASS/FAIL pairing, reusing our existing doctor
  instead of a new validator.
- **`apply_template()` is now idempotent (checksum update mode).** A target
  byte-identical to the fresh render reports `up-to-date` with no prompt;
  only a target that actually differs (user-customized, or template changed)
  asks before overwriting. Re-running setup over an existing install is now a
  quiet no-op update pass instead of a prompt per file — the equivalent of
  multi-agent-starter's update mode ("overwrite system files, preserve user
  data") for our template set.
- **Gate-registry correction: quality-completion RETIRE-CANDIDATE →
  KEEP-CONDITIONAL (same-day supersede).** The retirement investigation refuted
  its own premise: `session-quality-gate.py` is also the enforcement layer for
  the landed **P3-1 `session.completion_tests`** feature, making it a
  conditional-path gate (fires only where a consumer declares completion tests
  or the default `src/` style scan matches) — zero in-window firings is an
  adoption gap, not dead wiring, and the gate is battery-verified in verify-all.
  Deleting it would have silently unshipped P3-1. Recorded as a correction row
  rather than rewriting history; real follow-up is W-6 generalization/adoption.
  Lesson reinforced: a DEAD flag on a conditional-path gate needs a
  wiring-vs-adoption diagnosis before any retirement verdict.

- **Gate-registry DEAD review (2026-07-15) + audit follow-up bookkeeping.** The
  four gates the T-2 digest flagged DEAD got their review verdicts recorded and
  `last_reviewed` bumped: project-policy KEEP (conditional-path), r4-mutex KEEP
  (contention gate, active multi-session ops), context-mode KEEP-CONDITIONAL
  (tied to the plugin's W-10 review), quality-completion **RETIRE-CANDIDATE**
  (two audits agree: wired but never fired, sink never created — retirement is
  a separate reviewed code PR). New backlog row **W-10**: third-party
  plugin-injection pollution scan (observed live: a plugin's injected
  `<context_window_protection>` block acting as session-wide instructions,
  independently flagged by two research subagents — the mirror image of the
  P3-4 self supply-chain scan). E-1 gains a design-input note: llm-council's
  anonymous peer-review → chairman pattern as an option for the real-LLM judge
  track (pattern only, no code import). Docs/bookkeeping only, no behavior.

- **`docs/benchmark/landscape.md` 2026-07-14 spot re-check.** Five-lane web
  re-verification of the 2026-07-08 snapshot: claude-flow renamed **ruflo**
  (2026-02-27, npm/CLI unchanged); Aider marked effectively stalled (last
  release 2025-08); new "Field shift" note — Anthropic Dynamic Workflows GA
  (Pro plan 2026-07-02) erodes orchestration-first third parties but not this
  harness's governance position; re-check found no surveyed leader closing the
  prompt-only-enforcement gap. Survey-only change, no behavior.

### Added
- **Evidence-first inventory — kill the ghost-specialist deadlock at its root
  (`rules/policy/evidence-first.md` + `core/hooks/agent-inventory.py`).** A gate that
  demands a specialist with no in-runtime provider deadlocks the session: the gate blocks
  the work, and the very thing that would unblock it can't be dispatched (observed live —
  a stale plugin cache required `ui-ux-director`/`fe-architect`/… agents that exist only in
  the `legacy/` v0 mirror, not in the active registry). New policy `evidence-first.md`
  names the underlying failure — *asserting present state from memory instead of a
  same-turn read* — and forbids demanding a provider you haven't confirmed exists. Enforced
  by a new SessionStart truth pass, `agent-inventory.py`, which reconciles the **active**
  registry (including consumer overrides CI never sees) against the agent `*.md` providers
  actually beside it: `real` (id has a sibling provider), `ghost` (id has none → quarantined,
  never demandable), `discovered` (an unwired provider). **A filename is not evidence** — a
  provider is a `.md` that carries YAML frontmatter, i.e. actually *defines* an agent. A
  stray `README.md` in the registry dir is not dispatchable, so it must never be
  `discovered` (`--sync` would wire it in as a bogus agent), and an id backed by a
  frontmatter-less `.md` lands in `ghost`, not `real` — the file exists but the runtime
  cannot dispatch it, and calling that "real" *is* the deadlock. This is also what makes
  the inventory strictly stronger than `supervisor.py`'s own `is_real_agent()` file-exists
  check rather than a restatement of it, so `has_provider()`'s AND actually buys something. The verdict is written to
  `.agent/state/agent-inventory.json` (gitignored runtime state — no git churn, no
  drift-guard conflict) and `supervisor.py` consumes the `ghost` set as an extra
  dispatch-time quarantine source (`has_provider`), **fail-open** so a session with no
  inventory behaves exactly as before. Opt-in hybrid auto-correct (`--sync` /
  `AGENT_REGISTRY_AUTOSYNC=1`) additively wires `discovered` providers into the registry,
  copying each `model:` straight from the agent's own frontmatter so the additive write
  can't introduce the model drift `registry-drift.sh` check 4 forbids — it only ever adds,
  never edits or removes. Fail-open is end-to-end: the SessionStart path, `supervisor.py`'s
  `main()`, **and** the manual CLI all exit 0 on a malformed consumer registry — the
  reconciler must never itself become the thing that breaks a session. `AGENTS.md` links
  the rule from "When in doubt." Battery `core/tests/agent-inventory-test.sh` (8 checks:
  real/ghost/discovered classification, provider-needs-frontmatter, inventory persistence +
  ghost-set readback, additive-sync-with-model-copy, fail-open on no registry, fail-open on
  a malformed one), auto-discovered by `verify-all.sh`.
  `supervisor-dispatch-test.sh` gains two cases:
  **15 — a ghost that guards a `file_globs` path**, listed ahead of a real guard on the same
  path. The existing ghost case (7) is a *keyword* ghost declaring no globs, so it could
  never reach the file-glob matcher — leaving the deadlock's other form untested, and that
  form is the incident's own example (a retired `edge-fn-dev` guarding `**/functions/**`).
  It pins both halves of the contract: the ghost is hinted and skipped (`continue`, **not**
  `return`, so it cannot swallow the guard behind it), and no emitted `ask` ever names an
  undispatchable specialist.
  **16 — inventory quarantine end-to-end**: a provider `.md` is on disk (so `is_real_agent()`
  passes) but the reconcile rejected it, and `has_provider()` must quarantine it anyway.
  This is the one case where the inventory layer adds power over the file-exists check, so
  it is the case that proves the layer is load-bearing rather than decorative.
- **`model-routing-observer.py` — measure the model-tier convention.** A 2026-07-11
  transcript audit confirmed the call-time `model`-override convention is not
  followed: 7/7 subagent dispatches in the audited session inherited the session
  top model. New PostToolUse (Task/Agent) pure observer classifies every dispatch
  as `override` / `pinned_specialist` / `inherit_top` into
  `.agent/logs/model-routing.jsonl` (analyze:
  `jq -r .verdict … | sort | uniq -c`) — measured before enforced, per the gate-
  registry philosophy. Never blocks, emits nothing, exit 0 always. Battery
  `model-routing-observer-test.sh` (15 checks). Companion policy fixes:
  `docs/model-routing.md` gains a "Built-in agents (Claude Code)" section
  (Plan=TOP inherit, Explore=MID default / LOW for bounded lookups — a deliberate
  exception to fan-out-LOW), and `/verify-completion`'s general-reviewer dispatch
  now requires an explicit workhorse-tier override.
- **Skill A/B evaluation dataset (H-3, seed).** `evals/datasets/skill-ab.jsonl` is the
  labeled seed for measuring whether a shipped skill earns its keep: does its
  `description` route the right requests (and not the wrong ones), and does running
  *with* the skill produce what a no-skill baseline would miss. **35 cases** across the
  5 shipped skills (`spec`, `supervise`, `verify-completion`, `wrap`, `harness-audit`) —
  3 `assertion` cases + 2 trigger-positive + 2 trigger-negative each. Trigger labels are
  grounded in each skill's own `when_to_use` (positives) and `NOT` clauses (negatives),
  including cross-skill discriminators (e.g. "execute the approved plan" must route to
  `supervise`, not `spec`); every assertion's `rationale` quotes the skill's shipped
  description, so the seed is grounded, not invented. Fail-closed floor
  `evals/baseline-skill-ab.json` (`min_cases`, `min_assertions_per_skill` = 3, the
  shipped-skill list). New battery `core/tests/skill-ab-dataset-test.sh` (21 checks)
  validates only the seed's shape — parse, per-`kind` required fields, unique slugs,
  unknown-skill rejection, the ≥3-assertions-per-skill floor, ≥1 trigger-positive and
  ≥1 trigger-negative per skill, and that every named skill is a real shipped
  `SKILL.md` — with 7 malformed RED fixtures proving each guard goes red; it calls no
  model and is auto-discovered by `verify-all.sh`. The A/B **runner** that executes
  with-skill vs baseline and scores the assertions is a later increment (H-3 본체). See
  `evals/README.md` (Skill A/B track) for the n=35 and honest-ceiling disclosure.
- **Failure-mode grader rubric (L-1, doc portion).** `evals/failure-modes.yaml` replaces
  the autonomous loop's single opaque `harness_score` scalar with a checklist of **12
  named failure modes**, each distilled from a real adversarial-review catch in this
  campaign (`caught_in` cites the item + PR): silent-drop, vacuous-green, vacuous-parity,
  glob-scope-miss, bypass-flag, unanchored-skip, infra-as-verdict, lexical-containment,
  injection-breakout, loose-coercion, stale-ssot, review-false-clean. Every mode carries
  a `detection_signal` (the observable a grader looks for) and a `grader_check` (the
  boolean question whose safe answer the candidate must satisfy). Naming the holes makes
  the grader adversarial the way a human review is — "strengthening verification" without
  naming failure modes does not stop metric-gaming (proxy-hacking measured at 73.8%). The
  §5.1 correspondence table's `val_bpb` row is rewritten to describe per-mode
  `mode:<id> PASS|FAIL — reason` emission, keeping a rollup `harness_score:` line on
  **both** the GATE-pass and GATE-fail paths so the §5.2 grep consumer and the results.tsv
  status enum stay intact (GATE-fail emits `harness_score: 0` = discard, never an empty
  grep that would misclassify as crash). New battery `core/tests/failure-modes-test.sh`
  (25 checks) validates the file's shape through the same PyYAML parser the grader will
  use — schema_version, the ≥8-mode floor, unique kebab-case ids, and every required
  field non-empty — and proves each guard can go red with six malformed RED fixtures
  (too-few / missing-field / blank-field / duplicate-id / non-kebab-id / unparseable),
  auto-discovered by `verify-all.sh`. The `grade.sh` implementation that consumes the
  rubric is deferred to a later batch.
- **`plan-scope-allow.py` — plan-approved auto-allow accelerator.** New PreToolUse
  (Write/Edit/MultiEdit, last in chain) hook: once the user approves a plan this
  session (the `plan-gate.py` flag), in-workspace non-risk edits emit
  `permissionDecision: "allow"` so the native permission prompt stops firing on
  every step of approved work. First permission-weakening hook in the harness —
  emits only allow-or-silence (never deny/ask), fail-open direction is silence,
  risk areas (spec-gate `GUARD_PATTERNS`) + `.agent/hook-config.yml` + `.git/` +
  out-of-workspace (realpath containment) always pass through, env-gated
  `AGENT_PLAN_ALLOW_MODE=on` (default off, ships dark), sink
  `.agent/logs/plan-scope-allow.jsonl`, registered in `docs/gate-registry.md`.
  Battery `plan-scope-allow-test.sh` (27 checks incl. symlink/`..` escapes,
  case-evasion, sink discipline). Side fix: README/README.ko hook-count drift
  (17 → live 19) corrected.
- **`skills/harness-help/` — router skill** (ask-matt pattern, user-invoked):
  main flow `/spec` → approval → `/supervise` → `/verify-completion` → `/wrap`,
  standalone `/harness-audit`, and what to do when a gate interrupts. Sync rule:
  any skill add/remove updates the router in the same commit.
- **`docs/skill-authoring.md`** — skill-writing reference distilled from Matt
  Pocock's `writing-great-skills` (MIT, attributed): invocation axis, one trigger
  per branch, information hierarchy, leading words, checkable completion
  criteria, failure modes. Applied as a surgical pass over the five existing
  SKILL.md files (trigger dedup + explicit completion criteria).
- **Gate registry + fire-rate digest (T-2).** `docs/gate-registry.md` is the SSOT
  list of every deny/ask/block gate with the model weakness it assumes and a
  `last_reviewed` date (an assumption expires). `telemetry-digest.sh --gates`
  cross-references it against the runtime firing logs and reports per gate:
  **DEAD** (0 in-window firings), **FATIGUE** (firings ≥ `--fatigue`, default 50),
  **STALE** (`last_reviewed` + `--stale-days`, default 90, is past), and
  **UNINSTRUMENTED** (emits a decision but writes no log — reported honestly, not
  mislabeled DEAD). Test-reproduction records (`reproduce_test:true`) are excluded
  from fire-rate so batteries can't inflate it. Still an observer (exit 0 always);
  `telemetry-digest-test.sh` gains a synthetic-registry battery covering all four
  classes plus the reproduce-test exclusion and missing-registry fail-safe.
- **Runtime enforcement of `risk_areas.secrets.paths` (P1-8).** `pre-tool-guard.sh`
  now reads project-declared secret paths from `hook-config.yml` (via a bounded,
  metacharacter-rejecting `hook_config.load_risk_area_secret_paths` loader) and
  denies read/copy/exfil access to them — closing a field that shipped as schema
  but was never read at runtime. Additive: the built-in `secrets/` guards run first
  and are never weakened; a config value can only add literal paths, never inject a
  pattern. `risk-area-wiring-test.sh` proves enforcement + loader safety bounds.
- **Remote-URL credential scan + gitleaks fire drill (W-3).** A token baked into a
  git remote URL lives in `.git/config`, invisible to every content scanner —
  `core/git-hooks/scan-remote-url.py` flags an http(s) remote whose userinfo carries
  a password or a token-shaped value (no false positives on ssh / clean / bare-username
  URLs), wired as pre-push step 0 and a `/wrap` pre-flight. `core/infra/gitleaks-fire-test.sh`
  plants a synthetic secret matching the repo's own rule and asserts gitleaks catches
  it (PASS = gate live, FAIL = misconfigured allowlist, exit 2 = gitleaks absent/SKIP),
  so a clean result can be trusted. `remote-url-scan-test.sh` covers both.
- **Tests for plan-gate and tdd-guard (P1-3).** Both hooks previously shipped
  untested. `plan-gate-test.sh` (7 checks; new `AGENT_PLAN_FLAG` seam so tests never
  clobber the live approval flag) and `tdd-guard-test.sh` (12 checks; isolated mktemp
  git repos, RGR red/green/no-test verdicts). tdd-guard's misleading comments claiming
  hook-config override of its risk-area patterns were corrected to match reality
  (the override is a tracked follow-up, not yet wired).

- **Real-LLM semantic judge (E-1, batch-3) — out-of-CI.** `evals/judges/llm-judge.py`
  is the layer above the deterministic floor: it catches a cited test that carries a
  real assertion (so `reference-judge.py` CONFIRMs it) yet never exercises the claimed
  change — asserting on an unrelated function, a stale inline copy, a mock, or a
  tautology. It conforms to the same verifier interface
  (`llm-judge.py --root <root> <claim.json>` → shared verdict JSON), reads the cited
  `test_sources` and claimed `files` (bounded, realpath-contained), embeds them as
  delimited DATA in a prompt, and asks a real model via a subprocess CLI
  (`LLM_JUDGE_CMD`, default `claude -p`; `LLM_JUDGE_MODEL` / `LLM_JUDGE_TIMEOUT`).
  Refute-by-default (unparseable output, missing/mistyped keys, empty `test_sources`,
  a root-escaping path, or confidence `< 0.6` → REFUTED) is kept distinct from
  fail-closed on infrastructure (absent CLI, timeout, nonzero exit, empty stdout, or an
  invalid strict-integer timeout → clear stderr error, nonzero exit, and no verdict on
  stdout, so a broken backend never masquerades as a confident label). Prompt-injection
  is contained, not merely hedged: embedded evidence is wrapped in **per-call nonce**
  markers (untrusted content cannot forge the closing marker) and any marker-shaped
  substring in content is **defanged** before embedding, so a test that embeds a literal
  closing marker cannot break out of the DATA quarantine. Labeled dataset
  `evals/datasets/llm-judge.jsonl` (10 semantic-hard cases, 5 CONFIRMED / 5 REFUTED —
  the deterministic floor scores 5/10 on it, by construction) with fail-closed floor
  `evals/baseline-llm.json` (min_cases 10, enforced by the LOCAL run, not CI). New
  deterministic battery `core/tests/llm-judge-test.sh` (34 checks) drives the adapter
  with a MOCK CLI, so it needs no real model and runs offline — auto-discovered by
  `verify-all.sh`. CI is untouched: it must never call a model, and the track runs
  locally with `--repeat 1` (Pass^k's identical-verdict rule would be dishonest for a
  nondeterministic judge — flakiness is to be observed, not hidden). See
  `evals/README.md` (Real-LLM track). Honest ceiling stated: nondeterminism near the
  threshold, a residual prompt-injection risk from hostile prose that stays *within* the
  data block, and model-availability dependence.
- **Teaching gates (T-1).** Every `deny`/`ask`/`block` reason emitted by
  `pre-tool-guard.sh`, `secret-content-scan.py`, `check-hardcoding.py`, and
  `session-quality-gate.py` now carries a fixed `WHY:` tag (which rule fired and
  why) and a `FIX:` tag (the concrete allowed alternative), so a blocked agent
  can self-correct instead of routing around the gate. Machine-enforced: the
  per-hook batteries assert `WHY:`/`FIX:` on every non-allow fixture, and a new
  `core/tests/check-hardcoding-test.sh` (14 checks) gives that hook its first
  dedicated battery.
- **Skill negative-triggers (T-3).** All five shipped `skills/*/SKILL.md`
  descriptions now include at least one `NOT …` negative example (when *not* to
  fire), enforced as `registry-drift.sh` check 7 with fixtures (no-`NOT` → FAIL,
  `NOT` present → PASS, no frontmatter → FAIL).
- **Doctor codex-profile check (M-4).** `setup.sh --doctor` gains check 13:
  WARN when the `quick`/`deep` tier-profile files are missing beside the local
  codex config (`CODEX_CONFIG` seam; skipped when no codex config exists) —
  the same "declared template vs actual" observer family as the plugin-cache
  and command-scan checks. Fixtures cover present/missing/absent-config.

### Fixed
- **Guard false-positives (W-7).** `pre-tool-guard.sh` no longer blocks a commit
  whose *message* merely mentions a destructive command (`git commit -m "fix: guard rm -rf / patterns"`):
  a preamble strips the inert message payload before the destructive guards
  (1–4) scan — but only provably-inert shapes (single-quoted, `$`/backtick-free
  double-quoted, or a **quoted**-delimiter `<<'EOF'` heredoc). An unquoted
  `<<EOF` body still command-substitutes at shell-eval time, so it stays fully
  scannable; the secrets guards always scan the full command. A new
  `core/tests/pipefail-idiom-scan.sh` gate is the W-7(2) regression floor:
  it flags unguarded zero-match count pipes (`grep … | wc -l`, `n=$(grep -c …)`)
  in strict-mode runtime scripts, self-checking against a bad/good fixture so
  it can't rot to always-green; the safe idiom is documented in AGENTS.md.
- **Graceful-wrap traversal guard.** `supervisor-goal.sh`'s `_emit_graceful_wrap`
  (the budget-limited stub writer) now refuses a traversal-shaped slug the same
  way `write_record_stub` does, so a weird plan slug can never place the stub
  outside its configured dirs (fail-safe skip; regression-tested).

- **Repo-native execution ledger (F-2).** `supervisor-goal.sh complete` now
  drops `.agent/plans/<slug>/RECORD.md` — a mechanical execution ledger
  (waves from the live DB, plus PR / audit-verdict / carried-items slots the
  supervise skill fills) — so an execution record exists even on runtimes
  with no global recording layer. Session narrative stays with the global
  layer; the two never duplicate. Contract: never clobbers a RECORD.md the
  skill already wrote, and a ledger write failure never blocks completion
  (fail-safe); `AGENT_PLANS_DIR` is the test seam. `/supervise` Step 5 writes
  the same facts as its closing discipline on non-goal runs. A traversal-shaped slug (path separators or `..`) is
  refused fail-safe — the ledger can never land outside the plans root (a
  hardening from this change's adversarial review). New battery
  `core/tests/supervisor-goal-record-test.sh` (12 checks, isolated in mktemp
  git repos). Same-PR bugfix the battery exposed: `cmd_init`'s
  `objective="${4:-$slug}"` referenced `slug` on the same `local` line —
  bash 3.2 + `set -u` crashes on every objective-less
  `init <slug> <waves>` (latent: the documented 4-arg form never hit it);
  the declaration is now split.
- **`/spec --interview` — opt-in deep-interview submode (F-1).** For requests
  fuzzy enough that a wrong guess commits the spec to the wrong shape, the
  one-shot "ask if ambiguous" brainstorm gains a structured question loop:
  an unknowns table marking each row decision-changing (Y/N), batched
  questions over the Y rows only (at most 4 per round, options + recommended
  default named), re-scoring after each round (answers resolve rows and
  surface new ones — decision-tree pruning), and two termination conditions
  (zero open decision-changing unknowns, or 3 rounds — leftovers carry into
  `spec.md` under `## Open questions`). The Q/A trail lands in
  `## Interview log`, so the spec shows why it has its shape. Opt-in by
  design: simple requests keep the single pass, and `spec-gate.py` is
  untouched — the enforcement boundary neither knows nor cares which submode
  produced the artifacts.
- **Delegation contract + orchestration guards (O-1).**
  `skills/supervise/templates/delegation-contract.md` is the per-dispatch
  contract skeleton: the four elements (goal / output format / tools & scope /
  boundaries), an explicit `**model**:` field (execution waves name their tier
  instead of inheriting the expensive session default), and three sections
  absorbed from the 2026-07-10 external-harness comparison — Self-contained
  (subagents inherit no history; the contract carries every path, decision,
  and constraint), Constraints re-injection (each wave re-states its relevant
  constraint slice, not whole rulebooks), and Executable acceptance criteria
  (verify = a command's exit code by default; prose only with a stated
  reason). Wave shaping travels with it: fan-out cap 3–5 with a worked
  split-at-the-cap example, write single-threading (one writer per fileset),
  and verifier isolation (fresh spawn, end-state only). `/supervise` Step 2
  now composes every dispatch from the template; `/spec` Step 3 defaults
  `→ verify:` to an executable check. The guardable half is machine-enforced:
  `registry-drift.sh` gains check 5 (review/verify agents must carry a
  read-only toolset — a write-armed or allowlist-less reviewer fails) and
  check 6 (a tree that ships `skills/supervise` must ship the template with
  its `**model**:` field), each with injected-defect fixtures in
  `registry-drift-test.sh` (24 checks — inline and YAML-block `tools:` forms
  both parsed; a write tool smuggled into either form fails).
- **Clean-install CI smoke (M-5).** New `clean-install` CI job: installs all
  three runtimes into a scratch `$HOME` non-interactively
  (`AGENT_SETUP_YES=1 bash setup.sh --all`), then asserts the install itself —
  all three runtime configs exist and the `{{FRAMEWORK_ROOT}}` placeholder was
  actually templated (anti-vacuous: a no-op or mis-templated install must not
  go green; this assert step, not the doctor, carries the install
  verification, since the doctor's checks are repo/env-scoped and tolerate an
  empty home — a gap this change's adversarial review measured live). The
  doctor must then report 0 fail against the scratch home, and a built-in
  mutation probe (a hook stripped of its exec bit must turn the doctor red,
  else the job fails) keeps the job's green load-bearing. Closes the
  cold-install gap the landscape survey flagged: "install once, use
  everywhere" was previously verified only by hand.
- **Harness self-audit skill + extracted registry-drift gate (H-2).**
  `skills/harness-audit/SKILL.md` is an agent-driven, read-only self-audit that
  sits *on top of* the machine gates: one `verify-all.sh` dry-run, a per-check
  PASS/FAIL/SKIP table, an explicit citation of the P1-1 doc-reality verdict, and
  for each failure a root-cause + fix + backlog-follow-up. It interprets the gates;
  it does not reimplement them. Enabling refactor: the CI `validate-plugin` job's
  four inline checks (manifest required fields; hooks.json → executable core-hook
  resolution; agent `name:` frontmatter; registry↔agent model agreement) are
  extracted to `core/tests/registry-drift.sh` (a standalone, cwd-independent gate
  with a `REGISTRY_DRIFT_ROOT` test seam) with a non-vacuous fixture battery
  `core/tests/registry-drift-test.sh` (11 checks — each drift class injected and
  asserted caught). The gate is auto-discovered by `verify-all.sh`, closing the one
  machine check the unified runner was missing.
  Same-PR hardening from the 2026-07-10 workflow audit: the skill gains a
  runtime-layer step (`setup.sh --doctor` + `core/infra/telemetry-digest.sh`,
  with an unmeasured-is-unmeasured reporting rule) and a negative trigger in
  its description (T-3 applied early); doctor gains **check 12 — the
  phantom-command scan** (a runtime `commands/*.md` invoking a script that
  does not exist on this machine is a live failure path — reported as a
  WARN-only observation; `AGENT_COMMANDS_DIR` test seam, relative refs
  resolved against the runtime root, unexpanded `$VAR` refs skipped, and
  control characters stripped from echoed refs — an escape-sequence display
  spoofing hardening from this change's security review) with 7 new fixture
  checks in `setup-doctor-test.sh` (25 checks) — the rule-ification of a
  real orphaned-command failure found live in that audit.
  Backlog bookkeeping lands in the same PR: new §4.11 F-series (F-1 opt-in
  `--interview` deep-interview submode for `/spec`; F-2 repo-native
  `RECORD.md` execution ledger), the G-2 global-hygiene decision record, and
  a matching `F-rows` series check in `doc-reality.sh`.
- **doc-reality gate — the harness gates its own doc drift (P1-1).**
  `core/tests/doc-reality.sh` (+ a 39-case battery) fails CI when a shipped doc
  contradicts the repo: (A) a referenced in-repo path that does not exist —
  scanned across every tracked `*.md` (recursive; nested READMEs and `docs/**`
  included), minus the forward-looking plan, the backward-looking CHANGELOG, and
  `legacy/`; fenced code blocks (0–3-space fences, CommonMark-tracked) are
  illustrative examples and stripped, while an unterminated fence is itself a
  malformed-doc failure; (B) the six backlog-count series and (C) the four
  artifact counts declared in the plan §7, cross-checked against the live repo.
  New CI job. Hardened over four adversarial-review rounds; also completed the
  phantom-ref cleanup it surfaced (`core/hooks/README.md`,
  `core/hooks/secret-content-scan.py`, `core/hooks/context-mode-guard.sh`,
  `rules/policy/strong-goal-template.md`).
- **Eval harness — labeled dataset + Pass^3 + regression gate (E-1, deterministic
  layer).** `evals/run-evals.py` grades the completion verifier
  (`core/infra/completion-verify.py`) against
  `evals/datasets/completion-verify.jsonl` (12 labeled CONFIRMED/REFUTED cases):
  each claim must produce its labeled verdict, the suite runs three times (Pass^3)
  requiring identical results, and `evals/baseline.json` gates on a
  coverage/accuracy regression. New `evals` CI job; runner battery
  `core/tests/evals-test.sh` (28 checks). The LLM-judge semantic layer and the
  skill A/B dataset are later increments.
- **Eval harness — semantic track, deterministic floor (E-1, batch-2).** A judge
  that catches *green-by-construction* tests — a cited test that "passes" but
  asserts nothing real. `evals/judges/reference-judge.py` consumes a claim's
  `test_sources` and classifies each file **meaningful** iff it holds at least one
  real, non-constant assertion (line-based bash+python heuristics), emitting the
  shared verdict schema; it is refute-by-default, reads are bounded, and no path
  escapes `--root`. It is deliberately biased to **false-REFUTED over
  false-CONFIRMED** (a completion gate must never bless a hollow test). Graded by
  the existing runner against `evals/datasets/semantic-judge.jsonl` (17 labeled
  cases, 8 CONFIRMED / 9 REFUTED) under Pass^3 + `evals/baseline-semantic.json`
  regression gate; wired as new steps in the `evals` CI job; judge battery
  `core/tests/reference-judge-test.sh` (52 checks, incl. leak-safety on unsafe
  `../`/absolute/**symlink** paths and python constant-comparison triviality
  across decimal/hex/octal/binary/underscore/scientific number forms). This is the **deterministic floor** only: it catches
  *syntactic* triviality (no real / only constant assertions), not *semantic*
  triviality (a real-looking assertion that never exercises the changed code
  path) — that deeper judgment needs a real model and runs via
  `skills/verify-completion` or a pluggable `--verifier`, not in CI.
- **Unified verification runner — one command runs the whole suite (P1-2).**
  `core/tests/verify-all.sh` fulfills the README "Verification" one-command
  promise. It **discovers** the check set dynamically — every `core/tests/*.sh`
  except the runner and its own test — so the four gates, all thirteen `*-test.sh`
  batteries, and any script added later are picked up with no edit here (the
  anti-rot property). It then runs the two evals layers (the exact CI invocation)
  and gitleaks, reporting PASS / FAIL / **loud SKIP** per check and a final tally;
  a silently-skipped check reported as pass is exactly the false-green this repo
  guards against. It is `set -u` (not `-e`) so every check runs even when one
  fails, isolates each in a subshell, and **refuses to report success on an empty
  discovery** (zero checks → non-zero exit, not a vacuous green). Battery
  `core/tests/verify-all-test.sh` (21 checks) proves completeness against the live
  dir (no hardcoded list), fail-propagation, all-green, list-equals-run, the
  empty-set floor, and that an absent gitleaks is counted **skipped, never passed**.
  New `verify` CI job runs the self-test then the full discovered set — the sole
  CI executor of the ten checks that had no dedicated job, and auto-inclusive of
  future ones.

### Changed
- **README synced to 0.2.5 reality.** Version badge/status, skill count and
  table (spec + verify-completion were missing), the model-tier paragraph
  rewritten to match `docs/model-routing.md` (judgment inherits session-top;
  reviewer pins are the only machine-enforced part; implementation/mechanical
  dispatch via per-call override — conventions), and the docs index gains
  model-routing.md + benchmark/landscape.md.
- **Cross-AI parity gate strengthened (P1-6).** `core/tests/adapter-parity.sh` now
  asserts the three adapters (claude-code / codex / gemini) return the *same
  normalized decision* for a logically-identical event — and the same full decision
  JSON — across all three verbs (deny/allow/ask) and both `tool_input` shapes, each
  driven through a hook that actually reads that shape so a mistranslated field flips
  the decision: the command shape via `pre-tool-guard.sh`, the file/content shape via
  `check-hardcoding.py` (deny on hardcoded content, allow on clean) — plus
  shell-special (quoted) command and content. The prior version only checked a "deny"
  substring per adapter independently, so two adapters could disagree and still pass.
  24 parity assertions; exit 1 on any divergence.
  (Kept the filename: `cross-ai-parity.sh` named in the plan was a phantom P0-1
  removed, and the docs already reference `adapter-parity.sh`.)

### Removed
- **`legacy/v0-mirror-2026-05-12/` retired from the shipped tree — defence-in-depth
  for the ghost-specialist deadlock (preserved on tag `archive/v0-mirror`).** The
  plugin package *is* the git tree (`marketplace.json` declares `"source": "./"` and
  there is no exclusion manifest — the only things missing from a release are the
  gitignored ones), so the v0 mirror rode into **every** release: 194 files, 1.3 MB,
  including **33 retired agent `.md` providers** (`ui-ux-director`, `fe-architect`,
  `edge-fn-dev`, …) sitting next to **two 64-entry `master-registry.json`** files.
  That adjacency is exactly the shape `is_real_agent()` trusts — a registry id is
  "real" iff a sibling `<id>.md` exists — so any copy of that tree into an active
  registry path resurrects the deadlock the rest of this release exists to kill.
  `find_registry()` never reaches into `legacy/`, so this was a *latent* trap and dead
  weight rather than a live path (the live defence is `agent-inventory.py` above);
  removing it means a retired provider can no longer be resurrected by a stale copy.
  `legacy/trim-2026-07-04/` stays — its 3 agent `.md` files have **no** sibling
  registry, so they cannot satisfy the predicate, and keeping `legacy/` alive keeps
  the five `legacy/`-scoped exclusion rules (`gitleaks.toml`, `sanitize-audit.sh`,
  `supply-chain-scan.sh`, `doc-reality.sh`, `check-hardcoding.py`) valid and unchanged.
  Recover anything with `git show archive/v0-mirror:legacy/v0-mirror-2026-05-12/<path>`.

### Security
- **Codex/Gemini adapter synthetic-mode no longer builds canonical JSON by string
  interpolation.** `adapters/{codex,gemini}/adapter.sh` constructed the event JSON
  by interpolating `--command`/`--content` into a `python3 -c` literal
  (`'''$TOOL_CMD'''`), so a value containing a quote, newline, or `'''` broke the
  literal — mis-parsing the event (a cross-adapter parity break) and, worse, letting
  a crafted command inject python and force an `allow`, bypassing the very guard the
  adapter feeds. The values are now passed via environment variables to a fixed
  python program (no interpolation), carrying any command/content verbatim.
  Regression-locked by the new quoted-command parity cases.

## [0.2.5] — 2026-07-08

### Changed
- **Model policy: judgment stays up, hands get dispatched.** The supervise
  Model policy now names all four judgment classes (planning/design, wave
  dispatch decisions, gate verdicts & abort/advance, result synthesis) as
  session-top work, and adds an execution-dispatch row: implementation waves
  dispatch at the workhorse tier and mechanical work at the low tier via an
  explicit per-call `model` override — inline execution at the session's top
  model is the expensive default this rule exists to prevent. All of this is
  documented convention (only specialist pins are CI-enforced); O-1's
  delegation-contract template gains a required `model` field in its
  done-condition. `docs/model-routing.md` adds the matching orchestration-
  judgment row and reworks the Implementation row.
- **Doctor check 10 now scans every cached plugin, not just this harness.**
  Any `<marketplace>/<plugin>/` with more than one cached `<version>/` is
  WARN-listed (a live third-party dual-version cache motivated the
  generalization — the same stale-cache drift class check 10 was built for).
  WARN-only, absent cache root still passes. Fixtures: 3 new cases
  (third-party dual → WARN, multi-plugin single → PASS, stray file at
  version depth ignored).

### Added
- **Floors: long-horizon implementation is not a LOW-tier task.**
  `docs/model-routing.md` cites an external program-based-verifier benchmark
  (datacurve-ai/deep-swe, 2026-05 leaderboard, press-reported) showing
  light-tier models trailing the top tier by ~40+ points on long-horizon SWE
  work — cost/performance reference data reinforcing that LOW is for bounded
  mechanical tasks only.
- **`docs/benchmark/landscape.md`** — survey + self-assessment against the
  most popular agent harnesses on GitHub (2026-07-08 snapshot, API-verified
  stars): two comparison tables (Claude Code ecosystem / general harnesses),
  field investments vs field gaps, evidence-linked strengths and weaknesses,
  explicit non-goals with reversal conditions, and a gap→backlog map. Not a
  run benchmark — `results.md` remains the only measured comparison.
- **M-5 (backlog)** — clean-install CI smoke: bare checkout → scratch config
  home → `setup.sh --doctor` asserts 0 failures. Distribution integrity was a
  consistent field investment in the survey; the cold-install path is
  currently only verified by hand.

## [0.2.4] — 2026-07-08

### Added
- **M-1 — `docs/model-routing.md`.** Canonical cross-runtime model-tier policy:
  a three-rung ladder (LOW mechanical / MID workhorse / TOP reasoning) with an
  orthogonal effort dial ("effort before tier-up"), a work-class → tier table
  for Claude Code / Codex CLI / Gemini CLI, floors (verify-judge ≥ MID,
  fan-out workers default LOW — worker tier is the dominant cost lever at
  ~15× multi-agent token spend), and an enforcement map. Explicitly rejected:
  runtime model-switching hooks, automatic tier escalation, dedicated low-tier
  agents, price constants in the repo.
- **M-2 — verify-judge tier floor.** `/verify-completion`'s Layer 2 semantic
  judge is documented as never-below-workhorse (sonnet-class): a low-tier
  refute-by-default judge emits plausible false CONFIRMED verdicts and
  silently disables the completion gate. Low-tier sessions must pass an
  explicit `model` override on the judge dispatch.
- **M-3 — adapter templates carry the tiers.** The Codex adapter ships
  `quick.config.toml.template` (LOW) / `deep.config.toml.template` (TOP) as
  per-profile config files (recent Codex CLI builds reject inline
  `[profiles.*]` tables as legacy — verified against a live CLI); the Gemini
  template ships a workhorse default model with explicit `-m` escalation.
  Model IDs are marked as 2026-07 snapshots.

### Changed
- `skills/supervise/SKILL.md` Model policy: the mechanical-fixes row now names
  its real mechanism (explicit per-call `model` override on the Agent
  dispatch — no low-tier agent is shipped) and the table links to
  `docs/model-routing.md` as its cross-runtime generalization.

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
