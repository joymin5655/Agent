# Agent Brain — note schema

The cross-AI agent brain is a **domain-neutral, machine-writable typed-edge
atomic-note store** shared across Claude / Codex / Gemini sessions. It mirrors the
Zettelkasten schema of a curated wiki vault, but adds a `provenance:` block so a
re-ingest touches only AI-authored material and human-curated content is never
silently overwritten.

## Layout

```
<brain>/notes/<type>/<id>.md          curated typed atomic notes  → the queryable graph
<brain>/raw/<ai>/<stamp>-<slug>.md    quarantined session captures → NOT in the graph
<brain>/.graph/{nodes,edges}.jsonl    materialized graph (rebuilt from notes/ by graph.py)
```

`<brain>` = `$AGENT_BRAIN_DIR` if set, else `~/.agent/brain`. It is an **L3 user
store** (see `rules/policy/subagent-memory-policy.md`) — machine-local, never a
personal path hardcoded in shipped code.

## Write policy (the hybrid invariant)

- Agents write **freely to `raw/`** (session capture, quarantine).
- `notes/` is written **only** by the distill (`/brain-ingest`) and seed paths —
  never by a raw capture, never by an agent mid-turn.
- Promotion is one-way: `raw/ → notes/` (brain gate) → the human-curated vault
  (via the vault's own `/wiki-ingest`, never a direct write).

## Frontmatter

YAML between the first two `---` fences. Typed edges use Obsidian `[[wikilink]]`
syntax (not valid YAML), so `edges:` and `provenance:` are read by a line scanner,
not a YAML parser — no third-party dependency.

```yaml
---
id: insight-tls-impersonation        # {type}-{kebab-slug}; matches filename stem
type: insight                        # see "Note types" below
title: "TLS impersonation bypasses naive WAF"
created: 2026-07-20
updated: 2026-07-20
status: seed                         # seed | growing | evergreen | archived | raw
confidence: 0.8                      # optional, 0.0–1.0
edges:
  supports: [[concept-waf]]
  extends: [[insight-bot-detection]]
provenance:
  ai: "claude"                       # claude | codex | gemini — who wrote it
  session: "s2"                      # originating session id
  generated_by: "brain-ingest"       # brain-capture | brain-ingest | brain-seed
  source: "raw:codex/2026...-x"      # semantic origin
  kind: "generated"                  # generated (AI-written) | user (human origin)
---
```

## Note types

`concept · insight · procedure · episode · thesis · topic · entity · source ·
comparison · synthesis` — an unknown type is allowed (lands in its own subdir); the
store never rejects a write.

## Typed edges (10)

`supports · extends · instantiates · refines · near-miss · contradicts ·
triggered-by · requires · topic-tag · thesis-tag`

## provenance.kind — the @generated/@user sentinel

- `generated` — AI-authored; a re-ingest may rewrite it; not trusted until it
  passes the distill gate.
- `user` — human origin (e.g. seeded from a curated vault note); trusted, never
  auto-overwritten.
