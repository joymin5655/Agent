# Layout Composition Doctrine

Last updated: 2026-05-06

Use this reference when AirLens layout work needs more than basic alignment advice. It distills the user's latest layout/composition transcripts into practical rules for the `airlens-design-director` skill.

## Core Thesis

Good layout is not just grid compliance. It is controlled eye movement, meaningful hierarchy, intentional space, and transferable identity. Break rules only after defining the structure they are breaking from.

For AirLens, visual expression must still serve scientific trust. Dashboards, policy analysis, and model results should feel calm, legible, and data-dense. Brand moments, onboarding, Camera AI, and globe experiences can carry more tension, overlap, asymmetry, and motion when those moves make the product easier to understand.

## The LIFT System

### 1. Leverage Point

The leverage point is the first thing the viewer must notice. It can be a model, product, headline, metric, map region, camera result, risk state, or call to action.

Use:

- Scale
- Contrast
- Position
- Isolation
- Color accent
- Motion or implied motion
- Supporting elements that point toward it

Rules:

- Ask: "What is the single most important thing on this layout?"
- Push back anything that competes with it.
- Busy layouts may have multiple leverage points, but each proximity group needs its own clear priority.

AirLens examples:

- Globe route: selected region, station, or data layer is the leverage point.
- Camera AI: PM2.5 estimate plus confidence/uncertainty is the leverage point, not decorative framing.
- Policy route: causal result or scenario delta is the leverage point, with caveats close enough to be read.

### 2. Internal Rhythm

Internal rhythm is eye choreography. It defines how the eye moves after the first hit.

Use:

- Consistent margins and gutters to build trust
- Predictable grouping for related information
- Purposeful shifts to re-engage attention
- Fast rhythm for skimmable content
- Slower rhythm for dense, deliberate analysis

Ask:

- How does the eye move across the layout?
- Are transitions smooth or jumpy?
- Are related elements visually grouped?
- Does spacing control the speed of engagement?

### 3. Friction And Flow

Friction is a deliberate interruption: tight spacing, jarring shape, rotated block, rough texture, cropped image, clipped word, dense cluster, or unexpected overlap.

Good friction:

- Slows the viewer at a key message
- Adds energy without hiding the message
- Reinforces tone or meaning
- Lives inside a clearly readable flow

Bad friction:

- Creates accidental clutter
- Adds competing focal points
- Hides labels or controls
- Makes scientific or operational screens feel unreliable

AirLens rule: use friction for attention, never for ambiguity in AQI, uncertainty, consent, policy, auth, pricing, or safety copy.

### 4. Transferability

A layout is not solved until it survives format changes.

Test:

- Mobile and desktop
- Thumbnail scale
- Dark and light backgrounds
- Dense and sparse data states
- Loading, error, empty, and long-text states
- i18n expansion
- Reduced motion

The core hierarchy should remain recognizable when simplified or rearranged.

## Movement And Flow Levels

### Level 1. Direct Visual Guidance

Arrows, gaze direction, diagonal blocks, and obvious paths tell the eye exactly where to go. Use sparingly when clarity matters more than subtlety.

### Level 2. Hierarchy-Driven Flow

Size, weight, contrast, and spacing create an invisible path. This is usually preferable for AirLens because it feels calm and professional.

### Level 3. Main Route Plus Micro Routes

A design can have a primary journey and smaller loops. Micro routes increase time on design but must reconnect to the main path.

Use for:

- Dashboard panels with a main metric and supporting readings
- Camera AI result plus explanation chips
- Policy scenario summary plus caveat and evidence links

### Level 4. Implied Motion

Static design can feel alive through repetition, progressive scaling, blur, directional texture, gradients, or repeated geometric forms.

Use for:

- Atmospheric movement
- Sensor/network flow
- Forecast progression
- Camera capture analysis

Avoid when it competes with chart reading or map interpretation.

### Level 5. Deliberate Flow Disruption

A disruption blocks or bends the eye path, causing pause and re-engagement. It is a high-risk move.

Use only when:

- The pause reinforces the message
- The user can still recover the path
- The disruption does not hide functional UI

### Level 6. Temporal Flow

Temporal flow controls when the eye moves, slows, pauses, and releases. Think in beats:

- Punch: fast first impact
- Linger: detail scan
- Pause: open space or isolated object
- Release: CTA, next action, or summary

For AirLens:

