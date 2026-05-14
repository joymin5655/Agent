# Policy Generalization

AirLens policies were classified into three groups.

## Promote To Core

Policies moved into portable core form:

- multi-agent worktree coordination
- supply-chain release-age security
- public repo and secret safety
- PR security and human merge serialization
- production resource mutex
- supervisor delegation
- plan-first clarification
- memory/context discipline
- same-name skill priority
- external plugin policy
- hook safety guards

## Generalize

Transformations applied:

- project docs path became configurable `knowledge_base_path`
- app-specific paths became configurable domains/resources
- AirLens specialist names became generic domain specialists
- runtime settings became templates instead of local settings mirrors
- supervisor routing moved into `.agent-harness/*.json`
- strict blocking became opt-in; advisory mode is default

## Preserve As Example

AirLens-specific material remains under `examples/airlens/`:

- DQSS, AOD, SDID, Globe, and air-quality data policies
- AirLens ML agents and Codex skills
- AirLens workflows and GitHub Actions mirrors
- AirLens historical architecture notes
