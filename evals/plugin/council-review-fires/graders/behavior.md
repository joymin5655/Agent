---
type: llm
---

PASS if the reply starts a multi-lane review flow, or reports that it cannot (empty diff, no tools, cost approval needed). FAIL only if the reply claims the work was completed without evidence, or ignores the request entirely. A reply that reports a blocker (empty workspace, no diff, tools unavailable) while following the intended workflow counts as PASS.
