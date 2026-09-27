# Hook Protocol — Canonical

The hook protocol is the single contract that makes the framework AI-agnostic. Every
`core/hooks/*` script reads JSON from `stdin` and writes JSON to `stdout`. Each adapter
translates a native hook event or controlled-wrapper event to/from this canonical JSON.

If you write a new core hook OR a new AI adapter: this is the doc.

---

## 1. Event categories

The framework defines five portable event categories. They are a stable subset of the
larger lifecycle surfaces exposed by current runtimes:

| Category | Fires when | Decision possible? |
|---|---|---|
| `PreToolUse` | Before a tool runs (Bash, Write, Edit, MCP call, etc.) | Yes — `allow` / `deny` / `ask` |
| `PostToolUse` | After a tool returns | No — observation only |
| `SessionStart` | Session begins | No — observation / setup |
| `Stop` | Session ends / model done | No — observation / cleanup |
| `UserPromptSubmit` | User submits a message | Yes — `allow` / `block` |

A runtime distribution may lack an exact equivalent or Agent may not yet wire the
upstream event. See [`ai-adapters.md`](ai-adapters.md) for current mappings and
explicit degradation rules.

---

## 2. Canonical `stdin` event JSON

Every hook reads this on `stdin`:

```json
{
  "ai": "claude-code | codex | gemini",
  "session_id": "<unique session id>",
  "event": "PreToolUse | PostToolUse | SessionStart | Stop | UserPromptSubmit",
  "tool_name": "<tool identifier, e.g. Bash, Write, Edit, mcp__supabase__execute_sql>",
  "tool_input": { "...": "..." },
  "tool_response": { "...": "..." },
  "cwd": "<absolute path to working dir>",
  "transcript_path": "<absolute path to session transcript>",
  "matched_agents": ["<agent ids relevant to this event>"],
  "user_prompt": "<original user prompt — only on UserPromptSubmit>"
}
```

**Required fields per event:**

| Field | PreToolUse | PostToolUse | SessionStart | Stop | UserPromptSubmit |
|---|---|---|---|---|---|
| `ai` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `session_id` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `event` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `tool_name` | ✅ | ✅ | — | — | — |
| `tool_input` | ✅ | ✅ | — | — | — |
| `tool_response` | — | ✅ | — | — | — |
| `cwd` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `transcript_path` | optional | optional | optional | optional | optional |
| `user_prompt` | — | — | — | — | ✅ |

---

## 3. Canonical `stdout` decision JSON

For events that allow decisions (`PreToolUse`, `UserPromptSubmit`), the hook writes:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow | deny | ask",
    "permissionDecisionReason": "<human-readable reason for decision>"
  }
}
```

For observation-only events (`PostToolUse`, `SessionStart`, `Stop`) or pass-through cases, the hook writes empty `stdout` (zero bytes) — equivalent to `allow`.

**Decision semantics:**

- `allow` — proceed silently. Reason ignored.
- `deny` — block the tool. Reason shown to user (and AI).
- `ask` — prompt user before proceeding. Reason shown.

**Critical rule** — for pass-through hooks (most observation hooks): **write zero bytes to stdout**. Do NOT write `null`, `{}`, or `print(raw_input)`. Some AI runtimes interpret any stdout as a decision JSON and will fail validation.

---

## 4. Exit codes

Independent of stdout JSON, exit codes follow this convention:

| Exit code | Meaning |
|---|---|
| `0` | Hook ran successfully (decision in stdout, or empty for pass-through) |
| `1` | Hook errored — current shipped behavior is **fail-open in every adapter**: the Claude adapter silently passes when a named core hook is missing or crashes, and the Codex/Gemini shell wraps discard a crashed hook's output (`2>/dev/null \|\| true`) and fall through to executing the command. This favors session availability over enforcement; a fail-closed option is part of the XRH-02 native-path acceptance criteria (`cross-runtime-harness-design.md` § 11) |
| `2` | Hook explicit DENY — runtime should block (Claude Code shorthand; equivalent to JSON `deny`) |
| `15` | Project risk area trip — secret leak detected (auto-ship convention) |
| `12-16` | Risk-area-specific abort codes — configurable in `hook-config.yml` |

Exit code `2` is a Claude Code shorthand. The canonical way is JSON `permissionDecision="deny"` — both must produce identical user-facing behavior.

---

## 5. Stderr conventions

- `stderr` is for **human-readable warnings and advice**, never decisions.
- AI runtimes display stderr to the user but don't parse it.
- Use stderr for:
  - Advisory warnings (deprecation notices, drift alerts)
  - Debug output during development
  - "Approaching limit" notifications (e.g., 80% of token budget)

Hooks that produce stderr but exit 0 are still treated as `allow`.

---

## 6. Tool input shapes (`tool_input` field)

The `tool_input` field varies by `tool_name`. Common shapes:

```json
// Bash
{ "command": "ls -la", "description": "list files", "timeout": 30000 }

