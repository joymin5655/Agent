---
name: airlens-ops
description: AirLens operational review skill for deployment readiness, CI/CD checks, performance regressions, bundle/resource cost analysis, and conservative dead-code cleanup. Use for pre-deploy checklists, Cloudflare/GitHub Actions issues, React/Supabase/Three.js performance review, FinOps analysis, or safe refactoring.
---

# AirLens Ops

Use this skill for AirLens operational work that needs deploy discipline, measurable performance analysis, cost awareness, or cleanup safety.

## Deployment Readiness

Verify the release path: `main` push -> GitHub Actions `deploy.yml` -> Cloudflare Pages, with branch preview deployments.

Pre-deploy checklist:

1. Run or request results for `npm run build`, `npm run lint`, and `npm run test:run`.
2. Check production code for stray `console.log` and hardcoded secrets.
3. Confirm required env vars are documented in `.env.example`.
4. Confirm architecture changes are reflected in the relevant `CLAUDE.md` or docs.
5. Include rollback steps before approving deployment.

Required GitHub secrets:

- `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`
- `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`
- `VITE_POLAR_PRODUCT_ID_EXPLORER`, `VITE_POLAR_PRODUCT_ID_RESEARCHER`
- `VITE_POSTHOG_KEY`

Never force-push or deploy when required checks are failing.

## Harness Operations

Use the repo-local harness scripts when reviewing Claude/Codex collaboration readiness:

```bash
node scripts/harness-audit.js repo --format text
node scripts/agent-catalog.js --format text
node scripts/orchestration-status.js --format text
```

Rules:

- Claude runtime files live under `AirLens-web/.claude/**`.
- Codex runtime files live under `AirLens-web/.codex/skills/**` and `/Users/joymin/.codex/skills/**`.
- Shared decisions, handoffs, and inventories live in `Obsidian-airlens/wiki/**`.
- Use `scripts/orchestrate-worktrees.js` in dry-run mode first. Only run `--execute` when the user explicitly asks for worktree creation.
- Do not activate supervisor/dispatch blocking hooks until the false-block risk and privacy policy are reviewed.

## Performance Review

Review changed files plus surrounding hooks, stores, imports, and call sites. Report only issues with measurable impact; include file path, line, severity, confidence, expected ms/bytes impact, and a concrete fix.

Targets:

- LCP < 2.5s, INP < 200ms, CLS < 0.1, TBT < 200ms
- Landing JS < 150 KB gzipped; app JS < 300 KB gzipped
- 4x CPU throttled Globe target: FCP < 3s, TTI < 5s when browser benchmarking is available

AirLens-specific checks:

- Prefer `useDataQuery.ts` for data fetching so the 5-minute module cache is used.
- Avoid repeated `loadRemoteConfig()` calls after startup.
- Route ML API calls through the `check-usage` Edge Function before execution.
- Avoid refetching persisted `airQualityStore` data when valid data already exists.
- For `GlobeView.tsx` and Three.js/R3F code, verify `geometry`, `material`, and `texture` cleanup via `.dispose()`.
- Avoid creating objects inside `useFrame`; use `InstancedMesh`/`BatchedMesh` when many meshes are rendered.
- Stabilize Context provider values with `useMemo`; prefer Zustand selectors over full-store subscriptions.
- Watch Framer Motion `layout`, `AnimatePresence`, and list animations around heavy Canvas or route remounts.

Useful searches:

```bash
rg "await.*for\\s*\\(|await.*forEach|await.*map" src
rg "\\.from\\(.*\\.select\\(" src
rg "useAuthStore\\(\\)|createContext|useContext" src
rg "new THREE\\.|useFrame|InstancedMesh|BatchedMesh" src
rg "layout[= ]|AnimatePresence|whileInView" src
rg "import .* from ['\"]lodash['\"]" src
```

When practical, run `npm run build` and inspect chunk sizes. Flag 500 KB+ JS chunks as medium severity and 1 MB+ chunks as high severity. If Playwright or a browser benchmark is unavailable, say the browser benchmark was skipped and why.

## Cost And Resource Analysis

Use quantitative data: token counts, API calls, bundle size, monthly cost, or tier limits. Include expected savings percentage for each recommendation.

Cost centers:

- Supabase database, storage, Edge Function, and auth usage.
- Cloudflare Pages builds, Workers requests, R2 storage, and bandwidth.
- External data APIs, including paid air-quality, geocoding, weather, or satellite providers.
- Frontend bundle size and unnecessary client-side model or map payloads.

Flag any new dependency expected to add more than 50 KB gzipped.

## Refactor And Cleanup

Use conservative cleanup rules:

1. Detect candidates with tools such as `knip`, `depcheck`, `ts-prune`, and ESLint unused-directive checks when available.
2. Categorize removals as safe, careful, or risky.
3. Verify every removal with `rg`, including string-based dynamic imports and public API exports.
4. Remove one category at a time, then run tests/build.
5. Do not remove code during active feature work, before a production deploy, or when coverage is insufficient.

Never delete public API, dynamically referenced files, or code you do not understand without user approval.

## Output

For reviews, lead with findings ordered by severity. If no issues are found, state that clearly and list what was checked. Include skipped verification steps and why.
