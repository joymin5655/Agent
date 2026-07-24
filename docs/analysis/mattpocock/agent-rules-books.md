# mattpocock/agent-rules-books

- **Clone**: `_repos/reference/mattpocock-agent-rules-books` (shallow)
- **License**: MIT (copyright "Maciej Ciemborowicz") · **Stars**: 333 · **Pushed**:
  2026-05-13 (~2.5mo stale relative to 2026-07-25)

## ⚠️ Authorship correction

**This is NOT an original mattpocock repo — it is a fork.** `gh api repos/mattpocock/
agent-rules-books` confirms `"fork": true, "parent": "ciembor/agent-rules-books"`. The
`LICENSE` file's copyright line and the only commit visible in this shallow clone
(`Update README.md`) are both attributed to Maciej Ciemborowicz (`ciembor`), the original
author — mattpocock's copy appears to be a starred/kept fork, not a repo he authors or
actively maintains. Flagging this explicitly since the delegation contract named it as one of
"mattpocock's agent/AI-relevant repos" — it's in his namespace but not his work.

## Purpose

AGENTS.md-style rule sets / Claude Code skills distilled from 13 classic software-engineering
books (A Philosophy of Software Design, Clean Architecture, Clean Code, Code Complete,
Designing Data-Intensive Applications, Domain-Driven Design ×2, Implementing DDD, Patterns of
Enterprise Application Architecture, Refactoring, Release It!, The Pragmatic Programmer,
Working Effectively with Legacy Code) plus a Refactoring.Guru-derived set.

## Architecture

- One directory per book, each with three compression tiers of the same rule set:
  `<book>.full.md` (canonical, ~300-1000 lines), `<book>.mini.md` (~45-65 lines, "recommended
  for most real task use"), `<book>.nano.md` (~35-45 lines, "compact fallback for very tight
  context budgets"). Line/rule/byte counts are tabulated in the README's release matrix,
  generated deterministically (`wc -l`, markdown-list-item count, `wc -c`).
- `docs/USAGE.md` covers per-editor setup (Codex, Claude Code, Cursor) — always-on vs on-demand
  usage, skills vs scoped rules vs MCP/RAG patterns.
- `docs/COMPATIBILITY.md` and `docs/CRITICISM.md` (the latter explicitly logging "constructive
  criticism from Reddit") — unusually transparent for a rules repo; it airs its own weak points
  rather than only showcasing positives.

## Install / distribution mechanism

No installer script — it's copy-the-markdown-file-you-want into your project's
`AGENTS.md`/rules directory, or point a skill/RAG system at the `full` version. No `postinstall`
possible since there's no `package.json` at all in this repo (pure content).

## Key patterns worth absorbing

- **Three-tier compression (full/mini/nano) of the same rule set**, with counted, tabulated
  size metrics per tier, is a genuinely reusable idea for context-budget-aware documentation —
  broader than this one repo. This harness doesn't currently tier any of its own docs this way
  (e.g. `docs/model-routing.md`, skill SKILL.md files are single-version). Interesting, but
  **not a fit for this wave's scope**: this harness's docs are operational/mechanical
  (routing tables, gate definitions), not book-derived style guidance — there's no rule set
  here that needs a mini/nano compression pass. Noted for awareness only.
- `docs/CRITICISM.md` as a standing "known weaknesses, sourced from public pushback" file is a
  good transparency habit. This harness's own `docs/benchmark/landscape.md` (Wave 4's territory,
  not this dossier's) already plays a similar role by comparing against competitors' strengths.

## Overlap with this harness

None. This harness's skills enforce planning/verification *process* (spec-gate, completion
verification, dispatch discipline); this repo's rule sets are *coding-style and architecture*
guidance (deep modules, dependency rule, DDD vocabulary) aimed at influencing how code is
written, not how the agent's workflow is governed. Orthogonal concerns — a project could use
both without conflict, but neither absorbs the other.

## Security notes

None applicable — static markdown, no executable content, no installer.

## Verdict

REJECT for harness adoption — out of scope (style/architecture guidance vs this harness's
workflow-governance focus) and, more importantly, **not actually mattpocock's content** to
credit as such; adopting it under a "mattpocock repo" umbrella would misattribute Maciej
Ciemborowicz's work. If this rule-set style is ever wanted for a *consumer* project's own
`AGENTS.md`, cite `ciembor/agent-rules-books` directly, not this fork.
