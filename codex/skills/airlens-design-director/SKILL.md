---
name: airlens-design-director
description: "Use when designing or redesigning AirLens UI before implementation: landing pages, brand moments, onboarding, pricing, dashboards, and emotionally memorable but guardrailed product experiences. Produces a design brief, not code."
---

# AirLens Design Director

Use this skill before implementing meaningful AirLens UI changes where visual direction, product psychology, hierarchy, layout composition, conversion, or memory encoding matters.

This skill is for Codex only. Keep Claude-specific runtime APIs out of this file.

## Source Material

- `Obsidian-airlens/wiki/architecture/agent/ui-ux-pro-max-skill.md`
- `Obsidian-airlens/wiki/sources/design-psychology-satori-graphics-2026.md`
- `Obsidian-airlens/wiki/concepts/design-psychology-doctrine.md`
- `Obsidian-airlens/wiki/concepts/layout-composition-doctrine.md`
- `Obsidian-airlens/wiki/synthesis/airlens-design-agent-upgrade-2026-05-06.md`
- `Obsidian-airlens/wiki/sources/open-design-nexu-io-2026-05-06.md`
- `Obsidian-airlens/wiki/concepts/open-design-craft-doctrine.md`
- `Obsidian-airlens/wiki/concepts/skill-operations-protocol.md`
- `references/layout-composition-doctrine.md` in this skill as a local fallback when the wiki reference is unavailable.
- `apps/web/.codex/skills/airlens-frontend/SKILL.md` or `AirLens-web/.codex/skills/airlens-frontend/SKILL.md`, depending on checkout layout.

## Guardrails First

AirLens guardrails override creative direction:

- Preserve WCAG 2.2 AA: keyboard access, visible focus, contrast, names.
- Use Aurora tokens and existing UI primitives first.
- Do not create text overlap, clipped labels, hidden controls, or unreadable chart/map labels.
- Keep operational/data screens quiet, scannable, and information-dense.
- AQI color always needs labels; predictions need uncertainty and quality signals.
- All user-facing strings go through i18next.
- No unsupported ML, health, policy, or product claims.
- Avoid decorative orbs, filler hero sections, generic marketing layouts, and one-note palettes.
- Paid conversion must not overpower data trust, consent clarity, or uncertainty disclosure.
- Avoid Open Design anti-slop regressions: default indigo, purple-blue trust gradients, emoji feature icons, colored-left-border AI cards, invented metrics, and filler copy.
- Cap non-AQI accent use to a small, intentional pair: primary action, selected state, or one memory cue.
- Stateful UI must plan loading, empty, error, populated, and edge states.
- Motion must support spatial, temporal, or state reorientation and respect reduced-motion.

## Design Protocol

1. Read nearby UI, route, and design-system code before proposing direction.
2. Define audience psychology: target audience, deeper why, and desired emotional axis.
3. Define the intended emotional state after 5 seconds and after one day.
4. Run the L.I.F.T check: leverage point, internal rhythm, friction/flow, and transferability.
5. Declare eye choreography: primary path, secondary/micro paths, pauses, acceleration, and release.
6. Choose a grid strategy first, then break it only with visible intent: shared edge, centerline, repeated margin, proximity group, or meaningful tension.
7. Assign negative space a job: frame, pause, route, premium emphasis, grouping, or separation.
8. Apply the rent test: keep only elements that earn their place.
9. Explain shape/color/type rationale before implementation instructions.
10. Define symbolic interaction: visual cues, gesture/state cues, and labels that must be immediately understood.
11. Tie the direction to product/marketing function: CTA, KPI, conversion or retention, recall, and trust signal.
12. Use controlled imbalance, overlap, or convention-breaking only to clarify priority, flow, tone, or meaning.
13. Add one memorable visual metaphor tied to AirLens: atmosphere, measurement, uncertainty, policy impact, or camera-based environmental memory.
14. Run an Anti-Slop Check: state where AI-template perfection is intentionally broken and why it remains usable.
15. Run Open Design craft checks: default-indigo/AI-gradient avoidance, accent cap, filler-copy removal, invented-metric removal, state coverage, motion restraint, and accessibility floor.
16. Convert the direction into implementation constraints for layout, components, motion, responsive behavior, copy, accessibility, and review.

