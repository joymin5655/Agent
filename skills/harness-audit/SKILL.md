---
name: harness-audit
description: Agent-driven, read-only self-audit of the harness — run the machine integrity layer once as a dry-run, present a per-check pass/fail table, cite the P1-1 doc-reality result, and for any failure give root-cause + fix + backlog follow-up. Consumes the machine gates; it does not reimplement them. NOT for auditing a consumer project's own codebase (use that project's test suite), and NOT for applying fixes — this skill observes and reports only.
when_to_use: A periodic or on-demand health check of the harness itself — "audit the harness", "/harness-audit", "is the harness passing its own gates", or when you want one interpreted report over the CI/gate layer before a release or after a structural change.
tools: Bash, Read, Grep, Glob
---

# /harness-audit

## Goal

Produce **one interpreted health report** of the harness in a single read-only
dry-run. The machine integrity layer (P1-1 `doc-reality.sh`, the CI jobs, and the
`verify-all.sh` runner) is the *enforcement*; this skill is the *consumer* that
runs it once, reads off a per-check pass/fail table, and turns each failure into a
diagnosis a maintainer can act on.

Concretely the report answers three questions with evidence:

1. **Is the harness passing its own gates right now?** — a per-check PASS / FAIL /
   SKIP table, taken verbatim from `verify-all.sh`.
2. **What does the doc-reality gate (P1-1) say?** — cited explicitly, because it is
   the gate that catches the harness lying about itself (phantom paths + drifted
   counts), and it is the one item most easily missed in a wall of green.
3. **For every non-PASS: why, and what next?** — the check's purpose, the likely
   root cause, the recommended fix, and whether it warrants a new backlog row.

This skill supplies the *interpretation*; it does **not** re-implement any check.
The checks live in `core/tests/` and CI; here you run them and read the results.

## Why this is a layer, not a duplicate of P1-1

P1-1 (`core/tests/doc-reality.sh`) is a **machine gate**: it runs in CI, exits 0/1,
and mechanically blocks doc drift. This skill is the **agent consumer** that sits on
top of that gate — it invokes the whole machine layer in one dry-run and *interprets*
the results (root-cause, fix, backlog follow-up) the way a maintainer would. It reads
doc-reality's verdict; it never re-derives phantom-path or count logic. Deleting this
skill would not weaken any gate (CI still enforces them); deleting doc-reality would.
That asymmetry is the layer relationship: the gate enforces, the audit interprets.
This mirrors the machine-gate-vs-agent-consumer split the plan draws for H-2.

## Steps

### 1. Run the machine integrity layer (one dry-run)

```bash
bash core/tests/verify-all.sh
```

`verify-all.sh` is the single-command runner. It **dynamically discovers** every
`core/tests/*.sh` check (the runner and its own self-test aside, to avoid recursion —
that self-test runs as its own CI step) so no harness check is silently omitted, and
runs, per check, PASS / FAIL / loud SKIP with a final tally. Its discovered set
already includes the machine layer this audit reports on:

- **`doc-reality.sh` (P1-1)** — the doc-drift gate. It also cross-checks the §7
  artifact counts, which include the hook file count, so the historical **"hook
  count" audit item is covered here** (there is no separate hook-count step to run).
- **`sanitize-audit.sh`** — domain-neutrality (no prior-project taint).
- **`supply-chain-scan.sh`** — no injection-style directives in shipped files.
- **`adapter-parity.sh`** — the three adapters normalize one event identically.
- **`registry-drift.sh`** — the registry/manifest gate (plugin/marketplace fields,
  hooks.json → executable core-hook resolution, agent `name:` frontmatter, and
  registry↔agent model agreement).
- **every `*-test.sh` battery** — the per-hook and per-gate fixture tests.
- **`evals:deterministic` and `evals:semantic`** — the two eval layers (same
  invocation CI uses).
- **`gitleaks`** — the secret scan when present; a loud SKIP (never a silent pass)
  when the binary is absent.

Capture the runner's per-check output and its final `=== verify-all: … ===` tally.
This is entirely read-only: the runner and every check it dispatches only read the
repo — no files are written, nothing is committed. Note the runner's exit status: a
**non-zero exit means the harness is failing its own gates** and the report must say
so plainly.

