# AI Adapters

How the framework supports Claude Code, Codex CLI, and Gemini CLI through a single canonical hook protocol.

---

## Adapter overview

Each adapter lives at `adapters/<ai-name>/` and consists of:

```
adapters/<ai-name>/
├── adapter.sh              # main bridge (reads native event, calls core hook)
├── adapter.py              # event subscriber daemon (if AI lacks shell hooks)
├── <ai>-settings.template  # config file showing user how to register hooks
├── <ai>-instructions.template  # AGENTS.md / GEMINI.md / CLAUDE.md project template
├── README.md               # AI-specific notes
└── tests/
    └── run.sh              # adapter smoke tests
```

The adapter's contract:
- Input (from AI runtime): native event format
- Output (to AI runtime): native decision/enforcement
- Internal: canonical JSON to/from `core/hooks/*`

---

## Claude Code adapter

**Native event format**: stdin JSON, matches canonical schema almost 1:1.

**Hook registration**: `~/.claude/settings.json` (or `<project>/.claude/settings.local.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "<agent-root>/adapters/claude-code/adapter.sh pre-tool-guard" }
        ]
      }
    ]
  }
}
```

**Decision enforcement**: Claude Code reads stdout JSON directly. Decision values: `allow` / `deny` / `ask`. Exit code 2 is a deny shortcut.

**Adapter implementation**: thin pass-through. Add `"ai": "claude-code"` to event JSON, forward to core hook, return stdout as-is.

**Limitations**:
- All 5 event categories supported
- Hook timeout: 60 seconds default
- Matchers support glob: `Bash|Write|Edit`, `mcp__*`, `*`

See `adapters/claude-code/README.md` for the full Claude Code-specific quirks.

---

## Codex CLI adapter

**Native event format**: TBD — research during Phase 5 of framework build. Codex CLI (https://github.com/openai/codex) is OpenAI's official CLI tool.

**Hook registration**: typically `~/.codex/config.toml` or per-skill hook block.

**Expected adapter approach**:
1. Codex CLI fires a hook callback (shell command or Python subscriber).
2. Adapter receives native event, constructs canonical JSON.
3. Pipes to core hook.
4. Translates decision back to Codex's enforcement (typically tool-cancel command or user-prompt directive).

**Adapter file**: `adapters/codex/adapter.sh` (and `adapter.py` if subscriber daemon needed).

**Codex-specific notes**:
- AGENTS.md is the canonical project instructions file (Codex auto-loads it).
- Skills live at `~/.codex/skills/<name>/` with a different format than Claude SKILL.md.
- See `adapters/codex/codex-config.toml.template` for registration.

---

## Gemini CLI adapter

**Native event format**: TBD — research during Phase 5. Gemini CLI is Google's official CLI tool.

**Hook registration**: typically `~/.gemini/settings.json` with a hooks block.

**Expected adapter approach**: similar to Codex — receive native event, translate to canonical JSON, pipe to core hook, translate decision back.

**Adapter file**: `adapters/gemini/adapter.sh`.

**Gemini-specific notes**:
- GEMINI.md is the project instructions file.
- Skill activation uses `activate_skill` tool — different from Claude's slash-command invocation.

---

## Cross-AI parity guarantee

A test in `core/tests/adapter-parity.sh` verifies: given a logically identical input event, all 3 adapters produce identical decision JSON.

Example: `PreToolUse` with `Bash` tool and command `cat secrets/db.env` MUST return `permissionDecision="deny"` from all 3.

If you add a feature to one adapter that breaks parity, fix the other two before merging.

---

## Adding a new AI adapter

1. Create `adapters/<ai-name>/` per the structure above.
2. Implement `adapter.sh` translating native ↔ canonical (see `docs/hook-protocol.md` § 9).
3. Provide `<ai>-settings.template`.
4. Provide `<ai>-instructions.template` for project scaffolding.
5. Write `tests/run.sh` with minimum: Bash safe / Bash unsafe / Write to .env.
6. Add the AI to the `core/tests/adapter-parity.sh` matrix.
7. Update `setup.sh` to support `--<ai-name>` mode.
8. Update root `README.md` and this doc.

The bar for a new adapter: same hook protocol contract, same decision semantics, same security guarantees as existing 3.

---

## Adapter quality matrix

| Concern | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|
| Stdin JSON native | ✅ direct | adapter translates | adapter translates |
| Stdout JSON decision | ✅ direct | adapter translates | adapter translates |
| All 5 event categories | ✅ | TBD | TBD |
| Hook chain ordering | ✅ via settings.json | TBD | TBD |
| Project instructions file | CLAUDE.md | AGENTS.md | GEMINI.md |
| Skill format | `.claude/skills/<name>/SKILL.md` | `~/.codex/skills/<name>/` | `~/.gemini/skills/<name>/` |
| Slash commands | ✅ `/<name>` | command-equivalent | command-equivalent |

---

## When AI runtimes disagree

If Codex CLI has no `PostToolUse` equivalent, the adapter:
- Returns success for PostToolUse calls from `core/hooks/`
- Logs a warning that PostToolUse observation isn't supported on that AI
- Doesn't break parity for events that ARE supported

The framework prefers graceful degradation over feature-uniformity. Risk areas (`PreToolUse` denies) MUST work on all 3 — observation features MAY differ.