## Composition Doctrine

Use these rules as the default layout critique lens:

- **Leverage point:** identify the first thing the user must notice; protect it with scale, contrast, position, isolation, or motion.
- **Internal rhythm:** make the eye path feel choreographed, not merely aligned. Consistent spacing builds trust; purposeful shifts re-engage attention.
- **Flow levels:** use explicit directional cues only when needed; prefer hierarchy-driven flow, micro routes, implied motion, deliberate disruption, and temporal rhythm.
- **Grid discipline:** baseline, column, modular, hierarchy, asymmetric, compound, square, circular, triangular, or isometric grids are tools. Bending a grid is allowed only when the break still relates to a broader anchor.
- **Negative space:** treat empty space as active structure. It controls pacing, focus, hierarchy, perceived value, and parsing.
- **Overlap and layering:** let elements touch, bleed, or cross boundaries only when it connects related information, adds depth, or creates narrative energy.
- **Friction:** use tension like seasoning. Good friction slows the eye at a key message; bad friction hides the message.
- **Contrast:** create attention with big/small, dense/open, bold/quiet, motion/stillness, clean/gritty, and light/dark relationships.
- **Transferability:** the core hierarchy and identity must survive mobile, desktop, thumbnail, dark/light backgrounds, dense data states, loading, error, empty, long locale, and reduced-motion states.
- **Brief fit:** never make a chaotic, provocative layout when the user need is operational confidence, policy clarity, privacy trust, or scientific interpretation.
- **State coverage:** plan loading, empty, error, populated, and edge states for every data/form/list/table surface.
- **Motion restraint:** animate only for navigation, progress, container expansion, gesture follow-through, or state confirmation.

## Psychology Doctrine

Use these rules before recommending visual treatment:

- **Audience psychology:** name the user segment, deeper why, and emotional axis before style.
- **Shape:** circles/ovals soften and unify; squares/rectangles organize and stabilize; triangles move or warn; hexagons imply networks; organic shapes connect to sky/nature; lines route attention.
- **Color:** saturation creates dopamine and urgency; low saturation supports trust; contrast creates priority; AQI colors require labels; red urgency is powerful and must be restrained.
- **Typography:** typeface personality must match product meaning. Dense operational screens prioritize legibility; brand moments may carry stronger type personality.
- **Memory encoding:** use one memorable metaphor or repeated cue. Avoid multiple competing flourishes.
- **Symbolic interaction:** icons, states, gestures, and visual metaphors must be immediately understood or labeled.
- **Marketing function:** CTA, KPI, conversion/retention role, recall, and trust signal must be explicit.
- **Behavioral laws:** use Von Restorff for one isolated action, Hicks law to reduce choices, Gestalt for grouping, dual coding for text+visual comprehension, F-pattern for scan lanes.
- **Predictive empathy:** reduce uncertainty, privacy anxiety, billing ambiguity, permission friction, and health/policy overclaim risk before the user hits them.
- **Open Design craft:** remove default-indigo, accent flood, AI trust gradients, filler copy, invented metrics, emoji-as-icons, and typography misuse before implementation.

## Output Shape

For design-direction tasks, produce:

```markdown
Design Direction: <short title>

Audience Psychology
- Target audience:
- Deeper why:
- Desired emotional axis:

Emotion Target
- 5 seconds:
- One day:

Rent Test
- Keep:
- Evict:

Composition Map
- Leverage Point:
- Primary Flow:
- Micro Flow:
- Grid Strategy:
- Negative-Space Job:
- Friction Point:
- Temporal Flow:
- Transferability Check:

Shape/Color/Type Rationale
- Shape:
- Color saturation/contrast:
- Typography personality:

Symbolic Interaction
- Immediate cues:
- Gesture/state cues:
- Labels needed:

Marketing Function
- CTA/KPI:
- Conversion or retention role:
- Recall signal:
- Trust signal:

Intentional Imbalance
- Pattern:
- Why it improves understanding:
- Guardrail:

Memory Encoding Twist
- Metaphor:
- Where it appears:
- Why it will not harm usability:

Anti-Slop Check
- Template break:
- Human intent:
- Risk check:

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