- Punch: current AQI, selected region, Camera estimate, policy delta
- Linger: uncertainty, DQSS, SHAP rationale, source details
- Pause: negative space around the key result
- Release: next action, compare, save, report issue, open detail

## Grid Doctrine

Grids determine hierarchy, spacing, readability, and flow. They also make intentional grid-breaking possible.

### Useful Grid Types

- **Baseline grid:** aligns body text, headlines, captions, and dense report copy.
- **Column grid:** good for editorial pages, dashboards, landing sections, and multi-content pages.
- **Modular grid:** good for cards, products, stations, captures, feature lists, and repeatable data modules.
- **Manuscript grid:** best for long-form text and reports.
- **Hierarchy grid:** places large primary blocks and smaller secondary blocks by importance.
- **Asymmetric grid:** adds dynamic energy while staying organized.
- **Square grid:** works for galleries and repeated visual objects.
- **Compound grid:** combines column and modular logic for complex products.
- **Isometric/circular/triangular grids:** use for specific illustration, logo, or geometric systems, not general dashboards.

### Breaking The Grid

Break the grid only after defining the grid.

Allowed reasons:

- Clarify a leverage point
- Create useful tension
- Reinforce brand tone
- Add depth or motion
- Connect elements across space

Required anchors:

- Shared edge
- Aligned centerline
- Repeated margin
- Visual continuation
- Negative-space path
- Proximity group

Do not use random misalignment as style.

## Negative Space Doctrine

Negative space is active, not empty.

Jobs it can do:

- Frame a product, metric, or region
- Create premium focus
- Separate dense data groups
- Slow the eye before a key action
- Give the viewer a pause after complexity
- Route attention between elements

Ask:

- Is this space accidental or designed?
- What does this space make the user look at?
- Does the space improve comprehension or just waste room?

AirLens rule: data-dense screens can still use negative space, but it should create scan lanes and grouping, not empty marketing filler.

## Overlap And Layering

Overlap creates depth, rhythm, narrative, and connection. Text, imagery, gradients, shapes, and data overlays can interact instead of sitting in isolated boxes.

Use when:

- Text and image belong to the same idea
- A data overlay needs to feel part of the scene
- A card needs stronger priority
- Motion or energy helps the subject

Avoid when:

- It clips important labels
- It reduces contrast
- It hides controls
- It makes chart/data interpretation harder

## Contrast And Tension

Contrast is not only light versus dark.

Use:

- Big against small
- Dense against open
- Bold against quiet
- Motion against stillness
- Clean structure against rough texture
- Symmetry against controlled imbalance

The brief decides the amount. A provocative campaign can use high tension. An insurance-like trust screen, policy report, or scientific dashboard needs quieter contrast.

## Trust Your Eye Over Tools

Use guides and grids to establish structure, then adjust optically. Some elements need slight visual correction to feel aligned even when the numeric alignment is perfect.

Rules:

- Optical correction is allowed.
- Document the reason when the correction creates non-obvious asymmetry.
- Never use "trust your eye" as an excuse for unchecked spacing, clipped text, or broken responsive behavior.

## Layout Review Questions

Ask these before implementation:

- What is the leverage point?
- Are elements merely aligned, or are they communicating?
- What is the primary eye path?
- Are there useful micro routes?
- Where does the eye pause?
- Where does the eye accelerate?
- Is negative space doing a job?
- Is grid-breaking anchored by a broader structure?
- Does overlap create relation or clutter?
- Is friction clarifying the message or creating noise?
- Does the design fit the audience and brief?
- Does it survive mobile, desktop, thumbnail, dark/light, loading, error, empty, and i18n states?

## AirLens-Specific Defaults

- Operational dashboards: calm hierarchy, strong scan lanes, low friction, high density.
- Globe and immersive data: stronger leverage point, implied motion, controlled asymmetry, visible uncertainty.
- Camera AI: image/result pairing, local inference trust, clear confidence and caveats, no decorative clutter around the estimate.
- Policy intelligence: report-like rhythm, strong caveat proximity, restrained contrast, evidence links near claims.
- Onboarding/brand moments: more emotional motion and asymmetry allowed, but first screen must remain usable.

## Output Expectation For Agents

When using this doctrine, the agent should state:

- Leverage point
- Primary flow
- Micro flow
- Grid strategy
- Negative-space job
- Friction point
- Temporal rhythm
- Transferability checks
- Implementation constraints
