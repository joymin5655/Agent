# Gate registry (T-2)

Every gate that emits a `deny` / `ask` / `block` decision — plus the
non-blocking `observe` / `advise` entries that share this registry — with the
**model weakness it assumes** and a **review date**. The governing principle: *an
assumption expires*. A gate written against a model failure mode that no longer
occurs becomes pure friction (permission-approval rubber-stamping); a gate that
never fires may be dead wiring. Neither is visible without a registry to compare
the live firing log against.

`core/infra/telemetry-digest.sh --gates` reads the **machine block** below plus
the runtime firing logs under `.agent/logs/` and reports, per gate:

- **DEAD** — zero in-window firings (the gate may be mis-wired or its failure
  mode is extinct; confirm before removing).
- **FATIGUE** — firings ≥ the fatigue threshold (default 50; `--fatigue N`): the
  gate is high-friction; check whether it is catching real problems or being
  rubber-stamped.
- **STALE** — `last_reviewed` + review window (default 90 days; `--stale-days N`)
  is in the past: the assumption is overdue for re-validation.
- **UNINSTRUMENTED** — the gate emits a decision but writes no firing log
  (`sink = -`), so fire-rate cannot be measured. Reported honestly rather than
  mislabeled DEAD (unmeasured is not zero).

## Machine block

Parsed by the digest. **Strict format** — one gate per line, exactly:

```
GATE <id> | <hook> | <decision> | <sink> | <match> | <last_reviewed> | <assumption>
```

