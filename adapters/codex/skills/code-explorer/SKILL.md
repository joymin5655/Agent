---
name: code-explorer
description: Read-only codebase exploration for locating features, tracing execution paths, mapping dependencies, and gathering implementation context before planning or coding.
---

# Code Explorer

Use this skill when the task is to understand existing code, find where behavior lives, trace a feature, or gather architecture context before implementation. Keep the work read-only unless the user explicitly asks for edits after exploration.

## Workflow

1. Start from the user-facing action, route, command, job, API endpoint, or external trigger.
2. Locate entry points with fast search (`rg`, `rg --files`) and read the nearest owning files.
3. Trace the call chain from entry to completion, including async boundaries, branching logic, data transformations, and error paths.
4. Map architecture layers touched by the flow: UI, state, API, service, persistence, jobs, external services, and shared utilities.
5. Identify existing patterns, naming conventions, reusable helpers, and boundaries the implementation should respect.
6. Document external packages/services and internal module dependencies that matter for future changes.

## Exploration Rules

- Do not create investigation files or edit source files during exploration.
- Prefer exact file paths, function names, table names, routes, and line references over broad summaries.
- Read surrounding code before making architectural claims.
- Distinguish confirmed behavior from inference.
- Keep snippets short; quote only the lines needed to anchor a finding.
- If the task is likely to become implementation work, end with concrete guidance that a planner or implementer can act on.

## What to Look For

- Entry points: routes, components, event handlers, commands, scheduled jobs, webhooks, RPCs.
- Execution flow: caller/callee chain, state transitions, validation, side effects, failure handling.
- Data flow: request/response shapes, database queries, mutations, serialization, caching.
- Architecture: layer boundaries, dependency direction, shared abstractions, anti-patterns.
- Dependencies: external libraries/services and internal modules/utilities worth reusing.
- Test surface: existing unit, integration, or E2E tests that describe the behavior.

## Output Shape

Use this format when reporting a substantial exploration:

```markdown
## Exploration: [Feature or Area]

### Entry Points
- `[path:line]`: how it is triggered

### Execution Flow
1. `[path:line]` does ...
2. `[path:line]` calls ...

### Architecture Notes
- Confirmed pattern or boundary, with file references.

### Key Files
| File | Role | Importance |
| --- | --- | --- |

### Dependencies
- External: ...
- Internal: ...

### Implementation Guidance
- Follow ...
- Reuse ...
- Avoid ...

### Open Questions
- ...
```

For simple location-finding tasks, answer more briefly with paths, line numbers, and a short dependency summary.

## Good Fit

Use for:

- "where is this implemented?"
- "trace this feature"
- "explain this flow"
- "find similar patterns before coding"
- pre-planning architecture discovery

## Bad Fit

Do not use for:

- reviewing a completed diff; use `code-reviewer`
- producing an implementation plan; use `planner`
- making direct code edits without an exploration request
