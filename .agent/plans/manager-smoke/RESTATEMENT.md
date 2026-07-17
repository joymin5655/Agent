# Intake restatement — manager-smoke

## Original ask (verbatim)

머지하고 실제 supervise 런으로 manager-audit 테스트해줘

## Interpreted goal

Merge PRs #70/#71/#72 to main (done), then run a real /supervise loop on the
plan manager-smoke (two scratchpad waves) so /manager-audit can grade genuine
run artifacts: RESTATEMENT.md, supervisor-goal-audit.jsonl verdicts,
model-routing.jsonl dispatch records, and RECORD.md.

## Assumptions

- A minimal two-wave scratchpad plan is an acceptable "real run" — the point
  is exercising the loop and the audit lanes, not shipping repo changes.
- One deliberately unpinned Explore dispatch is planted during Wave 1 so the
  routing-waste lane has a real TOP-inherit leak to detect.
- The installed plugin still runs the pre-#70 observer (no spend fields yet);
  the audit's prompt_chars/4 fallback path covers this.

## Out of scope

- No repo files are created or modified by the waves (scratchpad only).
- No --goal-mode SQLite state (non-goal run; RECORD.md written manually).
- No application of any PROPOSALS.md patch without explicit user approval.

## Success criteria (measurable)

- test -f <scratchpad>/manager-smoke/wave1.txt exits 0
- test -f <scratchpad>/manager-smoke/wave2.txt exits 0
- bash core/infra/supervisor-goal-audit.sh manager-smoke 1 and 2 both PASS
- bash core/infra/manager-audit.sh manager-smoke --json returns findings
  including the planted inherit_top leak

## Open questions

None
