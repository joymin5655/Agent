# Strong Goal Template

A goal is **strong** when an auditor can verify it deterministically.
A goal is **weak** when verification requires human judgement.

Use this template when writing a plan, wave, or sub-task goal.

## Template

```markdown
### Wave N — <one-line summary>

**Target state** (what the world looks like when done):
- File X exists with property Y.
- Behavior Z is observable when input W is provided.

**Acceptance criteria** (cases the implementation must satisfy):
- (positive) Given … then …
- (negative) Given … then NOT …
- (regression) Existing behavior … still works.
- (domain-specific) … (e.g., uncertainty fields preserved)

**Validation evidence** (commands the auditor will run):
- `npm run test:run -- path/to/X.test.ts` → exits 0
- `bash core/tests/<topic>.sh` → all PASS
- `grep -c '<symbol>' src/x.ts` → ≥ N

**Boundaries**:
- May edit: path/A, path/B
- Off-limits: path/C, path/D (separate plan)
- Preserve: function names / public API of …
- Risk areas crossed: deploy / payment / etc.

**Stop conditions** (abort the wave immediately):
- gitleaks FAIL
- type-check FAIL
- test FAIL
- safeguard match (R4 mutex, R4.1 file mutex)
- user says "stop" / "halt"
- after N turns without progress
```

## Strong vs weak — 6 patterns

| Weak | Strong |
|---|---|
| "Improve performance" | "p95 latency ≤ 200ms on `/api/foo` measured with `<your-benchmark>`" |
| "Add validation" | "Tests for null/empty/oversized inputs pass; existing happy-path tests still pass" |
| "Fix the bug" | "Test that reproduces the bug fails on `main`; same test passes on the branch" |
| "Refactor X" | "Tests pass before and after; `git diff --shortstat` shows ≤ N lines net change" |
| "Make it work" | "<specific user flow> completes end-to-end in `core/tests/e2e/<flow>.sh`" |
| "Update docs" | "`grep -c '<old-term>' docs/` returns 0; `grep -c '<new-term>'` returns ≥ N" |

## Detection signals (weak goal)

If you see these in your plan, rewrite:

- "Improve …" / "Enhance …" / "Better …"
- "Should …" (without an observable check)
- Verbs without objects ("Implement …", "Build …")
- "And other related changes" / "etc."
- Adjective-only acceptance ("clean", "fast", "intuitive")

## Audit (deterministic scoring)

`bash core/infra/supervisor-goal-audit.sh score --plan <slug> --wave <num>`

Scores each wave on 5 dimensions (0-5 each, total 25):

| Dimension | What it measures |
|---|---|
| target_state | Observable behavior, named files, exit-code language. |
| acceptance_criteria | positive / negative / regression / domain-specific cases. |
| validation_evidence | Richness of verification commands. |
| boundaries | Editable / off-limits / preserve / risk-areas explicit. |
| stop_conditions | Abort triggers / turn cap / safeguards. |

Verdicts:
- ≥18 strong — wave can run autonomously.
- 12–17 mixed — wave can run but expect mid-flight clarifications.
- <12 weak — rewrite before running. Advisory; never blocks.
