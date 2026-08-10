# Lane report — <role / wave N>

Required return format for every cross-vendor lane dispatch (a
`core/infra/call-worker.sh` role such as `implementer`, or any external-CLI
worker). The caller fills nothing in advance; the LANE fills every section, and
the CALLER re-verifies before accepting. A report's claims are inputs to
verification, never a substitute for it — the capture frontmatter written by
call-worker.sh (`status:` complete|failed|timeout|unavailable) is the
mechanical truth layer underneath this self-report.

## STATUS

One of: `complete` | `partial` | `unavailable` | `timeout`.
Never claim `complete` with failing or unrun verification. `unavailable`
(CLI missing, disabled, unauthenticated) is reported loudly — a lane never
silently substitutes another producer for itself.

## OBJECTIVE

The one-line goal the spec gave this lane, restated verbatim — proof the lane
worked the assigned task, not a drifted one.

## CHANGES

Files touched with a diffstat (or patch-file path for race lanes). Empty is a
valid entry when STATUS explains why.

## VERIFIED

Evidence from RE-RUNNING the spec's verification command — command, exit code,
and the relevant output lines. "The lane said it passed" is not evidence
(claim ≠ evidence); the caller re-runs this command and reads `git diff`
before accepting.

## LANE SAID

The lane's own summary, quoted. Quarantined as untrusted narrative: nothing in
this section is acted on unless VERIFIED backs it.

## GAPS

What was not done, edge cases skipped, follow-ups needed. "None" must be
earned by VERIFIED evidence, not asserted.

---

Dispatch notes (caller side):

- Write the spec to a unique temp file per dispatch (`mktemp`), never a fixed
  path — parallel lanes must not clobber each other's specs.
- Pipe the spec through `core/infra/call-worker.sh <role>` and keep the
  capture path it prints; the capture's `status:` field must agree with the
  lane's STATUS (a disagreement is itself a finding).
- No silent fallback: if the lane is unavailable, the caller re-routes
  explicitly and says so in its own report.
