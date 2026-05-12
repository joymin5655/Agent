# Global Claude Setup (`~/.claude/`)

User-scope Claude configuration that applies to **all projects**. Other repos override these via project-level `CLAUDE.md` per the 8-layer hierarchy.

Adopted: 2026-05-12 (internal-platform reference setup).

## 8-Layer Inheritance

Claude Code loads context in this order (later layers override earlier):

1. Global user (`~/.claude/CLAUDE.md` + imports)
2. Root project (`<repo>/CLAUDE.md`)
3. Sub-project (`<repo>/apps/web/CLAUDE.md`, etc.)
4. Skill / agent frontmatter
5. Hook injections (SessionStart, UserPromptSubmit, etc.)
6. MCP server instructions
7. System reminders
8. User message

The user-scope files in this directory sit at layer 1.

## Files

| File | Purpose |
|---|---|
| `CLAUDE.md` | Entry point. Imports `RTK.md` + `karpathy.md` via `@filename` syntax. Keep tiny (~20B). |
| `karpathy.md` | Andrej Karpathy 4 behavioral principles for LLM coding agents. Source: [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills) (MIT). |
| `RTK.md` | RTK (Rust Token Killer) CLI proxy reference. Project-agnostic — token-optimized hook wrapper. |

## Karpathy 4 Principles (Summary)

1. **Think Before Coding** — surface assumptions, ask when unclear, present tradeoffs
2. **Simplicity First** — minimum code; no speculation; no abstractions for single-use
3. **Surgical Changes** — touch only what the task requires; don't refactor adjacent code
4. **Goal-Driven Execution** — convert tasks to verifiable goals; loop until verified

Full text in `karpathy.md`. License: MIT (upstream).

## Setup on a New Machine

```bash
mkdir -p ~/.claude
cp claude/global/CLAUDE.md ~/.claude/CLAUDE.md
cp claude/global/karpathy.md ~/.claude/karpathy.md
cp claude/global/RTK.md ~/.claude/RTK.md   # optional — RTK CLI is per-user setup
```

Verify import resolution:
```bash
cat ~/.claude/CLAUDE.md   # should show: @RTK.md\n@karpathy.md
```

## Project-Level Override Pattern

Project `CLAUDE.md` should **cross-reference** Karpathy principles rather than restate them. AirLens root pattern (2026-05-12 A+ diet):

```markdown
## Agent Operating Mode

**AirLens-specific 원칙** (Karpathy 글로벌 §3 Surgical / §4 Goal-Driven 자동 상속):
1. Glass-box Output — ML 출력에 불확실성 명시
2. Context Efficiency — 작업 시작 전 정본 docs 만 읽기

## Brevity & Output Discipline

출력 토큰 절감. Karpathy 글로벌 §1 Think / §2 Simplicity 자동 상속.
```

This avoids duplication and keeps project files small.

## Upstream Sync

`karpathy.md` is upstream-tracked. If `forrestchang/andrej-karpathy-skills` updates the source, decide:
- **Mechanical update** (typo, formatting) — re-copy
- **Semantic change** (new principle, scope shift) — re-evaluate fit with project conventions before adopting

Frontmatter in `karpathy.md` records `adopted: <date>` for audit.
