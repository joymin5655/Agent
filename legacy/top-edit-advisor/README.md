# Legacy: top-edit-advisor (retired 2026-10)

`top-edit-advisor.py` was a PostToolUse advisory that repeated a `systemMessage` every +15
direct Write/Edit calls made by the session's top-tier model. It never blocked.

Why retired (2026-10-20): it was retired in the maintainer's own setup first, the advisory repeated at
+15 direct edits and was routinely ignored, and enforcement belongs in the dispatch-time
observers and `/supervise`, so a per-edit PostToolUse spawn bought no decision. Zero firings
were never measured (sink `-`), so this is a judgement, not a DEAD verdict.

It is retired from the active path: `hooks/hooks.json` and
`adapters/claude-code/settings.json.template` no longer register it, `docs/gate-registry.md`
no longer lists it, and it no longer counts toward `core/hooks/`. The routing convention it
reminded about still lives in `docs/model-routing.md` and `skills/supervise/SKILL.md`; the
two observers (`model-routing-advisor.py`, `model-routing-observer.py`) stay wired.

The script and its test are kept for reference. To bring it back, move both files into
`core/hooks/` and `core/tests/`, restore the two hooks.json/template registrations
(PostToolUse `Write|Edit` and `NotebookEdit`) and the gate-registry line.
