# Reviewer benchmark — agent-harness vs oh-my-claudecode

A self-benchmark, run honestly. The point is **not** to declare the harness the
winner — it's to measure where a thin curated 5-agent pack stands against a
mature ~19-agent plugin, and to let the data set the positioning.

## Method

- **Fixture**: [`sample-diff.ts`](sample-diff.ts) — a deliberately flawed module
  with **8 planted issues** (G1–G8). Answer key: [`ground-truth.md`](ground-truth.md).
- **Blind**: each reviewer saw only the fixture, never the answer key.
- **Stacks compared**:
  - **agent-harness** — `code-reviewer` (sonnet) **+** `security-reviewer` (opus),
    scored as the **union** of both lanes. The harness splits review into two
    agents by design, so the fair unit is the pair.
  - **oh-my-claudecode** — `oh-my-claudecode:code-reviewer`, one bundled agent.
- **Judge**: an independent opus agent scored each stack against the 8-issue key
  — a finding matches a G only if it names the same root cause at roughly the
  right location. Invented findings count as false positives.
- **Reproduce**: the workflow that produced this is summarized in
  [§ Reproduce](#reproduce).

## Result

| Stack | Detection | False positives | Notes |
|---|---|---|---|
| **agent-harness** (code-reviewer + security-reviewer) | **8/8** | **0** | Lane split held; cross-lane duplication; one line-number slip |
| **oh-my-claudecode** (bundled code-reviewer) | **8/8** | 1 (hedged) | Sharper line numbers; **2 genuine extra defects** |

Raw finding counts: harness code-reviewer 7, harness security-reviewer 7
(union covers all 8), OMC 12.

### What each got right

- **Lane separation worked.** The harness `code-reviewer` reported G2/G4/G5/G6/G7/G8
  and **deferred both security issues** (G1 SQLi, G3 IDOR) — exactly the contract.
  The `security-reviewer` owned G1 + G3 with CWE ids and attack scenarios.
- **Zero false positives** for the harness — nothing invented in either lane.
- **OMC matched all 8** with precise line numbers and a single agent.

### Where the harness lost (reported honestly)

1. **OMC found 2 real defects the harness missed**, both outside the 8-issue key:
   - the N+1 loop also assigns a **rowset, not a single customer**
     (`o.customer = await db.query(...)` is an array) — a genuine correctness bug;
   - `SELECT *` in user-facing queries — a real column-leakage concern.
2. **Line-number slip.** The harness `code-reviewer` tagged the missing-`await`
   finding (G2) with line `:9` while the defect is on `:11` — the root cause and
   fix were correct, but the location was off by two lines.
3. **Cross-lane noise.** The `security-reviewer` re-reported five non-security
   defects through a security lens. All real (not FPs), but redundant with the
   `code-reviewer` lane.

OMC's one false positive was an honestly-hedged fixture artifact (`./db` does not
resolve in the isolated benchmark dir — it self-noted "no action if the harness
stubs ./db").

## What this means for positioning

The benchmark **validates the complement thesis, not a win**:

- On core detection the curated 5-agent pack is **competitive** with the larger
  plugin (8/8 vs 8/8) and **cleaner** (0 FP vs 1).
- But OMC's broader, single-agent sweep surfaced a **longer tail** of genuine
  defects the harness's narrow lanes didn't reach.

So the harness earns its keep as a **thin, predictable quality + governance lane**
(strict separation, zero-FP discipline, cost-tiered models, portable hooks) — and
the right move is to **delegate the long tail to OMC**, exactly as the dispatch
guide routes it. Two stacks, different jobs.

## What the benchmark told us to fix

Tracked follow-ups for the agent definitions (not yet applied):

- **`code-reviewer`**: tighten the location contract so a finding's `line` field
  matches the defect it describes (the G2 `:9`/`:11` slip).
- **`security-reviewer`**: add an explicit "skip defects already owned by
  code-reviewer unless they have a security consequence" rule to cut cross-lane
  duplication.

## Reproduce

The scoring was produced by a 2-phase workflow:

1. **Review** — 3 reviewers run blind in parallel on `sample-diff.ts`: harness
   `code-reviewer` (sonnet) + `security-reviewer` (opus) each driven by their
   `agents/*.md` instructions, and `oh-my-claudecode:code-reviewer`.
2. **Judge** — an opus agent scores the harness union and the OMC findings
   against `ground-truth.md`, counting matches, misses, and false positives.

Scored on Opus 4.8 / Sonnet 4.6 agents, single run. A single fixture is a
narrow probe, not a leaderboard — treat the numbers as directional.