- `<sink>` is a path relative to `.agent/logs/`, or `-` when the gate writes no log.
- `<match>` is the `guard` field value to count in the sink, or `*` to count every
  line in the sink (used when the sink holds exactly one gate's records).
- `<last_reviewed>` is `YYYY-MM-DD`.
- No `|` may appear in `<assumption>` (it is the last field, free prose otherwise).

<!-- gate-registry:begin -->
GATE destructive | pre-tool-guard.sh | deny | security-violations.jsonl | destructive | 2026-07-10 | Model will run an unscoped rm -rf / reset --hard / force-push when a plan says "clean up" or "start over".
GATE production-data | pre-tool-guard.sh | ask | security-violations.jsonl | production-data | 2026-07-10 | Model will DROP/TRUNCATE a real table while iterating on a migration.
GATE secrets-bash | pre-tool-guard.sh | deny | security-violations.jsonl | secrets | 2026-07-10 | Model will cat/copy/exfiltrate a secrets file to "check" or "inventory" credentials.
GATE verify-bypass | pre-tool-guard.sh | ask | security-violations.jsonl | verify-bypass | 2026-07-10 | Model will pass --no-verify to get past a failing pre-commit hook instead of fixing it.
GATE lint-tamper | pre-tool-guard.sh | ask | security-violations.jsonl | lint-tamper | 2026-07-10 | Model will weaken a linter/gate config to make code pass rather than fix the code.
GATE project-policy | pre-tool-guard.sh | deny | security-violations.jsonl | project-policy | 2026-07-15 | Model will git add large binary artifacts under data/artifacts/. DEAD-review 2026-07-15: KEEP — conditional-path gate; fires only where a consumer project defines artifact globs, zero in-window firings means no matching consumer activity, not an extinct assumption.
GATE secrets-content | secret-content-scan.py | deny | security-violations.jsonl | secrets | 2026-07-10 | Model will write a hardcoded API key / open() a secrets file / embed a token in an MCP payload.
GATE r4-mutex | r4-mutex-check.sh | ask | security-violations.jsonl | r4-mutex | 2026-07-15 | Two concurrent sessions will edit the same resource and clobber each other. DEAD-review 2026-07-15: KEEP — contention gate; multi-session campaigns are active and zero firings means no contention event in window (the failure mode it guards produced 3 real incidents before worktree isolation), not dead wiring.
GATE context-mode | context-mode-guard.sh | ask | security-violations.jsonl | context-mode | 2026-07-15 | Model will run a production-db / deploy MCP action without confirmation. DEAD-review 2026-07-15: KEEP-CONDITIONAL — fate tied to the context-mode plugin itself, which the 2026-07-14 landscape re-check flagged for prompt-pollution review (W-10); retire this gate together with the plugin if the plugin is dropped.
GATE quality-completion | session-quality-gate.py | block | quality-gate-violations.jsonl | * | 2026-07-15 | Model will end a session with style violations or failing completion tests left in the diff. DEAD-review 2026-07-15: RETIRE-CANDIDATE (superseded same-day). CORRECTION 2026-07-15b: **KEEP-CONDITIONAL** — the retirement investigation refuted its own premise: this hook is also the enforcement layer for **P3-1 `session.completion_tests`** (docs/hook-config.md "Completion tests"), so it is a conditional-path gate like project-policy — zero firings means no local consumer declares `completion_tests` and the default style scan scope (`src/`) misses local work patterns, not dead wiring (the gate is battery-verified in verify-all via quality-gate-completion-test.sh). Deleting it would silently unship a landed P3 feature. Real follow-up is adoption/generalization (W-6 `session.close_checks`), not removal. Guard-trim 2026-07-27: SPLIT — the subjective style scan (inline types / hex colors / console.log) is now ADVISORY by default (reported + logged, never blocks; opt back in via AGENT_QUALITY_STYLE_BLOCK=1); the block decision is owned by the objective completion_tests layer alone.
GATE spec-gate | spec-gate.py | ask | spec-gate.jsonl | * | 2026-07-10 | Model will start substantive implementation with no approved spec/plan.
GATE tdd-guard | tdd-guard.py | ask | tdd-guard-dryrun.jsonl | * | 2026-07-10 | Model will write implementation code before a failing test exists.
GATE hardcoding | check-hardcoding.py | deny(opt-in; default=dryrun) | hardcoding.jsonl | hardcoding | 2026-07-27 | Model will inline design constants (colors, tick arrays) that belong in a config file. Guard-trim 2026-07-27: demoted deny -> DEFAULT DRYRUN (AGENT_HARDCODING_MODE=off/dryrun/block; the deny in this row is the opt-in block-mode decision) — a design-taste opinion is not an irreversibility/secret gate, and the gate shipped UNINSTRUMENTED with a docstring promising an unwired hook-config escape (fixed: sink added, escape claim honestly marked T-4-planned).
GATE supervisor-ask | supervisor.py | ask | supervisor.jsonl | supervisor-ask | 2026-07-27 | Model will implement specialist-domain work (review/security) inline instead of dispatching the registered specialist. Registered 2026-07-27 after a registry-blindspot audit: the hook had logged ~440 records / 11 ask-intents in 30d while absent from this registry (firing but unreviewable). Records before 2026-07-27 lack the guard field, so the digest counts from registration forward; mode unchanged by registration — measure first, recalibrate on data at the next review.
GATE plan-scope-allow | plan-scope-allow.py | allow | plan-scope-allow.jsonl | * | 2026-07-11 | Post-plan-approval edit prompts get rubber-stamped (approval fatigue); auto-allow is safe only in-workspace, outside risk areas, while the session plan flag is live. Activation 3-way: AGENT_PLAN_ALLOW_MODE=on forces active, explicit non-"on" forces dark, unset delegates to the per-project trust tier (trust_tier.py — personal only, granted solely by user-side ~/.agent/trust.list outside every workspace; fail-closed collab).
GATE model-routing-observer | model-routing-observer.py | observe | model-routing.jsonl | * | 2026-07-11 | The call-time model-override convention (implementation=MID, fan-out=LOW) is not followed — unpinned dispatches silently inherit the session top model. Measured before enforced: 2026-07-11 audit found 7/7 dispatches at TOP. 2026-07-17: records gained a spend signal (prompt_chars, best-effort total_tokens) so manager-audit can rank relative dispatch cost.
GATE model-routing-advisor | model-routing-advisor.py | advise | - | * | 2026-07-28 | Same leak model-routing-observer measures (unpinned dispatch inherits the session top model), caught only after the fact by that observer. This hook surfaces the reminder at the decision point — a one-line additionalContext nudge on PreToolUse Task/Agent — so the dispatcher can add a `model` override or confirm the inherit is intentional before the call goes out. Advisory only: never blocks, never switches a model, writes no log of its own (sink -; model-routing-observer's sink stays the sole measured record).
GATE session-tier-observer | session-tier-observer.py | observe | session-tier.jsonl | * | 2026-07-21 | An expensive session does execution/mechanical work inline because nothing tells it which tier rung it occupies; detection makes the routing convention visible while every dispatch decision stays caller-made (the policy's "detection allowed, switching rejected" line). SessionStart payload carries no model field (verified 2026-07-21), so detection is best-effort: stdin field when the runtime adds one, transcript tail on resume, settings default labeled as such. Transcript-sourced values are spoofable by conversation content (a quoted 'model: ...' line in the chat matches the tail scan) — the record's source field discloses this; treat transcript-tier rows as best-effort labels, not verified identity, by any future consumer (/manager-audit does not read this sink yet).
GATE rubric-commit | rubric-commit-judge.sh | observe | rubric-score.jsonl | * | 2026-07-19 | A project's per-commit quality is never scored against its own rubric, so regressions land silently between on-demand verify-completion runs. Advisory by design (records, never blocks — the commit already happened); the deterministic half of the two-layer rubric design. Fires only where a consumer defines .agent/rubric.yml (conditional-path, like project-policy), so zero in-window firings means no consumer opted in, not dead wiring.
GATE verify-observed | session-quality-gate.py | observe | verify-observed.jsonl | verify-observed | 2026-07-30 | A session rewrites code end to end, runs nothing, and ends clean. quality-completion only closes this where a consumer declares session.completion_tests ("Unset/empty => the gate does nothing"), which is why THAT gate shows zero local firings — so the unconditional half is missing. Layer 3 of session-quality-gate.py notes code-changes-with-no-observed-verification, fed by verify-observer.py's PostToolUse invocation records (which share this sink but carry hook=verify-observer.py, so the digest's hook filter counts firings only). OBSERVE-ONLY on purpose: it blocks only under AGENT_VERIFY_OBSERVER_BLOCK=1, because a gate whose net effect is unmeasured has not earned the right to block (see "Is the gate worth its noise?" below). Presence-only by necessity — this runtime supplies no exit status (measured 2026-07-30), so the advisory never claims anything passed.
<!-- gate-registry:end -->

## Review discipline

When you re-validate a gate's assumption (it still catches real model failures, or
it's proven extinct), bump its `last_reviewed` date here. The digest's STALE
report is the reminder; this file is the record. Removing a gate is a code change
*plus* deleting its row here — the registry must not name a gate that no longer
ships (there is no separate drift gate for this file yet; keep it honest by hand).

### Is the gate worth its noise?

A healthy fire-rate is not the same as a positive contribution. Every firing
spends context: the reason text, the retry, the re-read. A gate that fires often
and correctly can still be **net-negative** if the noise it injects degrades the
rest of a long session more than the failures it catches cost. So the review
question is not "did it fire" but:

> **Is the session better off with this gate on than off?**

DEAD / FATIGUE / STALE do not answer that — they measure activity, not effect.
When there is no data to answer it, say so and treat the gate exactly like
`UNINSTRUMENTED`: unmeasured is not the same as fine. Two rules follow.

- **Measure before enforcing.** A new gate lands as `observe` with a sink, and
  earns `ask`/`deny`/`block` only once its firings can be shown to correspond to
  real problems. The reverse order ships enforcement whose value is a guess.
- **Sunset condition.** A gate that is DEAD across two consecutive review
  windows, with no new evidence for its assumption, becomes a retirement
  candidate — recorded on its row, the same way `project-policy` and `r4-mutex`
  recorded KEEP with a reason. Conditional-path gates (fire only where a consumer
  opts in) are exempt from the DEAD count but not from this question.

Origin: this criterion is adopted from the measurement protocol of an external
harness (the `fivetaku/fablize` plugin, its measurement-protocol doc §1/§7),
which puts the harness-paradox question first and states plainly that a zero-lift
result is a warning rather than a success. The counterfactual machinery that would answer it
properly — an on/off holdout arm — is backlog X-1, deliberately unbuilt until
designed: that same project shipped an unrun measurement layer, and an
instrument nobody executes measures nothing.
