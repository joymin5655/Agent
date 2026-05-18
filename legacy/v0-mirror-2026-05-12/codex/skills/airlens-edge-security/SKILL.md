---
name: airlens-edge-security
description: AirLens Supabase Edge Function and security-review guidance. Use for Deno Edge Functions, API endpoints, auth/CORS, webhooks, rate limits, secret handling, or security audits for SQL injection, XSS, RLS, authz, SSRF, and exposed secrets.
---

# AirLens Edge Security

Use this skill when creating or reviewing Supabase Edge Functions, API endpoint behavior, authentication/authorization, CORS, webhooks, rate limits, external API proxies, or security-sensitive code changes.

## Edge Function Rules

- Use existing shared modules: `_shared/auth.ts` / `_shared/cors.ts` patterns before adding new helpers.
- Handle `OPTIONS` preflight and return a consistent `{ data, error }` envelope.
- Authenticate protected endpoints with `requireAuth(req, corsHeaders)` unless the route is intentionally public.
- Validate request bodies, URL params, and query params with explicit type and range checks.
- Use rate limiting or `check-usage` before expensive operations.
- Keep functions under the practical Edge timeout; offload long work to the backend pipeline.
- Log operational failures without exposing stack traces, DB schema, tokens, or PII to clients.

## Secret And Data Source Policy

- `SERVICE_ROLE_KEY` is server-only and must never appear in `src/**`, browser code, logs, responses, or `VITE_*` env vars.
- `VITE_*` variables are bundled into the client and must not contain secrets.
- Webhooks, including Polar, require HMAC/signature verification before business logic.
- Client code must not call external data APIs directly; proxy through Edge/API layers.
- WAQI and OpenAQ are `historical_frozen` sources. Do not use Edge Functions to restore live WAQI/OpenAQ active snapshot ingest.
- Active snapshots must use active sources only; frozen sources are allowed only for explicit historical/research workflows with provenance.

## Security Review Process

1. Read the full changed files and relevant shared auth/CORS/db helpers; do not review from diff snippets alone.
2. Search the repo for dangerous patterns before reporting: `SERVICE_ROLE_KEY`, `VITE_`, `dangerouslySetInnerHTML`, `innerHTML`, `eval(`, `new Function(`, `.rpc(`, raw SQL, shell execution, and committed model artifacts.
3. Trace user input from `req.json()`, params, search params, form data, or UI state into sinks such as Supabase queries, RPCs, `fetch()`, HTML rendering, shell commands, or deserialization.
4. For Edge Functions, verify unauthenticated calls fail where required and malformed input returns controlled 4xx errors.
5. For database-backed behavior, distinguish anon-client RLS from service-role bypass paths.

## Findings Standard

- Lead with confirmed vulnerabilities and evidence. Avoid speculative findings.
- Include CWE ID, severity, affected file/line, exploit path, and concrete remediation.
- Include PoC steps when practical, but never target production services.
- Classify high severity for SQL injection, XSS with attacker-controlled content, hardcoded secrets, command/code injection, auth bypass, or RLS/IDOR data exposure.
- Classify medium severity for missing input validation, weak authorization checks, unsafe SSRF-prone fetches, or sensitive logging.
- Classify low severity for excessive error detail, weak non-security hashing choices, or defense-in-depth gaps.

## Common AirLens Checks

- Edge Functions using Supabase must not leak service-role results to users outside their authorization boundary.
- Public endpoints need explicit allowlists, bounded parameters, response size limits, and cache behavior.
- `.pkl`, `.onnx`, `.pth`, and `data/artifacts/` outputs should not be committed unless the repo already treats them as approved versioned artifacts.
- Security-definer database functions must set a fixed `search_path`.
