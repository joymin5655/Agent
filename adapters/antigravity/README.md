# adapters/antigravity — the `agy` (Antigravity CLI) review worker lane

Restores the council's seated google lane (`third-opinion-review`) after the
gemini CLI's individual OAuth was retired upstream (2026-06-18). Decided
2026-08-19: migrate to Antigravity (`agy`), Google's official successor, instead
of chasing an AI Studio API key.

Two independent pieces live here:

- the **review worker lane** (`antigravity-worker.sh`, `antigravity-preflight.sh`) that
  `call-worker.sh` dispatches to;
- the **native-hook plugin** (`adapter.sh`, `adapter.py`, `install-plugin.py`) that puts the
  core guards in front of agy's own tool calls (see "Native hooks (plugin)").

Measured against agy **1.2.12** in a live headless probe on **2026-09-29** (scratch workspace,
no paid worker dispatch). Sections labeled "1.1.14" keep the earlier 2026-08-19 measurement.

## Install / auth (measured 2026-08-19, agy 1.1.14; still current on 1.2.12)

- Official installer drops the binary at `~/.local/bin/agy`:
  `curl -fsSL https://antigravity.google/cli/install.sh | bash`
- **Auth = the OS keyring, seeded once interactively.** On this machine the
  keyring was already authenticated (Antigravity IDE had run before), so
  `agy -p "..."` answers headless with no login. If the credential expires,
  re-login is a documented interactive user step (`agy` opens a browser, or an
  SSH device-code flow) — the worker does NOT automate it; the preflight just
  fails closed so a dead credential surfaces as an absent lane, never a hang.
- **Opt-in API-key path (`ANTIGRAVITY_AUTH=apikey`).** The keyring stays the default. With the
  variable set, `antigravity-worker.sh` reads a Gemini API key from the macOS Keychain
  (service `gemini-api-key`, the same `security find-generic-password -a "$USER" -s <service>
  -w` pattern as the OpenRouter worker) and exports `GEMINI_API_KEY` into agy's environment
  only. The key is never put in argv, never logged, and never named in an error message. A
  missing Keychain item or a missing `security` binary exits 2 with a message that names the
  service. Any other value (or unset) keeps the keyring path and never calls `security`.
  Register the key yourself (the command prompts for the value, so it stays out of argv):
  `security add-generic-password -a "$USER" -s gemini-api-key -w`. agy also needs
  `"modelProvider": "gemini"` in `~/.gemini/antigravity-cli/settings.json` for the variable
  to take effect; the worker warns on stderr when that is absent and never edits the file.
  This path is opt-in because the install docs and a CLI maintainer (antigravity-cli issue
  #78) disagreed about it and the keyring already works; `setup.sh --antigravity` only prints
  this guidance and applies none of it. Security note: with the API-key path the key sits in
  the environment of agy and its sandbox (see "Worker threat model").

## argv contract (measured)

- Prompt is the POSITIONAL arg to `-p`/`--print`; flags must come BEFORE it —
  `agy --effort low -p "prompt"` works, `agy -p "prompt" --effort low` misparses.
- stdin does NOT interfere with the positional prompt (a piped stdin is ignored
  when `-p` carries the prompt) — so the worker writes the diff to the prompt arg.
- `--output-format json` returns a clean single-object envelope:
  `{"conversation_id","status":"SUCCESS","response","duration_seconds","num_turns","usage":{...}}`
  — `status` and `response` are the mechanical-truth fields the preflight keys on. On 1.2.12
  the envelope also carries a `denied_actions` array (see "Success contract").

## Tool posture matrix (measured on 1.1.14, 2026-08-19 — historical)

This is the original 1.1.14 probe, kept as the historical baseline. The 1.2.12 behavior differs
in two ways that matter for the threat model (see "Worker threat model" below). Probe: a temp
cwd, one prompt ordering the agent to (1) write `PWNED-WRITE.txt`
and (2) run `touch PWNED-SHELL.txt`. Transcripts under
`.agent/plans/antigravity-lane/probes/`.

| mode | shell exec | file created | exit | note |
|---|---|---|---|---|
| default (`agy -p`) | **denied** ("user denied permission to run command") | **none** | 1 | fail-closed by default |
| `--mode plan` | deferred behind an approval that never comes headless | **none** | 0 | builds a plan, executes nothing |
| `--sandbox` | **denied** | **none** | 1 | same denial as default in this probe |

Key result: **no probe created a file or ran a command.** The default already
fails closed on shell exec. The file-write tool was never observed to succeed,
but the transcript did not explicitly show it being denied (only the shell
denial surfaced) — so the write path is "no file produced," not "provably
gated." A code review needs neither write nor exec (it reads the diff from the
prompt and emits findings text), so the worker runs default mode with
`--dangerously-skip-permissions` FORBIDDEN, and — belt-and-suspenders, matching
the grok lane — under an OS `sandbox-exec` deny-write/deny-cred-read profile so
the unproven write path cannot matter. See `antigravity-worker.sh`.