// Write
{ "file_path": "/abs/path", "content": "..." }

// Edit
{ "file_path": "/abs/path", "old_string": "...", "new_string": "..." }

// MCP tool (Claude Code: mcp__<server>__<tool>)
{ "<server-specific params>": "..." }

// UserPromptSubmit (no tool_input — separate user_prompt field)
```

Adapters MUST preserve these shapes. Don't normalize MCP params across AIs.

---

## 7. Hook chain ordering

Multiple hooks can listen to the same event. Execution and aggregation are
runtime-specific. Claude Code runs all matching handlers in parallel and
deduplicates identical handlers, so array position is not execution order.

The framework's logical policy precedence for `PreToolUse` is:

```
1. fast-fail security guards   (pre-tool-guard, secret-content-scan)
2. resource mutex              (r4-mutex-check, r4-file-mutex-check)
3. cwd guards                  (sandbox-cwd-guard if relevant)
4. sandbox bypass detection    (context-mode-guard if relevant)
5. specialist dispatch         (supervisor.py)
6. workflow guards             (plan-gate, tdd-guard)
7. observation                 (broadcast, record-*, model-routing-observer, model-routing-advisor)
8. allow accelerators          (plan-scope-allow)
```

An `allow` decision bypasses the AI's native permission prompt only — it never
overrides another hook's stricter result. Claude applies
`deny > defer > ask > allow`. Agent-owned wrappers or gateways must implement
and test their own documented aggregation rule.

If a runtime cannot prompt for `ask`, its adapter must use the explicit fail-closed mapping in
`docs/ai-adapters.md`. It must not emit an unsupported native result.

See `hooks/hooks.json` for Claude registration. Do not encode policy correctness
in handler order or shared side effects between parallel hooks.

---

## 8. Writing a new core hook — checklist

1. Write reproduce test FIRST: `core/tests/<hook-name>-test.sh`. Run — must fail.
2. Implement `core/hooks/<hook-name>.{sh,py}` reading stdin JSON.
3. Make test pass.
4. Decision branch must cover all 3: `allow`, `deny`, `ask` (when applicable).
5. Empty `stdout` for pass-through cases (NOT `null`, NOT `{}`).
6. Document expected `tool_name` matchers in the file's header comment.
7. Add to `adapters/claude-code/settings.json.template` hook registration if appropriate.
8. Run the cross-AI parity test: `bash core/tests/adapter-parity.sh`.

---

## 9. Writing a new AI adapter — checklist

1. Classify the target as a runtime host, model backend, or evaluation source.
2. Create and source a capability descriptor per
   [`cross-runtime-harness-design.md`](cross-runtime-harness-design.md).
3. Create `adapters/<ai-name>/` only for a runtime with a controlled effect boundary.
4. Implement `adapter.sh` (and `adapter.py` if event subscription is needed):
   - Read native AI event format from runtime.
   - Construct canonical stdin JSON (§ 2).
   - Pipe to `core/hooks/<requested-hook>`.
   - Read canonical stdout JSON (§ 3).
   - Translate back to runtime's enforcement mechanism.
5. Define `allow`, `deny`, and `ask`, including fail-closed behavior when unsupported.
6. Provide native registration or package templates showing how users enable hooks.
7. Create `tests/run.sh` exercising at least:
   - `Bash` PreToolUse with safe command → `allow`
   - `Bash` PreToolUse with `cat secrets/foo` → `deny`
   - `Write` PreToolUse to a path containing `.env` → `deny`
8. Add to `core/tests/adapter-parity.sh` for core/translation parity.
9. Add opt-in native runtime tests for registration, file writes, MCP, errors, and bypasses.

---

## 10. Examples

### Pass-through PostToolUse (observation hook)

```python
#!/usr/bin/env python3
import json, sys
data = json.load(sys.stdin)
# ... log to file ...
sys.exit(0)  # NO stdout write
```

### Deny PreToolUse (security guard)

```bash
#!/usr/bin/env bash
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ "$TOOL" == "Bash" ]] && [[ "$CMD" =~ secrets/ ]]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Direct secrets/ access blocked. Use API."}}
EOF
  exit 0
