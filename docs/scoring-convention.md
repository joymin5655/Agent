# Scoring convention — the verdict schema

One shared shape for every "how good / is this real?" judgment in the harness,
so the completion verifier, the skill A/B harness, and the goal-audit scorer all
speak the same language and their outputs can be compared, gated, and logged the
same way.

## The verdict object

```json
{
  "verdict": "CONFIRMED" | "REFUTED" | "MIXED",
  "score": 0.0,
  "target": "<what was judged — a claim summary, a skill name, a plan slug>",
  "dimensions": {
    "<name>": { "passed": 0, "total": 0 }
  },
  "refutations": [ "<a specific, load-bearing reason the target fell short>" ],
  "schema_version": "1.0.0"
}
```

- **`verdict`** — the gate result. `CONFIRMED` = passed the bar; `REFUTED` =
  did not; `MIXED` = partial, for scorers that grade rather than gate (a goal
  audit that is neither strong nor weak). A pure gate uses only
  CONFIRMED/REFUTED.
- **`score`** — a single scalar in `[0, 1]`, normalized so different scorers are
  comparable. `passed / total` for the mechanical scorers; a judge's calibrated
  0–1 for the semantic ones.
- **`dimensions`** — the axes the score decomposes into (files/tests/assertions
  for the completion verifier; the five goal dimensions for the goal audit). A
  reader can see *where* the score came from, not just the total.
- **`refutations`** — the actionable part: every specific way the target fell
  short, most load-bearing first. An empty list is the only thing that earns
  `CONFIRMED`.

## Gate semantics — refute-by-default

The resting state is **REFUTED**. A target is `CONFIRMED` only when there is
something to verify (`total > 0`) **and** nothing was refuted. Ambiguity, a
missing artifact, an unparseable input, or "nothing to verify" all resolve to
REFUTED — never a silent pass, never a crash. A scorer that fails internally
degrades to REFUTED with the error as a refutation.

This is the same principle the adversarial-review workflow uses (each finding is
verified by a skeptic prompted to refute) and the same one the pre-commit and
Stop gates use (the unproven case is the blocked case).

## Producers

| Producer | Layer | `score` | `dimensions` |
|---|---|---|---|
| `core/infra/completion-verify.py` (P3-5) | deterministic | `passed / total` over cited facts | `files`, `tests`, `assertions` |
| `skills/verify-completion` (P3-5) | deterministic **+** semantic judge | combined | the above + a semantic axis |
| `core/infra/supervisor-goal-audit.sh` | deterministic (static scoring of a plan) | `total / 25` (see mapping) | 5 goal dimensions |
| skill A/B harness (H-3, planned) | assertion + judge | assertions passed / total | per-skill assertions |
| `grade.sh` (P2-2, planned) | judge | calibrated 0–1 | task-defined |

### Mapping the goal-audit 25-point scale onto the convention

`supervisor-goal-audit.sh` predates this schema and scores a plan on five
dimensions of 0–5 (total 25), with tiers `>=18 strong / 12–17 mixed / <12 weak`
(advisory — it does not block). It maps onto the convention without changing its
behavior:

- `score` = `total / 25`
- `verdict` = `strong → CONFIRMED`, `mixed → MIXED`, `weak → REFUTED`
- `dimensions` = its five dimensions (`target_state`, `acceptance_criteria`,
  `validation_evidence`, `boundaries`, `stop_conditions`), each `{passed, total: 5}`

Its verdict stays **advisory** (a weak plan warns, does not block) — the
convention describes the *shape* of a judgment, not whether a given gate is
enforcing or advisory. That choice belongs to each consumer.

## Consuming a verdict

```bash
# As a gate (exit code): completion-verify.py exits 0 iff CONFIRMED.
python3 core/infra/completion-verify.py --root "$PWD" .agent/claims/x.yml \
  && echo "done is real" || echo "claim refuted"

# As data (jq): read the score and refutations.
python3 core/infra/completion-verify.py --root "$PWD" .agent/claims/x.yml \
  | jq -r '"\(.verdict) score=\(.score)", (.refutations[] | "  - \(.)")'
```

A consumer should treat `verdict` as authoritative for the gate decision and
`refutations` as the thing to surface to a human or hand back to the builder.
`score` is for ranking and trend-tracking, not for gating (a 0.9 with a
load-bearing refutation is still REFUTED).

## Related

- `core/infra/completion-verify.py` — the deterministic completion verifier.
- `skills/verify-completion/SKILL.md` — the independent-context judge that wraps
  it and adds the semantic pass.
- `core/infra/supervisor-goal-audit.sh` — the 25-point goal scorer.
- `docs/harness-improvement-plan.md` — P3-5 (this), H-3, P2-2.
