# Plan-First & Clarifying Questions

4-tier classification for incoming user requests. Determines whether to
plan-mode, ask, or just execute.

## Tiers

| Tier | Signal | Action |
|---|---|---|
| `trivial` | Single-file edit, 1-line answer, known path. | Execute directly. No plan, no clarifying-Q. |
| `interactive` | Ambiguity present; 2+ valid interpretations. | **Ask** clarifying questions (1-3) **before** acting. |
| `autonomous` | Slash-command or explicit "full auto" phrase. | Execute the plan if one exists; otherwise enter plan-mode briefly, then execute. |
| `conversational` | User wants to think out loud, not act. | 2-3 sentences, recommendation + tradeoff. Don't implement. |

## Classification signals

### `trivial`
- "what is X" / "where is Y"
- "rename A to B" (single concrete target)
- "fix this typo"

### `interactive`
- "add a … to …" without naming the file
- "improve …" / "make … better"
- Multiple files plausibly affected
- Risk-area words ("deploy", "migrate", "secrets", "billing")

### `autonomous`
- Slash command (`/wrap`, `/supervise`, `/tdd`, …)
- "go ahead" + earlier-named plan
- "do all of it" / "full auto" + clear plan in context

### `conversational`
- "what do you think about …"
- "how should we approach …"
- "is there a better way to …"

## Clarifying-Q quality (for `interactive`)

When asking, follow these:

1. **Ask only what blocks you.** Not preferences you can guess from context.
2. **Offer concrete options, not open-ended prompts.** ("Option A: …, Option B: …" beats "How do you want this?")
3. **Max 1–3 questions per turn.** Batch them.
4. **Include risk-area trade-offs.** If one option touches `secrets`,
   surface it.

## When to skip clarifying-Q

- User has said "B-2 OFF" / "minimal Qs" / "just decide" — respect that
  preference (memory `feedback_*` entry persists across sessions).
- Question is about preference, not blocking ambiguity.
- Answer is obvious from prior conversation context.

## What "plan-first" means

For `autonomous` work without an existing plan: enter plan-mode briefly,
produce a short plan (1-page max for ≤ 3 waves), get user approval, then
execute. Don't write the plan to a file unless multi-wave.
