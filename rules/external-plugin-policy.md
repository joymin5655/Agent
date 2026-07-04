# External Plug-in Policy

How to safely adopt third-party plug-ins, skills, or agent libraries
alongside this framework.

## Decision matrix per plug-in

| Question | Answer informs |
|---|---|
| What does it auto-load (hooks, settings.json entries, MCP servers)? | Whether enforcement overlaps with `core/hooks/`. |
| Does it write to your repo automatically (CLAUDE.md updates, etc.)? | Risk of conflict with your `rules/` SOT. |
| Does it bundle its own sandbox / shell wrapper? | Risk of bypassing this framework's gates. |
| What's the license? | Compatibility with your distribution. |
| What's the namespace? | Risk of slash-command / skill-name collision. |

## Adoption checklist

1. **Test in a sandbox repo first**, not in your active codebase.
2. **Diff the plug-in's hook/skill registrations** against
   `core/hooks/` — if both register on the same matcher, decide
   priority explicitly.
3. **Pin namespaces**: same-name skills resolve in priority
   `local in-place > context-mode > superpowers > plug-in` by default
   — document deviations in your adoption log (see "Record of adoptions" below).
4. **Disable plug-in auto-edits to protected paths** (your `rules/`,
   `docs/`, `wiki/`, `core/`). If the plug-in can't be configured to
   skip these, fork or wrap it.
5. **Audit after T+7d** — what did the plug-in actually do? Trim
   anything unused.
6. **Audit after T+30d** — confirm or revoke the adoption decision
   based on real-usage data, not initial enthusiasm.

## Conflict patterns to watch for

| Pattern | Mitigation |
|---|---|
| Plug-in auto-edits your CLAUDE.md / AGENTS.md | Add `protected_paths` to plug-in config (if supported) or disable that feature. |
| Plug-in registers a global hook on the same matcher as a core hook | Choose one; the other is a no-op via path guard. |
| Plug-in sandbox bypasses your shell wrapper | The framework's `context-mode-guard.sh`-style hook is the reference pattern — adapt it to the plug-in. |
| Plug-in's secret-scanning is weaker than yours | Run both; the strictest result wins. |
| Plug-in commits to your repo without PR | Disable auto-commit; route through your normal PR flow. |

## Record of adoptions

Keep a table (e.g. a new file under `rules/policy/`) with one row
per plug-in: install date, scope (global / project), conflicts found,
T+30d verdict (keep / remove / replace).
