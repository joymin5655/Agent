---
name: airlens-frontend
description: Use when designing, building, or reviewing AirLens frontend code: React 19/Vite/Tailwind 4 architecture, Aurora UI components, Globe/Canvas rendering, accessibility, i18n, UX, and style compliance.
---

# AirLens Frontend

Use this skill for AirLens web frontend work in React 19, Vite 7, Tailwind CSS 4, Three.js/Canvas, Zustand, i18next, and the Aurora design system.

## First Checks

- Read nearby code before changing architecture, component APIs, stores, or styling.
- For landing, brand, onboarding, pricing, dashboard redesign, or emotionally memorable UI direction, use `airlens-design-director` first and implement from its guardrailed brief.
- Preserve existing patterns unless there is a concrete maintainability or product reason to change them.
- Put new shared types in `src/types.ts`; put constants and thresholds in `APP_CONFIG` at `src/lib/config.ts`.
- Route API access through `src/api/`; do not call Supabase directly from components.
- Keep components under 300 lines and files under 800 lines; extract only when it reduces real complexity.
- All user-facing text must use `t()` from i18next.

## Architecture

- Public pages use `PublicLayout` with Navbar/Footer: `/about`, `/auth`, `/pricing`, `/privacy`, `/terms`.
- Authenticated pages use `AppShell`: SideNav 220px, CommandBar, ContextRail 260px, OpsFooter.
- `/camera` is immersive and hides CommandBar/ContextRail.
- Use existing Zustand stores:
  - `useAuthStore` for Supabase session/profile/plan.
  - `useGlobeStore` for layers, selected marker, globe view state.
  - `useThemeStore`, `useNotificationStore`, `useAirQualityStore` for their existing concerns.
  - Use existing data hooks and TTL cache patterns for server state.
- Pages should remain lazy-loaded through route-level `React.lazy()` and `<Suspense fallback={<PageLoader />}>`.
- Assess bundle impact before adding heavy libraries; Three.js is already a large vendor chunk.

For architecture recommendations, include file structure, component hierarchy, state/data flow, code-splitting impact, and migration steps.

## Components And Styling

- Use Aurora tokens and Tailwind utilities:
  - surfaces: `bg-bg-base`, `bg-bg-card`, `bg-bg-elevated`
  - text: `text-text-main`, `text-text-dim`, `text-text-muted`
  - borders: `border-border-subtle`, `border-border-hover`
  - brand: `text-primary`, `bg-primary`, `text-tertiary`
- Use `src/components/ui/Button.tsx` for buttons; do not use `btn-main` directly in new component code.
- Avoid inline styles and arbitrary Tailwind values unless a token cannot express the design.
- Provide hover, focus-visible, active, disabled, loading, empty, and error states where relevant.
- Animations should use compositor-friendly properties and respect `prefers-reduced-motion` through the existing reduced-motion hook.
- Do not use `any` or production `console.log`.

## Globe And Visualization

- Core files: `src/pages/Globe.tsx`, `src/hooks/useEarthScene.ts`, `src/hooks/useGlobeDrag.ts`, `src/lib/earth/`, `src/store/globeStore.ts`.
- Rendering pipeline: `useEarthScene` -> d3 projection -> map redraw -> overlay draw -> animation canvas.
- Validate all Canvas API parameters with `isFinite` before drawing.
- Guard DPR and container dimensions before rendering.
- Keep draw work inside the requestAnimationFrame budget and avoid independent visualization failures blocking other layers.
- Station data and layer state should flow through `useGlobeStore`, not isolated component-local state.
- Preserve legacy HUD components unless explicitly migrating them: `GlobeHUD`, `NullschoolPanel`, `ColorBar`.
- Check `patches/cobe+*.patch` before COBE changes and provide non-Chrome fallbacks for CSS Anchor Positioning.

## Accessibility And UX

- Target WCAG 2.2 AA.
- Interactive elements must be keyboard reachable, have visible focus, and expose an accessible name.
- Prefer semantic HTML before ARIA; do not add redundant `aria-label`.
- Minimum target size is 24x24 CSS px; prefer 44x44 px for touch.
- Images need `alt`; decorative images use `alt=""`.
- Forms need labels; modals must trap focus and restore it on close.
- AQI color coding requires text labels, not color alone.
- Charts need an `aria-label` or descriptive caption.
- Globe views need a text alternative and visible location context.
- AI predictions must show uncertainty, such as p10-p90 ranges, confidence, and DQSS/quality indicators.

When reviewing UX, lead with concrete findings and include file/line, principle, impact, and fix. Avoid vague approval.

## i18n

- Runtime translations live in `src/locales/{lang}/translation.json`; fallback copies live in `public/locales/{lang}/translation.json`.
- Keep both locations in sync when adding or modifying keys.
- Required languages: `en`, `ko`, `ja`, `zh`, `es`, `fr`; `en` and `ko` must be complete.
- Use hierarchical keys, usually namespace plus `UPPER_SNAKE_CASE`, such as `TODAY.BREADCRUMB_MONITORING`.
- Verify interpolation variables match across languages.
- Search for hardcoded JSX text, `title`, `placeholder`, and `aria-label` strings when adding UI.

## Review Checklist

- AirLens rules: types in `src/types.ts`, constants in `APP_CONFIG`, no hardcoded stats/version/contact values, no unsupported ML feature claims.
- i18n: no hardcoded user text; translation keys added in runtime and fallback locations.
- Accessibility: keyboard, screen reader, focus, contrast, target size, reduced motion.
- Styling: Aurora tokens preferred over hex/rgb/arbitrary px values.
- Glass-Box AI: prediction values include uncertainty and quality signals.
- Duplication: extract repeated logic only when it appears enough to justify a shared abstraction.
