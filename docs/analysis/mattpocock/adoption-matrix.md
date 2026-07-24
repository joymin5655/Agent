# mattpocock repos — adoption matrix

Default verdict is **REJECT**; every ADOPT/DEFER row below carries a named, specific
justification per Rule 11 (no bulk import). Full per-repo detail is in the sibling dossiers
(`skills.md`, `sandcastle.md`, `evalite.md`, `dictionary-of-ai-coding.md`,
`agent-rules-books.md`, `slopwatch.md`, `ai-hero-cli.md`, `mise-en-place.md`,
`ai-sdk-tips.md`).

**Curation note**: all 9 named repos were kept (none dropped as too trivial to write up) —
even the REJECT-verdict repos (`ai-hero-cli`, `mise-en-place`, `ai-sdk-tips`) got a full dossier
because confirming *why* they don't overlap (course tooling / personal ops / stale tutorial)
required reading them first; curation shows up as verdict, not omission.

**Authorship flag**: `agent-rules-books` is a fork of `ciembor/agent-rules-books`
(`gh api` confirms `fork: true`, `parent: ciembor/agent-rules-books`; LICENSE and the only
visible commit are attributed to Maciej Ciemborowicz) — it is in mattpocock's namespace but
not his authored work. See its dossier for detail.

**OpenKnowledge precedent check**: applied to all 9 repos (the specific check this project used
to reject OpenKnowledge v0.28.1's unconsented **install-time** `~/.claude` writes via
`postinstall`). Result: **zero `postinstall` scripts found across all 9 repos**
(`grep -rl postinstall --include=package.json` run against every clone, zero hits) — no
install-time trust concern anywhere in this batch. This does NOT mean no repo touches
`~/.claude` at all: `sandcastle` writes there at **runtime**, by default, as a documented
session-capture/resume feature, not an install-time surprise — see `sandcastle.md`'s
Install/distribution section for the source citations (`SessionStore.ts`, `AgentProvider.ts`,
`README.md:891`). Applying the same evidence standard in both directions: a claim of "doesn't
touch X" is only made here where the source was actually read and confirmed absent, not
assumed from an install command's simplicity.

---

## Table 1 — Repo-level verdicts

