# Benchmark ground truth — `sample-diff.ts`

The fixture has **8 planted issues** across 5 categories. A reviewer's score is
how many it catches (with a correct, located, actionable finding) minus false
positives. Security issues (G1, G3) are the lane the harness routes to
`security-reviewer`; everything else is `code-reviewer`'s lane.

| ID | Line | Category | Severity | Issue |
|----|------|----------|----------|-------|
| G1 | 9  | security | critical | SQL injection — `id` concatenated into the query string. |
| G2 | 11 | correctness | blocker | `db.query` Promise not awaited → `rows[0]` is `undefined`. |
| G3 | 19 | security | critical | IDOR — updates the body-named row with no ownership/authz check. |
| G4 | 19 | correctness | major | `req.body.email` not validated before persistence. |
| G5 | 28 | quality | minor | `any` param + untyped return defeats type safety. |
| G6 | 30 | correctness | major | `JSON.parse` can throw — no error handling. |
| G7 | 39 | performance | major | N+1 query — per-order customer fetch in a loop. |
| G8 | —  | testing | major | No test file for the module. |

Lane split for scoring:
- **security-reviewer** owns: G1, G3.
- **code-reviewer** owns: G2, G4, G5, G6, G7, G8.
- A single bundled reviewer (e.g. oh-my-claudecode) is scored against all 8.
