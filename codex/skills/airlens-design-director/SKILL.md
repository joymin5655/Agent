---
name: airlens-design-director
description: Use when designing or redesigning AirLens UI before implementation: landing pages, brand moments, onboarding, pricing, dashboards, and emotionally memorable but guardrailed product experiences. Produces a design brief, not code.
---

# AirLens Design Director

Use this skill before implementing meaningful AirLens UI changes where visual direction, product psychology, hierarchy, or memory encoding matters.

This skill is for Codex only. Keep Claude-specific runtime APIs out of this file.

## Source Material

- `Obsidian-airlens/wiki/architecture/agent/ui-ux-pro-max-skill.md`
- `AirLens-web/.codex/skills/airlens-frontend/SKILL.md`

## Guardrails First

AirLens guardrails override creative direction:

- Preserve WCAG 2.2 AA: keyboard access, visible focus, contrast, names.
- Use Aurora tokens and existing UI primitives first.
- Do not create text overlap, clipped labels, or hidden controls.
- Keep operational/data screens quiet, scannable, and information-dense.
- AQI color always needs labels; predictions need uncertainty and quality signals.
- All user-facing strings go through i18next.
- No unsupported ML, health, or product claims.
- Avoid decorative orbs, filler hero sections, and generic marketing layouts.

## Design Protocol

1. Read nearby UI, route, and design-system code before proposing direction.
2. Define the intended emotional state after 5 seconds and after one day.
3. Apply the rent test: keep only elements that earn their place.
4. Use controlled imbalance only to clarify priority, flow, or meaning.
5. Add one memorable visual metaphor tied to AirLens: atmosphere, measurement, uncertainty, policy impact, or camera-based environmental memory.
6. Convert the direction into implementation constraints for layout, components, motion, responsive behavior, copy, accessibility, and review.

## Output Shape

For design-direction tasks, produce:

```markdown
Design Direction: <short title>

Emotion Target
- 5 seconds:
- One day:

Rent Test
- Keep:
- Evict:

Intentional Imbalance
- Pattern:
- Why it improves understanding:
- Guardrail:

Memory Encoding Twist
- Metaphor:
- Where it appears:
- Why it will not harm usability:

Implementation Brief
- Layout:
- Components:
- Motion:
- Responsive:
- Copy/i18n:
- Accessibility:

Review Gates
- UX:
- Style:
- Visual/manual:
```

If the request is a small component tweak, keep the brief short and continue with the normal `airlens-frontend` workflow.