| item | what it is | overlap with existing | verdict | justification | absorption channel |
|---|---|---|---|---|---|
| `mattpocock/skills` | 22-skill Agent-Skills plugin for planning/TDD/review/domain-modeling | High category overlap (planning-discipline skills), low mechanism overlap (prompt-only, no enforcement layer vs this harness's hook/CI-gated design) | See Table 2 — per-skill verdicts, not one repo-level verdict | Mixed: most skills REJECT (redundant with installed tooling or out of harness scope), 2 productivity skills (`grill-me`/`grilling`) are ADOPT-tool, 1 (`wayfinder`) is ADOPT-pattern | mixed, see Table 2 |
| `mattpocock/sandcastle` | TS lib/CLI: container-sandboxed AI agent orchestration (Docker/Podman/Vercel) | None — this harness has no container-sandboxing layer; conceptually adjacent to `.worktrees/` git-level isolation this harness already uses | DEFER | Real, mature tool (7k stars, active) solving a problem (untrusted/AFK agent execution isolation) this harness's single-trusted-developer-machine threat model hasn't hit; revisit only if `/supervise --goal-mode` autonomy scope grows to run untrusted code | clone-reference (already cloned to `_repos/reference/`) |
| `mattpocock/evalite` | TS/Vitest eval framework for LLM apps, SQLite run-history + UI | Strong conceptual overlap with `evals/run-evals.py` + judges + baseline; near-zero implementation overlap (Python-stdlib-only by design) | DEFER (pattern-only, no TS runtime) | Comparison confirms this repo's `evals/` already independently converged on the load-bearing ideas (separated data/task/score hooks, repeated-trial rigor, CI-gating baseline) evalite also uses; a TS runtime dependency is explicitly not recommended for a Python-stdlib harness | clone-reference (pattern lens only) |
| `mattpocock/dictionary-of-ai-coding` | Static AI-coding vocabulary glossary (published web content) | None structural; thematic only (defines terms this harness's docs use undefined — effort, harness, compaction) | REJECT | Not a tool or agent behavior — reference content for a human reader; brain-note ingestion is out of scope for this wave (2_BRAIN distillation is `/brain-ingest`'s job, not this wave's) | brain-note (deferred to future `/brain-ingest`, not executed here) |
| `mattpocock/agent-rules-books` | Book-derived (Clean Code, DDD, etc.) AGENTS.md rule sets, 3-tier compression | None — style/architecture guidance vs this harness's workflow-governance focus; also **not actually mattpocock's authored content** (fork of ciembor/agent-rules-books) | REJECT | Out of scope, and crediting it as "a mattpocock repo" would misattribute Maciej Ciemborowicz's work | none — if ever wanted for a consumer project's own `AGENTS.md`, cite `ciembor/agent-rules-books` directly |
| `mattpocock/slopwatch` | Self-hosted coding-agent observability platform (Postgres, per-agent Listeners) | Conceptually adjacent to the open M-8 backlog item (cost/telemetry instrumentation); zero implementation overlap | DEFER | Core Claude Code listener is an unimplemented 4-line stub — nothing working to adopt; revisit only if the listener ships and M-8 becomes active work | none currently — re-scan if slopwatch ships a working listener |
| `mattpocock/ai-hero-cli` | CLI for navigating "AI Hero" paid-course exercises | None — course-delivery tooling, different problem domain | REJECT | No overlap with engineering-workflow governance; a student-facing course tool | none |
| `mattpocock/mise-en-place` | Personal ops scripts (invoices, X/Twitter bot, Todoist) | None; notable only as a real-world consumer of `sandcastle` (confirms sandcastle is used in anger by its own author) | REJECT | Personal business tooling, no engineering-pattern content | none |
| `mattpocock/ai-sdk-tips` | AI SDK v5 tutorial companion/exercises (GPL-2, 9mo stale) | None beyond what `ai-hero-cli`/`evalite` dossiers already cover (this repo merely depends on both) | REJECT | Course/tutorial content, stale, no pattern distinct from repos already covered in this batch | none |

## Table 2 — `mattpocock/skills`, per-skill vs this harness's 8 shipped skills

This harness ships 8 skills: `spec`, `supervise`, `verify-completion`, `wrap`, `brain-ingest`,
`harness-audit`, `manager-audit`, `harness-help`. mattpocock/skills ships 22 in its installable
plugin bundle (`engineering/` ×17, `productivity/` ×5 — `misc/`, `personal/`, `deprecated/`,
`in-progress/` are excluded from `.claude-plugin/plugin.json`'s `skills` array and not
evaluated as installable candidates).

| skill | what it is | overlap with existing | verdict | justification | channel |
|---|---|---|---|---|---|
| `ask-matt` | Router over mattpocock's own skill set | Duplicate function of this harness's `harness-help` | REJECT | Already have a router skill for this harness's own 8 skills; installing a second router for a different skill set adds confusion, not value | none |
| `diagnosing-bugs` | Debugging/diagnosis loop for hard bugs | Duplicate of the globally-installed `investigate` skill (gstack plugin — "Systematic debugging... Iron Law: no fixes without root cause") | REJECT | Functionally redundant with an already-installed, actively-used skill | none |
| `grill-with-docs` | Relentless interview that also produces ADR/glossary docs as it goes | Partial overlap with `/spec --interview` (F-1, this harness's structured-interview mechanism) | DEFER | The interview mechanism itself is already covered by `/spec --interview`; ADR/glossary artifact generation is domain-modeling territory outside this harness's planning+verification charter | none this wave |
| `triage` | Issue/PR triage state machine over an issue tracker | None | REJECT | Out of scope — this harness has no issue-tracker integration | none |
| `improve-codebase-architecture` | Scan codebase for "deepening opportunities," HTML report + grill | None | REJECT | Out of scope — architecture-scanning tool, not workflow governance | none |
| `setup-matt-pocock-skills` | Per-repo bootstrap: issue tracker + triage labels + domain-doc layout | Duplicate function of `agent-harness:project-init` | REJECT | Already have a project-scaffolding skill; two competing bootstrap skills would conflict | none |
| `tdd` | Test-driven development workflow (red-green-refactor) | No dedicated TDD skill exists among this harness's 8 (though karpathy.md's global principles already state the same philosophy) | DEFER | Genuine gap (no operational TDD skill), but adding one is a scope decision for a future wave/backlog item, not a default action this wave — flagging rather than silently rejecting since the justification for NOT adopting is weaker than for the clear-duplicate rows above | backlog note for future wave |
| `to-spec` | Turn conversation into spec, publish directly to issue tracker (no interview) | Functional overlap with this harness's `spec` skill (spec.md/plan.md creation) | REJECT | Core function already covered; the issue-tracker-publishing step has no equivalent in this harness because there's no issue-tracker integration at all | none |
| `to-tickets` | Break plan into tracer-bullet tickets with blocking edges, published to tracker | Loose overlap with `supervise`'s wave decomposition, but targets an external issue tracker | REJECT | Out of scope — no issue-tracker integration exists to publish tickets to | none |
| `wayfinder` | Plan huge multi-session work as a shared map of decision tickets with claim/blocked-by/frontier-query state machine | Same problem `/supervise --goal-mode`'s SQLite state already solves (resumable multi-wave campaigns) | **ADOPT-pattern** | wayfinder's explicit claim → blocked-by → frontier-query (first unblocked+unclaimed ticket wins) state machine formalizes exactly the resumability problem `supervisor-goal.sh` solves ad hoc; the frontier-query algorithm is a citable, well-named pattern worth referencing the next time `supervisor-goal.sh`'s wave-selection logic is revised | pattern→harness (backlog note for `core/infra/supervisor-goal.sh`, not a code change this wave) |
| `implement` | Implement work from a spec/tickets | Implicit in `supervise`'s wave dispatch | REJECT | No gap — implementation dispatch already happens through wave delegation contracts | none |
| `prototype` | Build a throwaway prototype to answer a design question | None | REJECT | Out of scope for this harness's charter | none |
| `research` | Investigate a question, save findings as markdown | Ad hoc already covered by `Explore`/`general-purpose` agents | REJECT | No gap — generic research delegation already available without a dedicated skill | none |
| `domain-modeling` | Build/sharpen a project's domain model, ADR docs | None | REJECT | Out of scope — this harness governs workflow, not domain architecture | none |
| `codebase-design` | Shared vocabulary for designing deep modules | None | REJECT | Out of scope | none |
| `code-review` | Two-axis (Standards + Spec-match) parallel review, reported side by side | Partial overlap with `code-reviewer` + `verify-completion` (which independently checks spec-match) | DEFER | Interesting two-axis-parallel-review structure, but not clearly superior enough to the existing reviewer + independent verifier split to justify a reviewer-agent redesign in this wave | backlog note for future reviewer-agent revision |
| `resolving-merge-conflicts` | Resolve in-progress git merge/rebase conflicts | **Exact-name duplicate of an already-installed global skill** (`resolving-merge-conflicts`, gstack plugin, visible in this session's own available-skills list with a near-identical description) | REJECT | Already installed and active; adopting mattpocock's version would create a naming collision with zero functional gain | none |
| `grill-me` | Manual, on-demand relentless interview to sharpen a plan/design | **Named dependency gap**: this user's own global `~/.claude/CLAUDE.md` explicitly routes "코드베이스 없는 아이디어 구체화는 `/grill-me`" — but no skill named `grill-me` exists anywhere in this session's available-skills list. The user's documented workflow already assumes this skill exists and it doesn't. | **ADOPT-tool** | Closes a real, already-referenced gap (not a speculative import) — the global CLAUDE.md names this exact command as the designated route for codebase-free idea grilling, and mattpocock/skills ships precisely that skill under `productivity/grill-me` | tool-install — recommend `npx skills@latest add mattpocock/skills` and selectively pick only `grill-me` (+`grilling`, same family) rather than the full plugin bundle, to avoid importing the other 20 skills wholesale (Rule 11) |
| `grilling` | Auto-triggerable relentless-interview skill (triggers on "grill" phrases), same family as `grill-me` | Same gap as `grill-me` — the auto-invoke variant of the same missing capability | **ADOPT-tool** | Bundled with `grill-me` (same underlying gap, same source skill family) — install together via the same selective `skills.sh` pick | tool-install, same channel as `grill-me` |
| `handoff` | Compact conversation into a handoff doc for another agent | Duplicate of the already-installed `context-save`/`context-restore` skills (gstack plugin) | REJECT | Functionally redundant with already-installed, actively-used session-continuity skills | none |
| `teach` | Teach the user a new skill/concept within the workspace | None specific | REJECT | No clear gap — general-purpose explanation already covers this without a dedicated skill | none |
| `writing-great-skills` | Reference for writing/editing skills well | Duplicate of the already-installed `skill-creator` plugin (broader: also runs evals/benchmarks) | REJECT | Redundant with already-installed, more capable tooling | none |

### Table 2 verdict counts (recounted row-by-row)

REJECT ×16: `ask-matt`, `diagnosing-bugs`, `triage`, `improve-codebase-architecture`,
`setup-matt-pocock-skills`, `to-spec`, `to-tickets`, `implement`, `prototype`, `research`,
`domain-modeling`, `codebase-design`, `resolving-merge-conflicts`, `handoff`, `teach`,
`writing-great-skills`.
DEFER ×3: `grill-with-docs`, `tdd`, `code-review`.
ADOPT-pattern ×1: `wayfinder`.
ADOPT-tool ×2: `grill-me`, `grilling`.

16 + 3 + 1 + 2 = **22 rows, 22 verdicts, 0 unverdicted.**

## Overall verdict counts (Table 1's 8 non-`skills` repo rows + Table 2's 22 skill rows = 30
verdict-bearing rows total; the `skills` repo's own Table 1 row is a pointer to Table 2, not an
independent 31st verdict, and is excluded from this sum)

Table 1 (8 repos): REJECT ×5 (`dictionary-of-ai-coding`, `agent-rules-books`, `ai-hero-cli`,
`mise-en-place`, `ai-sdk-tips`), DEFER ×3 (`sandcastle`, `evalite`, `slopwatch`), ADOPT ×0.
5 + 3 + 0 = 8. ✓

Table 2 (22 skills): REJECT ×16, DEFER ×3, ADOPT-pattern ×1, ADOPT-tool ×2.
16 + 3 + 1 + 2 = 22. ✓

**Combined: REJECT 21 (5+16), DEFER 6 (3+3), ADOPT-pattern 1, ADOPT-tool 2.**
21 + 6 + 1 + 2 = **30 — matches the 8+22 row total exactly, 0 unverdicted.**