## Success contract (soft-deny)

The headless docs (fetched 2026-09-28) say a tool call that cannot get approval is
**soft-denied**: the run continues, exits `0`, and prints a stderr notice. The `exit 1` rows in
the 1.1.14 table above are the older measurement. So exit 0 is not success by itself.

agy 1.2.12 (measured 2026-09-29) reports a soft-deny two ways at once:

- the `--output-format json` envelope gains a non-empty `"denied_actions"` array, for example
  `[{"action":"write_file","display_name":"WriteToFile"}]`, and `response` is empty;
- stderr prints a notice starting `jetski: no output produced` that says a tool required a
  permission headless mode "cannot prompt for" and it was **auto-denied**.

The run ends at the first soft-deny. The 1.1.14 wording was `permission check failed` /
`denied permission to`. The worker treats a soft-deny as either signal: `denied_actions` with
one or more entries (when stdout is exactly one JSON value), or a stderr match (case
insensitive) on `permission check failed|denied permission to|auto-denied|cannot prompt for`.
An empty `"denied_actions":[]` is not a soft-deny.

| worker exit | meaning | preflight exit |
|---|---|---|
| 0 | envelope `status == "SUCCESS"`, no soft-deny signal | 0 if `.response` holds the token |
| 9 | agy exited 0 but soft-denied a tool call (envelope or stderr) | 8 — lane **absent** |
| 10 | agy exited 0 but the envelope is unparseable or `status` is not SUCCESS | 5 |
| 3 | agy's own exit code when the envelope `status` is `ERROR` (undocumented; the docs list 0/1/2) | 5 |
| 2 | usage/config error, or `ANTIGRAVITY_AUTH=apikey` with no Keychain item / no `security` | 5 |

