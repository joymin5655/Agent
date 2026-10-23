# Legacy: top-edit-advisor (retired 2026-10)

`top-edit-advisor.py` was a PostToolUse advisory that repeated a `systemMessage` every +15
direct Write/Edit calls made by the session's top-tier model. It never blocked.

Why retired (2026-10-20): it was retired in the maintainer's own setup first, the advisory repeated at
+15 direct edits and was routinely ignored, and enforcement belongs in the dispatch-time
observers and `/supervise`, so a per-edit PostToolUse spawn bought no decision. Zero firings
were never measured (sink `-`), so this is a judgement, not a DEAD verdict.

Correction (2026-10-23): the advisory never reached the model, so "routinely ignored" was never
a finding about the model. Its only output was `systemMessage`, which the Claude Code hooks
reference defines as a "Warning message shown to the user"; the session transcript records the
hook result with empty model-facing content. Output meant to change what the model does belongs in
`hookSpecificOutput.additionalContext`, which Claude Code inserts into the model's context next to
the tool result. The maintainer's own setup now uses a once-per-turn PostToolUse nudge instead,
returning `additionalContext` at the 10th direct edit.

It is retired from the active path: `hooks/hooks.json` and
`adapters/claude-code/settings.json.template` no longer register it, `docs/gate-registry.md`
no longer lists it, and it no longer counts toward `core/hooks/`. The routing convention it
reminded about still lives in `docs/model-routing.md` and `skills/supervise/SKILL.md`; the
two observers (`model-routing-advisor.py`, `model-routing-observer.py`) stay wired.

The script and its test are kept for reference. To bring it back, move both files into
`core/hooks/` and `core/tests/`, restore the two hooks.json/template registrations
(PostToolUse `Write|Edit` and `NotebookEdit`) and the gate-registry line, and switch its output
from `systemMessage` to `hookSpecificOutput.additionalContext` so the model receives it.
