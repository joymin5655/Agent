# Intake restatement — <slug>

One restatement per supervise run, written BEFORE plan validation and wave
classification. The user's chat prompt is optimized for a human reader;
dispatch decisions need a machine-checkable restatement. Every downstream
delegation contract must trace to this file — a wave that serves a goal not
named here is scope drift. Persisted at `.agent/plans/<slug>/RESTATEMENT.md`;
audited by `/manager-audit` lane `restatement-quality`.

## Original ask (verbatim)

<the user's invocation text, quoted exactly — no paraphrase, no trimming.
This is the audit anchor: everything below must be derivable from it plus
the plan objective>

## Interpreted goal

<one or two sentences: what outcome the user actually wants, restated
precisely. Resolve pronouns, name concrete artifacts and paths>

## Assumptions

<each interpretation choice made where the original ask was ambiguous —
one bullet per assumption, with the reading chosen and why. "None" only
when the ask was fully unambiguous>

## Out of scope

<what a reasonable reader might include but this run will NOT do — the
fence that keeps waves from drifting. Never empty: every ask has a larger
version of itself that is not being attempted>

## Success criteria (measurable)

<how the user knows this run succeeded — runnable commands, file paths
that must exist, observable states. Numbers, paths, and commands, not
adjectives. Same discipline as the delegation contract's executable
acceptance criteria>

## Open questions

<ambiguities that materially change the spec and could NOT be resolved by
assumption. If non-empty and the run is not full-auto: surface to the user
before dispatching Wave 1. "None" is the normal healthy state>
