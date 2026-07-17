# Proposals — manager-smoke (manager-audit 2026-07-17)

## Semantic verdicts (skill Step 2)

- `top-inherit-leak: Explore` — **kept**: the dispatch was a bounded filename
  lookup; policy says LOW override, it carried none. (Planted on purpose for
  this smoke; detection confirmed.)
- `top-inherit-leak: Plan` — **dismissed**: design work is the Model policy's
  inherit lane; unpinned is intended.
- `top-inherit-leak: claude-code-guide` — **kept (minor)**: doc lookups fall
  under "unpinned types = MID default"; the dispatch carried no override.
- `fanout-not-low: 13× Explore at MID/TOP` — **false positive of the tool
  itself**: docs/model-routing.md § Built-in agents names Explore-at-MID a
  deliberate exception to the fan-out-LOW default. Became P1.

## P1: fanout-not-low must honor the documented Explore-MID exception

- **Finding**: routing-waste/fanout-not-low — "13× Explore at MID/TOP" flagged,
  but Explore-at-MID is explicitly sanctioned (docs/model-routing.md § Built-in
  agents: "Deliberate exception to the fan-out-LOW default").
- **Patch** (`core/infra/manager-audit.sh`, fanout jq filter): exclude records
  that are `subagent_type == "Explore"` with tier `MID` from the fan-out group
  before the `length >= 3` gate:
  ```
  [.[] | select(.verdict != "pinned_specialist"
                and ((.subagent_type == "Explore" and .tier == "MID") | not))]
  ```
  plus a regression fixture: 3× Explore at sonnet → no fanout-not-low finding.
- **Status**: applied (2026-07-17, user-approved P1+P2)

## P2: audits need per-run scoping — wire AGENT_SESSION_ID or a --since window

- **Finding**: all lanes read the full model-routing.jsonl history; every
  record has `session_id: ""` because nothing exports AGENT_SESSION_ID to the
  hook, so `--session` cannot isolate one supervise run and old sessions leak
  into every audit (the 13× Explore group above spans multiple days).
- **Patch** (convention/doc first): add a `--since <ISO-ts>` filter to
  `core/infra/manager-audit.sh` (jq: `select(.ts >= $since)`), and have
  /supervise Step 0 note the run's start timestamp in RESTATEMENT.md so the
  completion step can pass it. Longer-term: export AGENT_SESSION_ID in the
  adapter env so the observer's existing field becomes useful.
- **Status**: applied (2026-07-17, user-approved P1+P2)
