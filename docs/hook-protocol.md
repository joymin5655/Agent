# Hook Protocol — Canonical

The hook protocol is the single contract that makes the framework AI-agnostic. Every `core/hooks/*` script reads JSON from `stdin` and writes JSON to `stdout`. Each AI adapter translates the runtime's native event format to/from this canonical JSON.

If you write a new core hook OR a new AI adapter: this is the doc.

---

## 1. Event categories

The framework defines 5 event categories, mirroring Claude Code's native taxonomy (which is the most expressive of the 3 supported AIs):

| Category | Fires when | Decision possible? |
|---|---|---|
| `PreToolUse` | Before a tool runs (Bash, Write, Edit, MCP call, etc.) | Yes — `allow` / `deny` / `ask` |
| `PostToolUse` | After a tool returns | No — observation only |
| `SessionStart` | Session begins | No — observation / setup |
| `Stop` | Session ends / model done | No — observation / cleanup |
| `UserPromptSubmit` | User submits a message | Yes — `allow` / `block` |

Codex CLI and Gemini CLI may not have all 5 native event types — see [`ai-adapters.md`](ai-adapters.md) for per-AI mappings.

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
| `1` | Hook errored — runtime should treat as `ask` (fail-safe) |
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

Multiple hooks can listen to the same event. The runtime executes them sequentially. The framework convention for ordering (PreToolUse):

```
1. fast-fail security guards   (pre-tool-guard, secret-content-scan)
2. resource mutex              (r4-mutex-check, r4-file-mutex-check)
3. cwd guards                  (sandbox-cwd-guard if relevant)
4. sandbox bypass detection    (context-mode-guard if relevant)
5. specialist dispatch         (supervisor.py)
6. workflow guards             (plan-gate, tdd-guard)
7. observation                 (broadcast, record-*, model-routing-observer)
8. allow accelerators          (plan-scope-allow — last, so any earlier deny short-circuits first)
```

An `allow` decision bypasses the AI's native permission prompt only — it never overrides another hook's `deny`/`ask` (most-restrictive-wins). Any hook returning `deny` short-circuits the chain. Any hook returning `ask` defers to user — chain continues after user confirmation.

See `adapters/claude-code/settings.json.template` for the canonical registration order.

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

1. Create `adapters/<ai-name>/`.
2. Implement `adapter.sh` (and `adapter.py` if event subscription needed):
   - Read native AI event format from runtime.
   - Construct canonical stdin JSON (§ 2).
   - Pipe to `core/hooks/<requested-hook>`.
   - Read canonical stdout JSON (§ 3).
   - Translate back to runtime's enforcement mechanism.
3. Provide `<ai>-settings.template` or `<ai>-config.template` showing how user registers hooks.
4. Create `tests/run.sh` exercising at least:
   - `Bash` PreToolUse with safe command → `allow`
   - `Bash` PreToolUse with `cat secrets/foo` → `deny`
   - `Write` PreToolUse to a path containing `.env` → `deny`
5. Add to the `core/tests/adapter-parity.sh` matrix.

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
