---
name: persona-review
description: Seat a panel of real-distribution-grounded Korean citizen personas in front of a piece of UX, copy, or content and report how ordinary users would react. Samples 5 personas from a catalog, dispatches each as an independent panelist, and synthesizes their reactions. NOT a code/security/performance review (those are code-reviewer / security-reviewer lanes) and NOT a substitute for real user testing — it is a fast, diverse first-read stand-in.
when_to_use: You want a user/citizen perspective on something people will read or use — a landing page, onboarding, pricing copy, an email, an error message, a feature's wording — and ask "how would ordinary users react", "run a persona panel", "user-perspective review", or "/persona-review <target>".
tools: Read, Grep, Glob, Agent
---

# /persona-review

## Goal

Answer one question with evidence from a **diverse panel of ordinary users**:
*how would real people react to this?* You seat five synthetic-but-grounded
Korean personas — sampled from Korean census distributions — in front of a
target artifact and report their reactions, frictions, and what to change.

This is a **citizen/user lens**: comprehension, trust, tone, and clarity. It
stands beside `code-reviewer` (correctness) and `security-reviewer`
(vulnerabilities) and replaces neither. A panelist may *voice* a worry that is
really a security or correctness concern ("is my data safe here?") — capture it
as a user worry and route it to the right reviewer; do not adjudicate it here.

**Leading word: panel.** Five independent voices, then one synthesis — not one
voice pretending to be five.

## Inputs

- **Target** — the artifact under review: a URL, a file path, pasted copy, a
  screenshot description, or a component. Required.
- **Question** (optional) — what to probe: first-read comprehension, trust,
  tone, call-to-action clarity, pricing legibility. Default when unstated:
  *first-time-visitor comprehension + trust*.
- **Catalog** — `skills/persona-review/personas/catalog.json` (shipped). If it
  is missing or unparseable, stop and say so — do not invent personas.

## Steps

### 1. Load the catalog

Read `skills/persona-review/personas/catalog.json` and confirm
`personas` is a non-empty list. Each entry carries `age`, `sex`, `province`,
`occupation`, `education_level`, a one-line `summary`, and `hobbies` / `skills`.
**Completion criterion:** you can name the persona count and it is > 0.

### 2. Frame the target

State, in one line each: *what* the artifact is, and *which* question the panel
answers. If the caller gave only "review this", use the default question. If the
target is a URL or file you can open, open it first so panelists react to real
content, not a guess.

### 3. Seat 5 panelists (spread, not convenience)

Pick five personas that **spread across** age bucket, region (province), and
occupation — not five who cluster. A concrete rule that works: sort by a key
that rotates each run (e.g. offset by how many times this target was reviewed),
then walk the list skipping any persona whose (age_bucket, province) pair is
already seated until you have five. **Completion criterion:** the five seated
personas cover at least three distinct age buckets and four distinct provinces.

### 4. Dispatch the panel (parallel, independent)

Spawn **five `general-purpose` agents in one message** (five tool calls in a
single turn, so they run concurrently). Give each ONE persona and the target.
Panelist prompt template:

> You are reacting to <target> **only as this person** — do not break character,
> do not review code or design systems, do not be agreeable to please. You are:
> <persona summary; age; sex; province; occupation; education; hobbies>.
> React honestly as this person would on first encounter:
> 1. In one sentence, what do you think this is?
> 2. What, if anything, confuses you or makes you hesitate?
> 3. Would you trust it / act on it? Why or why not?
> 4. One thing that would make it clearer or more convincing for *you*.
> Answer in Korean, in this person's voice and register. 6 sentences max.

Independence matters: do not let one panelist see another's answer. Do not
answer on their behalf if a dispatch fails — re-dispatch or report the gap.

### 5. Synthesize

Collect the five reactions and write ONE report (schema below). Order it:
reactions **shared** across panelists first (these are the strongest signals),
then **segment-specific** friction (attributed to the persona segment that
raised it), then **prioritized recommendations**. Route any user-voiced
security/correctness worry to the owning reviewer under "Out of lane".
**Completion criterion:** every finding traces to at least one seated panelist;
no finding is invented to round out the report.

## Output

```markdown
## Persona panel review — <target>

**Panel** (5): <age·sex·region·occupation one-liners>

### Shared reactions
- <what most/all panelists felt> — <which segments>

### Segment-specific friction
- [<age·region·occupation>] <what tripped this persona> — <why it matters>

### Recommendations (prioritized)
1. <change> — addresses <friction>, for <segment>

### Out of lane (routed, not judged)
- <user-voiced security/correctness worry> → security-reviewer / code-reviewer

### Panel verdict
<one line: ships-for-users / needs-work / confusing — for whom>
```

## Boundaries

- **Not code/security/performance review** — route those concerns; don't judge them.
- **Not real user testing** — a diverse, fast stand-in that surfaces likely
  friction early; say so when the stakes call for real users.
- **Personas are synthetic** — every persona is NVIDIA Nemotron synthetic data,
  grounded in real distributions but describing no real individual (any Korean
  name in a summary is generated, not a real person's). Don't treat a persona as
  a real person or add fields to it.
- **No fabricated reactions** — an unraised concern is not a finding.

## Regenerating the catalog

The shipped catalog is a stratified subsample of the public
`nvidia/Nemotron-Personas-Korea` dataset (CC BY 4.0). To rebuild it (e.g. a
larger or re-seeded sample):

```
python3 skills/persona-review/scripts/build_catalog.py --size 120 --seed 42
```

Attribution and modification notes live in the catalog's `_meta` block; keep
them intact — CC BY 4.0 requires crediting the source and marking changes.
