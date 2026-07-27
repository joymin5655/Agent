# Launch checklist — distribution & discovery (maintainer-run)

Everything here is an **outward-facing action the maintainer performs
manually** — nothing in this file is automated, and no CI depends on it.
Research basis: 2026-07 survey of the top starred Claude Code ecosystem repos
(see `docs/benchmark/landscape.md`); the consistent star drivers were a
pain-first pitch, a visible demo, one-line install, and directory listings.

## Preconditions (do these before any submission)

- [ ] Demo GIF recorded per `docs/demo.md` and embedded at the top of the
      README (lead with the false-"done" catch).
- [ ] CI badge green on `main`.
- [ ] README opens pain-first with the install one-liner in the first screen.
- [ ] Version tagged and CHANGELOG current.

## Directory / marketplace listings (durable discovery)

| Target | How | Notes |
|---|---|---|
| `hesreallyhim/awesome-claude-code` | PR adding this repo under the harness/tooling section | Follow their CONTRIBUTING format; one-line description + link |
| claudemarketplaces.com | Submission form on site | Marketplace manifest already ships (`.claude-plugin/marketplace.json`) |
| claudebazaar.com | Submission form on site | |
| claudepluginhub.com | Submission form on site | |

One-line description to reuse across listings:

> A safety harness for AI coding agents — machine gates (not prompts) that
> block secret leaks, refute false "done" claims, and enforce plan-first
> discipline, identically across Claude Code, Codex CLI, and Gemini CLI.

## Launch posts (do once, after the GIF exists)

Angle: **do not compete on agent count** — compete on the empty category:
"the harness that catches an agent lying about completion." Concrete, visual,
evidence-cited.

**Show HN draft:**

> Show HN: A safety harness that catches AI coding agents lying about "done"
>
> My AI agent kept telling me tests passed when they didn't. So I built a
> harness of machine gates: a refute-by-default verifier that re-checks every
> completion claim in a fresh context (crash → REFUTED, low confidence →
> REFUTED), PreToolUse hooks that physically block secret reads and force
> pushes, and a CI that verifies the harness itself (the README fails the
> build if it names a file that doesn't exist). Works identically across
> Claude Code, Codex CLI, and Gemini CLI through one decision core —
> cross-CLI parity is machine-tested, not promised. [GIF]

**r/ClaudeAI draft:** same story, more casual, lead with the GIF and the
blocked-secret-read frame; link the self-benchmark (8/8 planted bugs, 0 false
positives — `docs/benchmark/results.md`) with its honest "near-tie" caveat
intact.

**X/Twitter thread skeleton:** 1) the pain (agents claim done), 2) the GIF,
3) "gates not vibes" — one hook example, 4) the triple-audit diagram, 5)
install one-liner + repo link.

## Cross-community (after cross-CLI headline lands in README)

- [ ] Post in Codex CLI and Gemini CLI communities — the harness is one of
      the few governance layers that treats them as first-class runtimes
      (decision parity proven by `core/tests/adapter-parity.sh`).

## Cadence

Revisit listings once per minor release; refresh star-landscape numbers in
`docs/benchmark/landscape.md` on the schedule it documents.