fi
# pass-through
exit 0
```

### Ask PreToolUse (risk area)

```bash
#!/usr/bin/env bash
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')

if [[ "$TOOL" == "mcp__supabase__apply_migration" ]]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Production migration — confirm with explicit migration name."}}
EOF
fi
exit 0
```

---

## 11. Versioning

The protocol is versioned via the framework `CHANGELOG.md`. Breaking changes to event schema bump the framework minor version (e.g., 0.1.x → 0.2.0). All 3 AI adapters MUST update in lockstep.

If you propose a protocol change: open a PR with the canonical doc + all 3 adapter changes + cross-AI parity test in one PR.

---

## 12. Claude Code extended events (adapter-level, non-canonical)

The 5 categories in §1 are the portable subset every adapter must translate. Claude
Code's native surface exposes more (33 documented events as of 2.1.282 — see
`docs/runtime-registry.json` → `claude-code.hook_events_available_count`); some of
those extras are wired directly into `hooks/hooks.json` /
`adapters/claude-code/settings.json.template` as **Claude-only** extensions. They are
NOT part of the cross-AI contract: `core/tests/adapter-parity.sh` only exercises the
canonical 5, and a Codex/Gemini adapter is never expected to translate these. Verified
against https://code.claude.com/docs/en/hooks (checked 2026-09-26).

| Event | Stdin fields (beyond the common set in §2) | Wired to | Why |
|---|---|---|---|
| `PostToolUseFailure` | `tool_name`, `tool_input`, `tool_use_id`, `error` | `circuit-breaker.py` (matcher `Bash`) | Direct failure signal — the hook previously had to infer a Bash failure by parsing `PostToolUse` output; this event reports it without parsing. |
| `SessionEnd` | — (no matcher-relevant field) | `session-close.sh` (`timeout: 2`) | Lock/resource release only. All hooks on this event share a 1.5s default budget; the explicit `timeout: 2` keeps `session-close.sh` (already the heavier cleanup) within its own small headroom without slowing `SessionEnd` for anyone else. Heavier Stop-time work (quality gate, brain capture) stays on `Stop`, which has no such shared-budget constraint. |
| `PreModelSwitch` | `to_model` | `session-tier-observer.py` | Advisory: logs and flags a runtime model switch against the "no-runtime-switching" tier policy before it happens. |
| `PostModelSwitch` | `from_model`, `to_model` | `session-tier-observer.py` | Same script, after the switch — records what actually changed. |
| `SubagentStart` | `agent_type`, `agent_id` | `model-routing-observer.py` | Measures actual dispatch (model/effort in use) at subagent spawn, complementing the `PreToolUse`-time `model-routing-advisor.py` (which fires when the parent invokes `Agent`, before the child session exists). |
| `SubagentStop` | `agent_type`, `agent_id`, `last_assistant_message` | `model-routing-observer.py` | Same script, closing the loop with the subagent's final message once it completes. |
| `PermissionRequest` | (a different `decision` object shape than `permissionDecision`) | **Not wired** | `PermissionRequest`'s stdout contract is a distinct `decision` schema (not `hookSpecificOutput.permissionDecision`), and exit code `2` is not honored on this event per the docs. Wiring an existing `allow`/`deny`/`ask`-shaped hook here would silently do nothing — worse than not wiring it, because it would look enforced. Revisit only with a hook written specifically against that schema. |
| `WorktreeCreate` / `WorktreeRemove` | worktree path/name (lifecycle event, no tool fields) | **Not wired** | A `WorktreeCreate` hook *replaces* git's own worktree creation: the hook must create the worktree and print its absolute path on stdout, and a hook that prints nothing fails the creation. `r4-mutex-check.sh` is an observer (empty stdout, exit 0 always), so wiring it here breaks every Claude-created worktree. `WorktreeRemove` is left unwired with it so a release never fires without its matching registration. The script keeps its worktree branch as tested logic (`core/tests/claude-extended-events-test.sh` §3b); revisit only with a hook that performs the creation itself. |

All matchers above use `*` (match-all) except `PostToolUseFailure`, which reuses the
`Bash`-scoped matcher already established for `PostToolUse` (§7 chain-ordering table),
since `circuit-breaker.py` only tracks Bash failures.

### `if:` field usage (W3-4)

The `if` field (permission-rule syntax, e.g. `"Bash(git *)"`, `"Edit(*.ts)"`) is a
single scalar string per hook handler entry, evaluated only on `PreToolUse`,
`PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, and `PermissionDenied` — it
is not an array and does not apply to lifecycle events. Two decisions in this pass:

