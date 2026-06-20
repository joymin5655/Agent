# Specialist Routing — domain-anchored matchers + ghost fallback

Portable lessons for any registry-aware supervisor/router (the v0.2.0 orchestrator port
target, `core/hooks/supervisor.py`). Both come from a recurring real-world false-positive:
a globe/Three.js client edit kept routing to a non-existent `edge-fn-dev` specialist, three
sessions in a row, forcing a manual `executor` workaround.

## Lesson 1 — Match on domain anchors, never generic tokens

An intent matcher's keywords must be **specific to the domain**, not common English/Korean
words that appear across unrelated domains.

**Anti-pattern (what bit us):**

```python
"edge-fn-dev": re.compile(r"(Edge Function|Deno|API|endpoint|webhook|JWT|CORS|Polar)")
```

`API` / `endpoint` are generic — client code (WebGL render API, browser API, a `fetch` to an
endpoint) contains them, so a globe component matched `edge-fn-dev` and the router suggested a
specialist that wasn't even in session.

**Fixed — domain anchors only:**

```python
"edge-fn-dev": re.compile(
    r"(Edge Function|supabase/functions|Deno\.serve|\bDeno\b|\bCORS\b|webhook|Polar|functions\.invoke)"
)
```

Rule of thumb: if a token would match the *consumer* of a thing as often as its *author*
(e.g. "API" matches both API callers and API builders), it is too generic — anchor on the
runtime/path/library that only the author's code contains (`supabase/functions`, `Deno.serve`).
Prefer a small false-negative (miss a vaguely-worded request) over a cross-domain false-positive
(mis-route every component that says "API").

## Lesson 2 — Ghost-agent fallback (never ask for a phantom)

A matcher can name a specialist that has **no provider in the current session** (a "ghost" —
matched only as a reference candidate, not an executable agent). The router must not (a) silently
drop it, nor (b) ask the user to dispatch a phantom. It must suggest a **real fallback** — a
general capable executor.

```
matched specialist has an in-session provider?
  ├─ yes → recommend it
  └─ no (ghost / reference-only)
        → recommend the executor fallback ("oh-my-claudecode:executor" or project equivalent)
          as a one-line advisory; do NOT block, do NOT ask for the phantom
```

This matters most for **SIMPLE_EDIT** intents, where the executable-agent list is intentionally
cleared for noise control — the ghost match still lands in the reference list and would
otherwise vanish. Surface it as a soft hint so the capable fallback is offered instead of the
edit silently proceeding with no specialist context.

## Applying this in the orchestrator port

When porting the full registry-aware supervisor into `core/hooks/supervisor.py`:

1. Keep matchers domain-anchored (Lesson 1) — review every token against "could a consumer of
   this domain write it?".
2. Split matched agents into `executable` (has provider) vs `reference` (ghost). The advisory
   path must name the **executor fallback** for ghosts and for `reference`-only SIMPLE_EDIT
   matches (Lesson 2).
3. Advisories are **stderr, never blocking, fail-safe** (a routing-advisory exception must
   never block the tool). Keep security-specialist routing (auth/secret/injection) on its own
   matcher so narrowing one domain never weakens safety routing.

## Provenance

AirLens audit `airlens-groovy-robin` (2026-06-20). Empirically the lone offending token was
`API`; the fix + a 7-case reproduce test live in the AirLens consumer tree. This rule lifts the
reusable shape into the portable harness so other projects inherit it.