To enumerate the checks without executing them (useful for a coverage sanity-check
of the report), `bash core/tests/verify-all.sh --list` prints the labels only.

### 2. Run the runtime layer (doctor + telemetry digest)

`verify-all.sh` covers the *repo*; two further read-only probes cover the
*runtime this repo is installed into* and the *live gate behavior*:

```bash
bash setup.sh --doctor
bash core/infra/telemetry-digest.sh
```

- **`setup.sh --doctor`** — environment diagnosis (tool availability, exec bits,
  registry/hooks sanity) plus the drift observers: plugin-cache single-version
  (a stale cached version re-exposing retired agents/skills), declared-hook
  manifest vs live settings reconciliation, and the phantom-command scan (a
  runtime `commands/*.md` invoking a script that does not exist on this
  machine). Doctor WARNs are observations, never blockers — report them in the
  same diagnosis format as step 4.
- **`telemetry-digest.sh`** — per-gate fire-rate from the local event sinks;
  surface any DEAD (never fires) or FATIGUE (high-frequency ask) candidates as
  calibration follow-ups, not as failures.

Append the doctor summary line (`doctor: N pass, M warn, K fail`) and any
DEAD/FATIGUE candidates to the report. If either probe's input is absent on
this machine (no runtime install, empty sinks), say so — an unmeasured layer is
reported as unmeasured, not as green.

### 3. Present the table (cite P1-1 explicitly)

Read the runner's output and render a per-check table:

```
check                    result   note
-----------------------  -------  -------------------------------------------
doc-reality.sh (P1-1)    PASS     docs match repo; §7 counts + hook count OK
sanitize-audit.sh        PASS     no prior-project taint
supply-chain-scan.sh     PASS     no injection-style directives
adapter-parity.sh        PASS     3 adapters agree
registry-drift.sh        PASS     manifests/hooks/agents/registry agree
… (batteries) …          PASS     fixture tests green
evals:deterministic      PASS     labeled dataset, Pass^3
evals:semantic           PASS     test-meaningfulness judge, Pass^3
gitleaks                 SKIP     binary not installed on this host
```

Call out the **doc-reality (P1-1)** line by name — its verdict is the headline of
this audit. State the overall tally (N passed / M failed / K skipped) and the
runner's exit status.

### 4. Diagnose each non-PASS

For every FAIL, every doctor WARN, and every SKIP that matters (e.g. a skipped
security scan), write:

- **Purpose** — what the check guards (one line).
- **Root cause** — the most likely reason it is failing, read from the check's own
  failure output (each gate prints the offending item; quote it).
- **Fix** — the concrete corrective step (edit which doc / ship which file / restore
  which exec bit), matching the guidance the gate itself prints.
- **Backlog follow-up** — whether this warrants a new row in
  `docs/harness-improvement-plan.md` (a recurring or structural failure does; a
  one-off local fix does not). Suggest the row; do not add it here.

A SKIP is not a PASS: an absent `gitleaks` is a coverage gap to flag (install it or
rely on the dedicated CI secret-scan job), not a silent green.

### 5. Summarize health + next actions

Close with an overall verdict — healthy (all gates green) or failing (one or more
gates red) — and an ordered list of recommended next actions drawn from step 4. If
the harness is failing its own gates, that is the top-line finding.

## Completion condition

The audit is complete when a single dry-run has produced **(a)** a per-check
pass/fail table and **(b)** an explicit citation of the P1-1 (doc-reality) result.
Anything less (a table with no doc-reality line, or a doc-reality verdict with no
table) is an incomplete audit.

## Hard rules

- **Read-only.** This audit observes; it does not edit, fix, or commit. Diagnosis
  and fix *suggestions* are the output — applying them is a separate, human-directed
  step.
- **Do not reimplement the checks.** The gates in `core/tests/` and CI are the
  source of truth. This skill runs them and interprets their output; if a check's
  logic is wrong, fix the check (and its battery), not this skill.
- **The P1-1 citation is mandatory.** doc-reality is the gate that catches the
  harness lying about itself; its verdict is always named in the report.
- **A non-zero `verify-all.sh` exit is a failing harness.** Report it as such —
  never round a red run up to "mostly green".
