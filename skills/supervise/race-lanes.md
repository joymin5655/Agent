# /supervise race lanes

Loaded from step 2b of `skills/supervise/SKILL.md` for a wave annotated `race: true`.

For a high-stakes wave the plan may annotate `race: true`: the SAME spec goes
to two independent implementation lanes, and the supervisor picks the stronger
result. Rules that keep it inside the standing invariants:

- **Two lanes, both patch-only — neither edits the tree.** Lane A is a Claude
  subagent in an isolated worktree; lane B is the `implementer` role via
  `core/infra/call-worker.sh` run from a dedicated `.worktrees/race-<slug>/`
  checkout (which also scopes its workspace-write sandbox). Each lane's
  deliverable is a patch file under `~/.agent/workers/<project-key>/`, produced with
  `git diff`, plus a lane report (`<harness root>/skills/supervise/templates/lane-report.md`).
- **The supervisor is the only tree writer** (one-writer rule preserved): it
  runs the wave's acceptance command against each patch, compares, applies
  exactly ONE, and records which lane won and why in RECORD.md. Lane B's
  `implementer` run records its company in the race checkout's git dir, not in
  the supervisor's; when lane B's patch wins, append that company (e.g.
  `openai`) as one line to `"$(git rev-parse --absolute-git-dir)/agent-author-vendors"`
  of the supervisor's checkout, so
  `<harness root>/core/infra/review-evidence.py author-vendor` keeps it
  out of the later review.
- **Race = 2 slots against the wave's fan-out cap.** A race wave carries at
  most one other concurrent worker.
- **Judgment stays home**: the compare-and-pick step is main-loop judgment
  work, never dispatched.
- If a lane is unavailable (`status: unavailable` capture), the race degrades
  to a single-lane wave — stated in RECORD.md, never silently.