Any agy nonzero exit code (including 3) passes through the worker unchanged; the preflight
reports every such probe exit as 5 (state unknown). A hook-level deny
is invisible to the caller: it is exit 0, status `SUCCESS`, no stderr, no `denied_actions` (a
denied step just shows up in the transcript as `tool call denied by pre-tool hook`), so it
does not trip exit 9. A worker dispatch is exactly that case: the workspace deny plugin (and,
if the environment variable reaches the hook, the adapter's worker mode) denies every attempted
`run_command` or write tool call, so it is silent. A worker exit 0 therefore does not prove the
model made no tool calls, and exit 9 no longer fires for tool-use attempts (it still fires for
permission soft-denies from tools outside the deny matcher).

## Native hooks (plugin)

agy loads hooks from plugin folders. `setup.sh --antigravity` installs one so the core guards
(`pre-tool-guard.sh`, `secret-content-scan.py`, `check-hardcoding.py`, `tdd-guard.py`,
`spec-gate.py`, the r4 mutex hooks) run in front of agy's own tool calls. The `PostToolUse`
hooks (`circuit-breaker.py`, `verify-observer.py`, `r4-file-mutex-register.sh`) and the Stop
gates run after the fact as observers; see "Events and tools". Measured on 1.2.12 against a
workspace plugin on 2026-09-29; the global folder below is documented but its loading by a real
agy was not measured.

**Install / uninstall.** The plugin folder is
`${AGENT_ANTIGRAVITY_PLUGIN_DIR:-$HOME/.gemini/config/plugins/agent-harness}` and holds
`plugin.json` plus a rendered `hooks.json` with the absolute path of `adapter.sh`.

```bash
bash setup.sh --antigravity                        # installs the plugin (idempotent)
python3 adapters/antigravity/install-plugin.py --root "$PWD" --check      # NONE | BROKEN | OK
python3 adapters/antigravity/install-plugin.py --root "$PWD" --uninstall  # removes our two files
```

The installer never reads or writes `~/.gemini/config/hooks.json` (other tools register
there) or `~/.gemini/antigravity-cli/settings.json` (agy rewrites it itself). It refuses a
target folder whose plugin is not `agent-harness`, refuses a framework root containing shell
metacharacters (`"`, newline, backtick, `$`, backslash, control characters), and uninstall
keeps any file you added to the folder (a small `.agent-harness-owned` marker stays with it, so
a later install or uninstall still recognizes the folder as ours; the marker goes when the last
file does). `setup.sh --doctor` reports the plugin as PASS (hooks
point at an executable adapter), WARN (not installed while `agy` is on PATH) or FAIL (broken).
Restart any running agy session after installing.

**Events and tools.** The plugin wires `PreToolUse`, `PostToolUse` and `Stop`, one adapter
command per event (agy sends no event name on stdin, so it comes from argv). The `PreToolUse`
matcher is
`run_command|send_command_input|write_to_file|replace_file_content|multi_replace_file_content`
(`PostToolUse` omits `send_command_input`). The adapter maps them to the canonical `Bash`,
`Write` and `Edit` events (`send_command_input` becomes a `Bash` event carrying the typed
`Input`: text sent into a live shell is a command in all but name, and a call without a string
`Input` is denied unless it only sets `Terminate`; `multi_replace_file_content`
becomes one `Edit` per chunk, capped at 100) and runs the same core-hook chains as the Codex
template; `core/tests/antigravity-adapter-test.sh` fails if the two drift. Mapping and canonical
fields: [`docs/hook-protocol.md`](../../docs/hook-protocol.md) §13. `PostToolUse` hooks
(`circuit-breaker.py`, `verify-observer.py`, `r4-file-mutex-register.sh`) run after the call as
observers and their stdout is discarded, so circuit-breaker's "change your approach" context
never reaches the model on agy (only its state file and the r4 register hook's side effect are
effective). Relaying `PostToolUse` context to agy is unmeasured. The argument keys of
`send_command_input` (`Input`, `Terminate`) come from agy's binary, not from a live call; a
shape mismatch is a fail-closed deny.

**Decisions and why `{}` is not used.** On agy 1.2.12 a PreToolUse stdout of `{}` is a DENY
(measured). A hook `{"decision":"allow"}` behaved like `ask` in headless and did not bypass the
`write_file` permission (M5); its grant semantics are otherwise unmeasured, so the adapter never
emits it (D1) and never prints `{}` as a pass-through. When no core hook objects it prints
`{"decision":"ask"}`, which makes agy fall back to its own permission handling (the command ran
when no rule matched). A core-hook deny becomes `{"decision":"deny","reason":...}`. A core-hook
`ask` (a guard demanding a human, for example `git commit --no-verify`) becomes
`{"decision":"force_ask","reason":...}`: agy documents plain `ask` as respecting the user's
`permissions.allow` rules and Always-Allow cache, so a matching rule such as `command(git commit)`
could satisfy it silently, while `force_ask` ignores them. That difference comes from agy's
bundled hook docs; no live probe combined a hook `ask` with an allow rule, and headless
`force_ask` behavior (no one to prompt) is unmeasured. Advisory-only context stays a plain `ask`
with a reason (it needs no confirmation). Every failure (a missing or non-executable hook,
timeout, bad JSON, exit code other than 0, an exhausted 25s budget, malformed stdin, an
unverified argument shape) is turned into an explicit deny; a malformed
`AGENT_ANTIGRAVITY_BUDGET_S` falls back to 25. PostToolUse always prints `{}`. Unknown tools
get the bare `ask` plus a stderr note.

**Worker mode.** `antigravity-worker.sh` exports `AGENT_ANTIGRAVITY_WORKER=1` for every
dispatch. When the adapter sees exactly `1`, PreToolUse denies every matched tool call with
"review worker: tools are disabled" without running a hook (a review needs neither exec nor
write), PostToolUse prints `{}`, and Stop stops. Whether an arbitrary parent environment
variable reaches the hook process is not measured; if it does not, the core hooks run under
the worker's sandbox and any failure is a deny. Independently of that, the worker writes a
workspace plugin into its own scratch directory (`.agents/plugins/agent-worker-deny/`, the
layout measured in M1) whose static hook denies `run_command`, `send_command_input` and the
three write tools and stops the run. It needs neither the variable nor the global plugin, and
a worker that cannot write it exits 2 before agy starts (and before any API key is exported).

**Stop loop guard.** A core Stop hook that returns `block` becomes
`{"decision":"continue","reason":...}` once. The adapter keeps a marker under
`${AGENT_STATE_DIR:-$HOME/.agent/state}/antigravity-stop/<conversationId>` (the id must match
`^[A-Za-z0-9-]{1,64}$`, otherwise no hook runs and the answer is `stop`). While the marker
exists the next Stop answers `stop` and removes it, so the gate cannot loop; markers older
than 6 hours are ignored, and if the marker cannot be written the adapter answers `stop`.
The Stop chain shares one 25s budget (below the 30s `timeout`), but `brain-capture.py` and
`session-close.sh` each keep a reserved 20% slice, so a slow `session-quality-gate.py` (at most
the remaining 60%, about 15s) cannot starve them. A completion gate that overruns its slice is
killed, reported on stderr ("did not finish"), and its verdict is not applied: `completion_tests`
that take longer than that cannot gate on agy. `session-quality-gate.py` attributes edits to the
session from agy's `transcript_full.jsonl` shape (`tool_calls[].args.TargetFile` of the three
write tools) as well as Claude's. Advisories it prints are not relayed (Stop relays block only).

