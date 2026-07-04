# Specializing agents per project

The two bundled agents are deliberately **generic** — they ship one house
style and work in any repo. To make them sharp for *your* project without
forking the agent definitions, drop optional files into a `.agent/` directory
at your repo root. Each agent reads its file (if present) and layers the
project rules **on top of** its generic behavior.

This is the portability mechanism: **one harness, specialized per repo.**

## Injection points

| File | Read by | Purpose |
|---|---|---|
| `.agent/conventions.md` | code-reviewer | Stack, layering, naming, do/don't — project idioms the reviewer should enforce. |
| `.agent/threat-model.md` | security-reviewer | The project's real attack surface (deployment model, trust boundaries, sensitive tables/endpoints, auth model). |
| `.agent/flake-list.md` | *(pattern — any custom agent you add for test upkeep)* | Quarantine log for known-flaky tests (name + reason + date). The agent appends here instead of leaving silent skips. |
| `agents/master-registry.json` | supervisor.py, session-init.py | Per-project routing overrides (keywords, file_globs, model). Copy the shipped default and edit. |

All are **optional**. With none present, the agents run their generic
behavior. Nothing here is required for the harness to work.

## Worked example — specialize `security-reviewer` for a Supabase app

A generic OWASP pass stays at textbook altitude. A `.agent/threat-model.md`
makes the same agent hunt the threats that actually matter on your stack.

`.agent/threat-model.md`:

```markdown
# Threat model — Supabase web app

## Deployment model
- Postgres behind Supabase, exposed via PostgREST + Edge Functions (Deno).
- Browser client uses the **anon** JWT; servers use the **service_role** key.

## Trust boundaries (audit these first)
1. **RLS is the only thing between the anon key and the data.** Every table
   reachable by the anon role MUST have RLS enabled AND a policy. A table with
   RLS disabled, or enabled-but-no-policy, is a full read/write hole. Flag any
   migration that creates a table without a matching policy.
2. **`service_role` bypasses RLS.** Flag any path where the service_role key
   could reach the client bundle, or where an Edge Function uses service_role
   for an operation that should run under the caller's JWT.
3. **`VITE_`-prefixed env vars ship to the browser.** Any secret behind a
   `VITE_` name is public. Only the anon key / public URLs belong there.

## Sensitive surfaces
- Edge Functions that mutate billing, auth, or other users' rows.
- Storage buckets: public vs. authenticated read, and signed-URL expiry.
- IDOR on `/rest/v1/<table>?id=eq.<n>` — confirm RLS scopes rows to the owner.

## Out of scope
- Third-party endpoints (don't run exploits against them).
```

Now `security-reviewer` checks RLS coverage, `service_role` leakage, the
`VITE_` boundary, and IDOR on PostgREST routes **in addition to** its generic
OWASP Top 10 list — without any change to the agent definition.

## Conventions and flake-list examples

`.agent/conventions.md` (read by code-reviewer):

```markdown
# Conventions
- TypeScript strict; no `any`; explicit return types on exports.
- All user-facing strings via i18n keys — no hardcoded copy.
- Components split by responsibility, not line count.
- Tests: AAA pattern; integration tests hit a real test DB (no DB mocks).
```

`.agent/flake-list.md` (example — appended by a custom test-focused agent you add):

```markdown
# Flake list
- `api/upload.test.ts > resumes large upload` — times out on slow CI runners.
  Quarantined 2026-06-15. Re-enable after the upload retry refactor.
```

## See also

- [`master-registry.md`](master-registry.md) — registry format + routing.
- [`customization.md`](customization.md) — `hook-config.yml` risk areas.
- `agents/*.md` — the generic agent definitions these files specialize.