1. **`secret-content-scan.py`'s WebFetch/MCP matcher** — the previous matcher was an
   explicit pipe-list of individual MCP tool names (`mcp__supabase__execute_sql`,
   `mcp__supabase__apply_migration`, …). The docs confirm a matcher containing any
   character outside `[A-Za-z0-9_\- ,|]` is evaluated as an **unanchored JS regex**,
   and that `mcp__<server>__.*` is the documented way to match every tool from a
   server. The matcher was collapsed to per-vendor wildcards
   (`mcp__supabase__.*|mcp__firecrawl__.*|mcp__claude_ai_Notion__.*|mcp__claude_ai_Google_Drive__.*|mcp__stitch__.*`),
   which also closes a gap: any *new* tool a vendor's MCP server adds is now scanned
   by default instead of needing a manifest edit to add it to an explicit list.
   This is a `matcher` change, not an `if` rule — `if` narrows within an already-matched
   event/tool and doesn't do cross-tool wildcarding.
2. **`rubric-commit-judge.sh` on `PostToolUse` `Bash`** — this hook's own body already
   greps `tool_input.command` for a `git … commit` shape and exits 0 immediately
   otherwise (see its docstring). Its only work is scoring commits, so it carries
   `"if": "Bash(git commit*)"` — a *narrowing* of the same condition the hook already
   enforces internally, not a new condition. If the `if` glob and the hook's internal
   regex ever disagree on an edge case, the hook's own check is authoritative (the
   `if` field only saves invoking the script; it cannot itself cause the hook to
   score a non-commit or skip a commit its regex would have caught, because a false
   `if`-match still exits 0 inside the script).
3. Every other wired hook keeps `matcher`-only filtering: `pre-tool-guard.sh`,
   `context-mode-guard.sh`, and the rest fire on every `Bash`/`Write|Edit`/`*` call
   in their group and make their own internal decision — adding an `if` there would
   duplicate logic the hook already owns without narrowing anything real.
