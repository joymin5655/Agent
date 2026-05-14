# Memory And Context Discipline

Keep context small and durable.

## Rules

- Read only the files needed for the current decision.
- Summarize long references instead of loading unrelated sections.
- Record durable decisions in the project's chosen knowledge base path.
- Do not duplicate volatile implementation detail across multiple docs.
- Keep local logs and session state gitignored.

Default knowledge-base path is configured in `.agent-harness/config.json`.
