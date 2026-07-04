# Concept — Plan Mode + Tier Classification

Some tasks are trivial (typo fix, single-line rename). Others are large (multi-file refactor, new feature, architecture decision). The framework treats them differently.

---

## The 4 tiers

```
trivial          ← typo, 1-line, simple lookup
   ↓ getting heavier
interactive      ← default — ask clarifying questions, suggest approach
   ↓
autonomous       ← user says "just do it" / `/wrap` / `/supervise`
   ↓
conversational   ← multi-turn exploration, brainstorming, "what if..."
```

The tier determines:
- Whether to enter plan-mode before code
- Whether to ask clarifying questions
- Whether to write a plan file
- Whether to commit per-step or in a single PR

---

## How tier classification works

There is no dedicated classifier hook today — `UserPromptSubmit` only runs
`agent-session-heartbeat.sh` (see `hooks/hooks.json`). The AI applies the
heuristics itself when reading the prompt:
1. Reads the user prompt
2. Looks up `hook-config.yml: plan_tier.autonomous_triggers` and the heuristics below
3. Picks a tier and adjusts its own plan-mode / clarifying-question behavior accordingly

Example heuristics:
- "fix this typo" → trivial
- "what does X do?" → trivial (read-only Q&A)
- "add feature X" / "refactor Y" → interactive (default)
- "/wrap" / "/supervise <plan>" / "just do it" → autonomous
- "let's think about..." / "brainstorm..." → conversational

---

## Plan-first discipline (interactive + autonomous tiers)

For interactive and autonomous tiers touching 3+ files:

1. AI reads relevant code (Phase 1 — Understanding)
2. AI proposes a plan (Phase 2 — Design)
3. AI asks the user to approve or refine the plan (Phase 3 — Review)
4. AI writes the plan to `/tmp/agent-plan-<slug>.md` (Phase 4 — Final Plan)
5. AI starts implementation only after user approval (Phase 5 — exit plan-mode)
   - Implemented as a flag file: `core/hooks/plan-gate.py` writes `/tmp/agent-plan-approved` on approval.

Claude Code has native plan-mode with `ExitPlanMode` tool. Codex and Gemini may not — the adapter degrades gracefully by setting `tier=interactive` and asking the user to confirm before any destructive action.

---

## Autonomous tier — when to use

The autonomous tier skips plan-mode and clarifying questions. Use it when:

- You've already discussed the approach with the AI in this session
- The task is well-scoped (clear input / clear output)
- Risk-area safeguards are still active (autonomy doesn't bypass `deny` decisions)

The framework's `/wrap` and `/supervise` skills are autonomous-tier helpers — they bundle commit + push + PR creation OR multi-phase plan execution into one invocation.

Critical: autonomous tier still respects all 5 risk-area layers. If your task touches secrets/migrations/deploys, the hooks still ask/deny. Autonomy means "skip questions about HOW" — not "skip safety".

---

## Trivial tier — when to use

For tier=trivial, the AI:
- Skips plan-mode
- Skips clarifying questions
- Just does it

Examples:
- "Rename `foo` to `bar` everywhere"
- "Fix the typo in line 42"
- "What's the difference between X and Y?"

If you find yourself classified as trivial but the change is risky, ask the user to confirm before edit.

---

## Conversational tier — when to use

Exploration mode. The AI explores without committing. No code changes unless the user says "OK, do it".

The framework has dedicated skills for this:
- `/grill-me` — interview the user
- `/brainstorm` — explore the design space
- `/office-hours` — pre-build product thinking

---

## See also

- [`../../core/hooks/plan-gate.py`](../../core/hooks/plan-gate.py)
- [`../../rules/policy/plan-first-clarifying.md`](../../rules/policy/plan-first-clarifying.md)
- [`../../skills/wrap/SKILL.md`](../../skills/wrap/SKILL.md)
- [`../../skills/supervise/SKILL.md`](../../skills/supervise/SKILL.md)
