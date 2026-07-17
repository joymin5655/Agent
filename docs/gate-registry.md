# Gate registry (T-2)

Every gate that emits a `deny` / `ask` / `block` decision, with the **model
weakness it assumes** and a **review date**. The governing principle: *an
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
GATE quality-completion | session-quality-gate.py | block | quality-gate-violations.jsonl | * | 2026-07-15 | Model will end a session with style violations or failing completion tests left in the diff. DEAD-review 2026-07-15: RETIRE-CANDIDATE (superseded same-day). CORRECTION 2026-07-15b: **KEEP-CONDITIONAL** — the retirement investigation refuted its own premise: this hook is also the enforcement layer for **P3-1 `session.completion_tests`** (docs/hook-config.md "Completion tests"), so it is a conditional-path gate like project-policy — zero firings means no local consumer declares `completion_tests` and the default style scan scope (`src/`) misses local work patterns, not dead wiring (the gate is battery-verified in verify-all via quality-gate-completion-test.sh). Deleting it would silently unship a landed P3 feature. Real follow-up is adoption/generalization (W-6 `session.close_checks`), not removal.
GATE spec-gate | spec-gate.py | ask | spec-gate.jsonl | * | 2026-07-10 | Model will start substantive implementation with no approved spec/plan.
GATE tdd-guard | tdd-guard.py | ask | tdd-guard-dryrun.jsonl | * | 2026-07-10 | Model will write implementation code before a failing test exists.
GATE hardcoding | check-hardcoding.py | deny | - | * | 2026-07-10 | Model will inline design constants (colors, tick arrays) that belong in a config file.
GATE plan-scope-allow | plan-scope-allow.py | allow | plan-scope-allow.jsonl | * | 2026-07-11 | Post-plan-approval edit prompts get rubber-stamped (approval fatigue); auto-allow is safe only in-workspace, outside risk areas, while the session plan flag is live. Activation 3-way: AGENT_PLAN_ALLOW_MODE=on forces active, explicit non-"on" forces dark, unset delegates to the per-project trust tier (trust_tier.py — personal only, granted solely by user-side ~/.agent/trust.list outside every workspace; fail-closed collab).
GATE model-routing-observer | model-routing-observer.py | observe | model-routing.jsonl | * | 2026-07-11 | The call-time model-override convention (implementation=MID, fan-out=LOW) is not followed — unpinned dispatches silently inherit the session top model. Measured before enforced: 2026-07-11 audit found 7/7 dispatches at TOP. 2026-07-17: records gained a spend signal (prompt_chars, best-effort total_tokens) so manager-audit can rank relative dispatch cost.
<!-- gate-registry:end -->

## Review discipline

When you re-validate a gate's assumption (it still catches real model failures, or
it's proven extinct), bump its `last_reviewed` date here. The digest's STALE
report is the reminder; this file is the record. Removing a gate is a code change
*plus* deleting its row here — the registry must not name a gate that no longer
ships (there is no separate drift gate for this file yet; keep it honest by hand).
