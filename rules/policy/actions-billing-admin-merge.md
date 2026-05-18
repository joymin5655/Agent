# Admin-merge SOP — GitHub Actions billing edge case

When CI fails because Actions billing is exhausted (not because of a real
test/leak), the maintainer can `gh pr merge --admin --squash` to ship
**only if** four conditions all hold. This SOP documents those
conditions and the auto-checker that enforces them.

## Trigger conditions (ALL four required)

1. **CI is SUCCESS** *or* fails only because of GitHub Actions billing
   (spending-limit / account-payments / billing-hit signals in the
   workflow output).
2. **Zero risk-area violations** in the PR diff
   (`data` / `secrets` / `deploy` / `payment` / `domain-output` —
   see `security-guards.md`).
3. **User explicitly invokes** the admin-merge path. Generic phrases
   ("just merge it") don't qualify — must be one of:
   - `/wrap --auto-merge`
   - `/supervise <plan> --auto-merge`
   - "admin merge"
   - "proceed all the way to merge"
4. **(Optional) Billing-hit signal** confirmed via secret-scan workflow
   run logs.

## Decision tree (in `core/infra/auto-ship.sh`)

```
CI exit code?
  0  → all success → continue
  ≠0 → which checks failed?
        only secret-scan → check the run logs:
          "leaks found"           → ABORT (exit 6 — real leak)
          "spending limit|billing" → continue with local-gitleaks fallback
          (neither)                → ABORT (exit 8 — unclear)
        anything else → ABORT (exit 10)

Then for each risk area:
  data violated     → ABORT (exit 12)
  deploy violated   → ABORT (exit 13)
  payment violated  → ABORT (exit 14)
  secrets violated  → ABORT (exit 15)
  domain-output net-removal → ABORT (exit 16)

If all checks pass:
  gh pr merge --admin --squash
  sleep 2
  verify state == MERGED
  pull main if cwd == main
```

## Evidence

Each admin-merge run appends a record to `.agent/logs/admin-merge.jsonl`
via the `admin-merge-track.py` PostToolUse hook (runs on the `gh pr merge`
Bash invocation):

```json
{"ts":"…","pr":123,"branch":"feat/foo","reason":"billing-fail","decision":"admin-merge-allowed"}
```

T+30d audit reviews these records for bypass patterns or
false-positive trends.

## What admin-merge is NOT for

- Test failures (fix the test, don't merge around it).
- Lint failures (fix the lint).
- Real secret leaks (rotate the secret, rewrite history, repush).
- Reviewer disagreement (resolve in the PR thread).

## Caveats

- `--admin` bypasses branch protection. Don't make this routine.
- The 4-condition check is automation, not authority. The human at the
  keyboard is responsible for the merge.
