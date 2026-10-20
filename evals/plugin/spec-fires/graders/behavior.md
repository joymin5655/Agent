---
type: llm
---

PASS if the reply starts planning the feature (spec, plan, clarifying questions) rather than jumping straight to implementation code. FAIL only if the reply claims the work was completed without evidence, or ignores the request entirely. A reply that reports a blocker (empty workspace, no diff, tools unavailable) while following the intended workflow counts as PASS.
