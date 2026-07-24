# mattpocock/skills

- **Clone**: `_repos/skills/mattpocock-skills` (shallow, HEAD `ed37663`)
- **License**: MIT · **Stars**: 186,652 · **Pushed**: 2026-07-23 (active) · plugin.json version 1.2.0

## Purpose

A personal Claude Code / Codex / Cursor skill collection ("Agent Skills standard") for
"real engineering, not vibe coding." 22 skills shipped in the installable plugin, spanning
spec/ticket workflows, TDD, code review, domain modeling, and an interview primitive
("grilling") used across several other skills as a shared building block.

## Architecture

- `skills/{engineering,productivity,misc,personal,deprecated,in-progress}/<name>/SKILL.md` —
  standard Agent-Skills frontmatter (`name`, `description`, optional `disable-model-invocation`,
  optional `argument-hint`). `.claude-plugin/plugin.json`'s `skills` array is the actual
  installable set (22 skills, all from `engineering/` and `productivity/`) — `misc/`,
  `personal/`, `deprecated/`, and `in-progress/` are NOT shipped in the plugin; they're
  work-in-progress or single-use skills kept in the repo but excluded from the bundle.
- `.claude-plugin/marketplace.json` — one-plugin marketplace wrapping the whole repo.
- Cross-skill composition: several skills explicitly chain into each other
  (`grill-with-docs` → `domain-modeling`; `improve-codebase-architecture` → grilling loop;
  `to-spec`/`to-tickets` write to a per-repo-configured issue tracker). This is closer to a
  **workflow graph** than a flat skill list — `ask-matt` is a router skill whose sole job is
  picking which flow fits the user's situation.
- Per-repo bootstrapping: `setup-matt-pocock-skills` is a `disable-model-invocation: true`
  skill (must be explicitly run) that asks 3 questions (issue tracker, triage labels, domain
  doc layout) and writes the answers to `docs/agents/*.md` inside the **target repo**, plus a
  `## Agent skills` block appended into `CLAUDE.md`/`AGENTS.md` (edits whichever already
  exists; never creates a duplicate). Other skills (`triage`, `to-spec`, `wayfinder`) read
  those config files at runtime instead of hardcoding GitHub-only behavior — this is how the
  same skill set supports GitHub, GitLab, or a local-markdown issue tracker.

## Install / distribution mechanism — OpenKnowledge precedent check

Applying the check this project used to REJECT OpenKnowledge v0.28.1 (unconsented
npm-postinstall writes to `~/.claude`): **PASS, clean.**

- `package.json` has **no `postinstall` script** (only `changeset`/`changeset version` dev
  scripts) — confirmed via `grep -rl postinstall` across the whole clone, zero hits.
- Two install paths, both explicit and scoped to the *current project*, never global:
  1. `npx skills@latest add mattpocock/skills` — third-party `skills.sh` installer, copies
     selected skill files into the project (user picks skills + target agents interactively).
  2. Native CC plugin: `/plugin marketplace add mattpocock/skills` then
     `/plugin install mattpocock-skills@mattpocock` — this DOES go through Claude Code's own
     plugin machinery (which itself writes to `~/.claude/plugins/`), but that's the standard,
     consented CC plugin flow this project already uses for other plugins — not a bypass.
- `setup-matt-pocock-skills` (the only skill that writes config) writes exclusively inside the
  target repo (`docs/agents/*.md`, `CLAUDE.md`/`AGENTS.md`) — verified by reading its full
  `SKILL.md`. No writes to `~/.claude`, no writes outside the repo it's invoked in.

## Key patterns worth absorbing

1. **`ask-matt` router skill** — a `disable-model-invocation: true` skill whose entire job is
   disambiguating "which of my other skills fits this request," rather than every skill
   competing on trigger-phrase matching alone. This harness's `harness-help` already plays
   this role for the harness's own 8 skills — pattern already absorbed, no action needed.
2. **`writing-great-skills`** — a standalone reference skill (not a workflow) that captures
   *how to write a good skill description* as a citable resource other skill-authoring work can
   point to. This harness has no equivalent meta-skill; `skill-creator` (installed globally,
   not part of this harness) partially covers it. Not distinctive enough over already-installed
   tooling to justify a dedicated absorption.
3. **Per-repo bootstrap skill pattern** (`setup-matt-pocock-skills`) — a one-time, explicit,
   `disable-model-invocation` skill that asks a short fixed question set and writes the answers
   to a *config file the other skills read at runtime*, rather than hardcoding assumptions
   (GitHub-only, English-only, etc.) into every skill. This harness's `project-init` skill
   (agent-harness plugin) already does something similar for project scaffolding — overlapping
   territory, not a gap.
4. **`grilling` as a shared primitive** — a single relentless-interview skill that `grill-me`,
   `grill-with-docs`, `batch-grill-me`, and `improve-codebase-architecture` all invoke rather
   than each reimplementing an interview loop. This harness's `/spec --interview` (F-1, landed
   2026-07-10) already independently converged on the same idea — a structured
   question-then-replan loop gated by decision-changing unknowns — so this is confirmation of
   an existing design choice, not new material to import.

## Overlap with this harness

High conceptual overlap in *category* (both are "planning discipline + verification for coding
agents" skill sets) but low overlap in *mechanism*: this harness enforces its gates with a tool
boundary (spec-gate, hook-based enforcement) and a CI/eval layer (`verify-all.sh`, 27+ checks);
mattpocock/skills is entirely prompt-driven with no enforcement layer — a skill like
`tdd` or `code-review` *asks* the agent to follow a process but has no mechanism preventing
it from skipping steps. That's a real philosophical difference (explicitly called out in their
README as a contrast with "GSD, BMAD, and Spec-Kit" owning the process) — not a defect to fix,
but a reason wholesale adoption doesn't fit: importing prompt-only skills into a
hook-enforced harness would understate what this harness already guarantees mechanically.

## Security notes

- No installer runs arbitrary code; skills are markdown + a handful of static template files
  (`agents/openai.yaml` config stubs for cross-agent metadata).
- `git-guardrails-claude-code` (misc/, not in the shipped plugin) sets up CC hooks to block
  destructive git commands — same intent as this harness's own pre-tool-guard hooks. Read but
  not adopted (duplicate coverage, not evaluated further since it's excluded from the plugin
  bundle mattpocock actually ships).

See `adoption-matrix.md` for the full per-skill verdict table (22 shipped skills compared
against this harness's 8).