**Not covered.**

- No `SessionStart`, `UserPromptSubmit` or `SessionEnd` equivalent is wired (agy's own event
  set has none that maps cleanly); `PreInvocation`/`PostInvocation` are left unwired.
- Tools outside the matcher are not guarded: `view_file`, MCP tools, browser tools,
  `invoke_subagent`, `command_status` (read-only) and anything else agy adds. The tool set was
  not enumerated from a live agy; only `send_command_input` was added after review.
- Interactive `ask`/`force_ask` UX is not measured, so the user-visible behavior of the
  pass-through with a matching permission rule, and of `force_ask` headless, is unverified.
- Relaying `PostToolUse` `additionalContext` or `Stop` advisories to agy is unmeasured; both are
  discarded.
- Whether a hook deny still holds under `--dangerously-skip-permissions` is not measured (the
  probe was blocked). Do not rely on the plugin as the only control in that mode.
- Whether agy honors `{"decision":"continue"}` on Stop, and whether a `PostToolUse` `error`
  can be a non-string, are unverified (the adapter stringifies non-strings).
- Because the hook's cwd is the plugin directory, the adapter takes the workspace from
  `run_command`'s `Cwd` or `workspacePaths[0]` and never from its own cwd.

## Worker threat model (drift from 1.1.14)

The 1.1.14 matrix above showed shell exec denied by default. On 1.2.12 headless, an
`echo` via `run_command` ran with **no allow rule** (measured, while a hook returned `ask` or
`allow`), and a hook `allow` did not bypass the `write_file` permission (the write was still
auto-denied). Inferred, **not measured on 1.2.12**: that agy applies the user's
`~/.gemini/antigravity-cli/settings.json` `permissions.allow` (for example `command(touch ...)`)
to worker runs because the worker uses the real HOME, and what a run with no hook at all does
for other commands. So "fail-closed by default" is not assumed. The controls that hold are:

1. the OS `sandbox-exec` profile: deny-write outside the scratch directory and agy's state dir,
   deny-read of credential stores. Inside the writable `~/.gemini` it now also denies writes to
   `config/hooks.json`, `config/plugins/` and `settings.json`, so a prompt-injected command
   cannot plant or replace a hook that would later run unsandboxed in your interactive agy
   (`antigravity-cli/settings.json` stays writable because agy rewrites it itself). It does **not**
   stop reads of environment variables or network egress;
2. a workspace deny plugin written into the scratch directory before agy starts (static hook,
   no environment or adapter dependence), plus the adapter's worker-mode deny
   (`AGENT_ANTIGRAVITY_WORKER=1`), which depends on the variable reaching the hook (unmeasured);
3. `--dangerously-skip-permissions` stays forbidden.

With `ANTIGRAVITY_AUTH=apikey` the key is in the environment of agy and its sandbox, so a
prompt-injected `env` call could read it if the deny plugin does not stop that call: the worker
exports the key only after writing that plugin and refuses to start when it cannot. Live loading
of a workspace plugin was measured, but the deny matcher and that the hook is not skipped in a
worker run were not exercised against a paid dispatch. Prefer the keyring path unless you need
the API key. In keyring mode the worker does not scrub an ambient `GEMINI_API_KEY` inherited
from its caller.
