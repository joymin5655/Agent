# mattpocock/dictionary-of-ai-coding

- **Clone**: `_repos/reference/mattpocock-dictionary-of-ai-coding` (shallow)
- **License**: none declared (no `LICENSE` file — content, not code; typical for a
  publish-to-web glossary) · **Stars**: 3,136 · **Pushed**: 2026-07-02 (active)

## Purpose

A plain-English glossary of AI-coding vocabulary (published at aicodingdictionary.com):
terms like Agent, Context, Compaction, Effort, Prefix cache, Sandbox, Harness, MCP,
Progressive disclosure, organized into curriculum sections (The Model; Sessions, Context
Windows & Turns; ...). Positioned explicitly against "manufactured confusion" in AI-coding
jargon.

## Architecture

- `dictionary/<Term>.md` — one file per term (flat directory, ~50+ terms observed).
- `internal/generate-readme.ts` + `internal/Curriculum.md` + `internal/README.template.md` —
  `npm run generate` assembles the term files into the single README.md table of contents +
  body, in curriculum order. `README.md` carries an explicit `GENERATED FILE — DO NOT EDIT`
  banner.
- No runtime component — this is a static content repo with a small build script, not a tool
  or library.

## Install / distribution mechanism

N/A — nothing to install. It's read, not run. (OpenKnowledge-precedent check is moot: no
installer of any kind exists.)

## Key patterns worth absorbing

- The generate-from-source-files-into-one-README pattern (`internal/generate-readme.ts` +
  banner comment marking the output as generated) is a clean, small convention worth noting in
  passing, but this harness has no glossary/dictionary artifact that would use it.

## Overlap with this harness

None structurally. Thematic overlap only: this harness's own docs (e.g.
`docs/model-routing.md`, skill descriptions) occasionally use terms this dictionary defines
(effort, harness, context, compaction) but the harness doesn't maintain — and doesn't need — a
formal glossary of its own.

## Security notes

None applicable — static markdown content, no executable surface beyond a local `tsx`
build script that only reads/writes within the repo.

## Verdict

REJECT for harness adoption — not a tool or pattern this repo's harness can absorb; it's
reference content for a human reader, not an agent behavior. Flagged as a candidate for a
**brain-note bookmark** (2_BRAIN reference, not a harness artifact) given it directly explains
several terms this harness's own docs use without defining (effort, harness, compaction,
progressive disclosure) — but that ingestion is explicitly out of scope for this wave
(2_BRAIN distillation happens later via `/brain-ingest`, per the delegation contract's
boundaries) and is not executed here.
