# Skill Authoring Guide

How to write and edit the skills in [`skills/`](../skills/). A skill exists to wrangle determinism out of a stochastic system: **predictability** — the agent taking the same *process* every run, not producing the same output — is the root virtue, and every rule below is a lever on it.

Distilled from Matt Pocock's `writing-great-skills` skill (MIT, © 2026 Matt Pocock, [mattpocock/skills](https://github.com/mattpocock/skills), commit `391a2701dd948f94f56a39f7533f8eea9a859c87`). Terms are his; the frontmatter mapping and examples are ours.

## Invocation: two costs, pick one

- **Model-invoked** — the skill keeps a trigger-rich `description`, so the agent (and other skills) can fire it. Pays **context load**: the description sits in the window every turn.
- **User-invoked** — only a human typing `/name` reaches it. Zero context load, but pays **cognitive load**: the human must remember it exists.

Pick model-invocation only when the agent must reach the skill on its own. When user-invoked skills multiply past memory, the cure is a **router skill** — one skill that names the others and when to reach for each. Ours is [`/harness-help`](../skills/harness-help/SKILL.md); **any skill added or removed must update the router in the same commit** (a router that lies is worse than none).

In this repo the axis maps to frontmatter: `description` states what the skill is and its boundaries; `when_to_use` carries the triggers.

## Writing the description

- **Front-load the leading word** — the description is where it does its invocation work.
- **One trigger per branch.** Synonyms that rename a single branch are duplication ("build features using TDD … asks for test-first development" is one branch written twice). Keep only genuinely distinct branches.
- **Cut identity that's already in the body.**

## Information hierarchy

Skill content is **steps** (ordered actions) and **reference** (consulted on demand), arranged on a ladder by how immediately the agent needs each piece:

1. **In-skill step** — ends on a **completion criterion** that is *checkable* (agent can tell done from not-done) and, where it matters, *exhaustive* ("every modified file accounted for", not "produce a change list"). A vague criterion invites premature completion; a demanding one drives **legwork**.
2. **In-skill reference** — a flat peer-set of rules is fine, not a smell.
3. **Disclosed reference** — pushed to a sibling file behind a **context pointer** (e.g. `supervise/templates/`). Disclose what only some branches need; inline what every path needs. The pointer's *wording* decides whether the agent reaches it — sharpen wording before inlining.

**Co-location**: keep a concept's definition, rules, and caveats under one heading, not scattered.

## Leading words

A **leading word** is a compact pretrained concept the agent thinks with (*tight*, *red*, *refute*, *tracer bullet*). Repeated as a token, it anchors execution in the body and invocation in the description — use the same word in prompts, docs, and code. Prefer an existing word: a coined one recruits no priors. Hunt restatements ("fast, deterministic, low-overhead" → *tight*) and collapse them.

## Pruning

- **Single source of truth** — each meaning lives in one place; changing behaviour is a one-place edit.
- **Relevance** — does the line still bear on what the skill does?
- **No-op test** — does the line change behaviour versus the model's default? Delete failing sentences whole; don't trim words from them.

## Failure modes (diagnosis vocabulary)

| Mode | Symptom | Cure |
|---|---|---|
| **Premature completion** | step ends before genuinely done | sharpen the completion criterion first; split the sequence only if the criterion is irreducibly fuzzy *and* you observe the rush |
| **Duplication** | same meaning in two places | collapse to one source of truth |
| **Sediment** | stale layers nobody removes | pruning pass on every edit |
| **Sprawl** | too long even when all live | disclose reference down the ladder; split by branch |
| **No-op** | line the model obeys by default | delete, or strengthen the leading word (*be thorough* → *relentless*) |
| **Negation** | "don't X" makes X more available | prompt the positive; keep prohibitions only as hard guardrails, paired with what to do instead |

## Repo-specific invariants

- A skill here may be backed by a **gate** (`spec` ↔ spec-gate, `wrap` ↔ gitleaks/risk-area). The SKILL.md documents the process; the hook enforces it. Never let the two drift — `core/tests/doc-reality.sh` is the check.
- Skill count and names are stated in `README.md` and routed in `/harness-help`; both update in the same commit as any skill change.
