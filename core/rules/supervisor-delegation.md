# Supervisor Delegation

The supervisor classifies work before routing it.

## Classification

- intent: `QUERY`, `SIMPLE_EDIT`, `FEATURE`, `MULTI_DEPT`, `META`, `RECALL`, `LEARN`, `REVIEW/AUDIT`
- domain: `frontend`, `backend`, `database`, `security`, `testing`, `docs`, `ops`, `ml`, `general`
- risk: `LOW`, `MEDIUM`, `HIGH`

## Policy

- Advisory mode is the default.
- High-risk or multi-domain writes require plan evidence and specialist evidence.
- Strict mode may block Write/Edit/MultiEdit until the evidence exists.
- Generic exploration agents do not satisfy specialist evidence by themselves.
- Aliases in `.agent-harness/agent-registry.json` may map global agents to project specialists.
