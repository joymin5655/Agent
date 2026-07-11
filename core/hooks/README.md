# core/hooks/

AI-agnostic hook implementations. Each script reads a canonical event JSON from `stdin` and writes a canonical decision JSON to `stdout` (or empty stdout for `allow`). See [`../../docs/hook-protocol.md`](../../docs/hook-protocol.md) for the contract.

## Ported in v0.1.0 (this release)

| Hook | Event | Purpose |
|---|---|---|
| `pre-tool-guard.sh` | PreToolUse (Bash) | Bash command safety — destructive deletion, force push, secrets/.env access, DROP/TRUNCATE TABLE |
| `secret-content-scan.py` | PreToolUse (Write/Edit/MultiEdit + MCP write tools) | Secret bypass patterns in file content + MCP URL/query/content payloads |
| `r4-mutex-check.sh` | PreToolUse (`*`) | Resource mutex — production-db, edge-function-deploy, production-deploy |
| `r4-file-mutex-check.sh` | PreToolUse (Write/Edit/MultiEdit) | File-level mutex when another session is editing the same path |
| `r4-file-mutex-register.sh` | SessionStart (`baseline`) + PostToolUse Bash (`commit`) | Register worktree-commit-changed files in lock file |
| `agent-session-start.sh` | SessionStart | Register session + GC stale entries + broadcast started + emit dashboard context |
| `agent-session-heartbeat.sh` | UserPromptSubmit + PostToolUse | Heartbeat the active session to keep it fresh |
| `context-mode-guard.sh` | PreToolUse (`*`) | Block Context-Mode plugin sandbox bypass of R4 / secrets |
| `tdd-guard.py` | PreToolUse (Write/Edit) | Block new prod code unless a failing test exists in the same area |
| `spec-gate.py` | PreToolUse (Write/Edit/MultiEdit) | Gate substantive impl edits when no plan is approved this session — `ask` unless the plan-approval flag exists (written by `plan-gate.py`). Escape: `/spec` writes spec.md+plan.md then approve via ExitPlanMode, or `AGENT_SPEC_GATE_MODE=off`; modes off/dryrun/block (default dryrun) |
| `plan-scope-allow.py` | PreToolUse (Write/Edit/MultiEdit, last in chain) | Auto-allow accelerator — once a plan is approved this session, in-workspace non-risk edits skip the native permission prompt. Emits only `allow` or nothing (never deny/ask); risk areas, `.agent/hook-config.yml`, `.git/`, and out-of-workspace paths always pass through. Env-gated: `AGENT_PLAN_ALLOW_MODE=on` (default off) |
| `circuit-breaker.py` | PostToolUse (Bash) | Detect repeated Bash failures + advise strategy change |
| `check-hardcoding.py` | PreToolUse (Write/Edit) | Detect hardcoded color arrays / gradients / UI metadata |
| `session-init.py` | SessionStart | Surface project agent inventory + cleanup per-session flags |
| `session-close.sh` | Stop | Session cleanup + broadcast done + optional macOS notification |
| `plan-gate.py` | PostToolUse (Agent + ExitPlanMode) | Set plan-approval flag after plan-class agent or ExitPlanMode |
| `supervisor.py` | UserPromptSubmit + PreToolUse (Write/Edit/MultiEdit) + PostToolUse (Task/Agent) | v0.2 minimal dispatcher — records a registry-keyword intent, `ask`s on the next edit (once), resolves on specialist dispatch; independent security file-glob matcher; ghost→executor fallback; `AGENT_SUPERVISOR_MODE=observe` downgrades to stderr |

## Roadmap — v0.2.0 ports

The following hooks exist in the prior project but are deferred because they require either:
- Significant rewrite to be project-agnostic
- A canonical schema that hasn't been generalized yet
- External plugin dependencies

| Deferred hook | Reason | Equivalent v0.1.0 substitute |
|---|---|---|
| `supervisor.py` (54KB original) | Full registry-aware orchestrator — intent classifier + multi-dept fan-out | v0.2 minimal dispatcher shipped (keyword intent + `ask` + dispatch-resolve + security glob); the full 54KB orchestrator remains deferred |
| `memory-explore-verify.py` | Needs `_memory_drift_patterns.py` catalog rewrite | Manual code-review for memory writes |
| `policy-drift-watch.py` | Path-list specific to source project | None — projects implement their own drift watch via `hook-config.yml: memory_protected_paths` |
| `claude-mem-watch.py` | Tied to Claude-Mem plug-in (third-party) | None — Claude-Mem users can install the plug-in's own hook |
| `wiki-*` hooks (5) | Tied to source project wiki layout | None — projects bring their own wiki conventions |
| `domain-uncertainty-check.py` | Domain-output uncertainty enforcement | Define via `hook-config.yml: risk_areas[id=domain-output]` |
| `rate-limit-check.py` | Project-specific Edge Function inventory | Project implements rate-limit check |
| `fk-type-precheck.py` | Project DB FK type drift | Project DB-specific |
| `route-change-guard.py` | Project router path list | Project routing-specific |
| `record-*` hooks (4) | Project telemetry — easy to adapt | Generic broadcast via `agent-session.sh broadcast` |
| `classify-prompt.py` | Plan-tier classifier — generic but config-coupled | Manual tier classification by user |
| `broadcast-on-bash.py` | Auto-broadcast Bash decisions to work-feed | Manual `agent-session.sh broadcast` calls |
| `token-budget-track.py` | Token usage telemetry | None — AI runtimes typically expose this natively |
| `admin-merge-track.py` | PR admin-merge evidence sink | None — use `gh pr view` for audit |
| `supervisor-goal-*.py` (3) | Goal-mode TUI / heartbeat / budget | None — manual goal tracking |

## Adding your own hook

1. Write a reproduce test in `core/tests/<hook-name>-test.sh` (must fail before you implement).
2. Implement the hook script following the canonical protocol.
3. Register it in the relevant adapter's `settings.template` under the right matcher.
4. Run adapter parity smoke test: `bash core/tests/adapter-parity.sh`.
5. Add the row to this README.

## Pass-through hooks

The default for many of these hooks is pass-through (no decision needed). The protocol contract: **empty stdout = allow**. Do NOT write `null`, `{}`, or the raw input — some AI runtimes will fail validation.

```python
# correct
sys.exit(0)

# WRONG — produces validation errors
print("null")
print(json.dumps({}))
```

See `docs/hook-protocol.md` § 3 for the full contract.
