# Grok (xAI) Adapter — worker lane only

**This adapter is a WORKER-LANE bridge, not a runtime host adapter.** It does
not wire the framework's hooks into a Grok-hosted session (the way
`adapters/codex/` and `adapters/gemini/` wrap those CLIs' shell tools) — it
lets `core/infra/call-worker.sh` dispatch one-shot, read-only prompts TO the
`grok` CLI as a cross-vendor **advisor**. `adapter-parity.sh` checks hook
parity across claude-code/codex/gemini only; grok is intentionally outside
that set.

Role wiring (`core/infra/backends.json`): grok carries the **`advisor-third`**
role only. It is deliberately NOT wired into any gate role
(`second-opinion-review/verify`) — an advisory lane, never a completion-gate
vote. Consumers opt in explicitly (e.g. `/council-review --with-grok`).

## Files

| File | Purpose |
|---|---|
| `grok-worker.sh`           | stdin→`--prompt-file` bridge + OS sandbox + neutral cwd. |
| `grok-preflight.sh`        | Fail-closed exact-token health probe (call-worker runs it). |
| `grok-tiers.json.template` | Model pin + per-tier args (→ `~/.grok/agent-tiers.json`). |

## Installation

```bash
ln -sf "$PWD/adapters/grok/grok-worker.sh"    ~/bin/grok-worker
ln -sf "$PWD/adapters/grok/grok-preflight.sh" ~/bin/grok-preflight
cp -n adapters/grok/grok-tiers.json.template  ~/.grok/agent-tiers.json
```

(or `setup.sh --grok`, which does the same). If the `grok` CLI itself isn't
installed yet: `curl -fsSL https://x.ai/cli/install.sh | bash` or
`npm i -g @xai-official/grok`. Auth: log in once interactively with the
`grok` CLI (first-launch browser OAuth; requires an eligible xAI subscription
tier) — the credential lands in `~/.grok/auth.json`. The preflight refuses
the lane until a real inference round trip succeeds — the file's presence
proves nothing.

## Read-only: OS-enforced, because the CLI's flags are not

Measured on grok CLI 0.2.118 (2026-08-19, macOS, headless `-p` mode), each of
these was given a "create a file" prompt and **each one wrote the file**:

| Attempted restriction | Result |
|---|---|
| `--tools ''` (empty allowlist) | wrote the file |
| `--permission-mode plan` | wrote the file |
| `--deny write --disallowed-tools write,edit_file,shell,...` | wrote the file |
| `sandbox-exec` deny-write profile (OS level) | **blocked** ("The write tool was blocked", no file) |

The CLI's `shell` tool stays LIVE (its own flags don't remove it), so a
malicious prompt can drive arbitrary local action. `grok-worker.sh` enforces
read-only OUTSIDE the CLI, and the profile blocks what an exfil actually needs
— reading secrets and writing where it matters:

1. **Neutral cwd** — every dispatch runs from a fresh `mktemp -d` WORK_DIR; the
   caller's repository is never on the CLI's path. Prompts carry their diff
   inline and need no repo access.
2. **`sandbox-exec`, writes narrowed to WORK_DIR** — the only writable paths are
   this run's WORK_DIR, `~/.grok` (session store) **minus `agent-tiers.json`**
   (a writable argv source is a persistence hole), and `/dev`. This also stops a
   concurrent council lane from forging a sibling lane's capture file — the
   shared temp scratch is no longer writable to this run.
3. **Credential reads denied** — `~/.ssh`, `~/.aws`, `~/.config`, `~/.codex`,
   `~/.gemini` are read-blocked, so a `shell`+network exfil finds nothing to
   send. (Measured: the CLI still runs; a prompt-driven `cat ~/.ssh/...` returns
   blocked.)
4. **Tier args allow-listed** — only `--reasoning-effort {low,medium,high}` is
   accepted from the tiers file; anything else refuses.
5. **`$HOME` validated** — a `$HOME` carrying scheme metacharacters (`"()\`)
   would let a widened profile be built, so the worker refuses (exit 8).
6. **Web search off by default** — queries derive from the prompt (your diff):
   an exfil channel. `GROK_WORKER_WEB_SEARCH=1` opts in and prints a warning.
7. **No `exec`** — the CLI runs as a child with signal forwarding so the EXIT
   trap fires and the prompt file (the untrusted diff) never outlives the run.

On a host without `sandbox-exec` the worker **refuses** (exit 7);
`GROK_WORKER_ALLOW_UNSANDBOXED=1` is the explicit, warned opt-out.

**Residual risk** (documented, not closed): network and process-exec stay open
(the CLI needs the vendor API, and denying exec blocks the CLI's own launch),
so a prompt can still exfil data it is ALLOWED to read — the diff it was given,
public files. Use this lane only for code you are willing to send to xAI
anyway. Re-measure the table above on every CLI upgrade — a new tool could
route around the profile. Regression coverage: `core/tests/grok-worker-test.sh`
(write-block, credential-read-deny, tiers-write-deny, unsafe-HOME).

## Cost

Every dispatch and every preflight is a real billable call on the user's
SuperGrok/X Premium subscription. `call-worker.sh` refuses without
`AGENT_WORKER_YES=1` (the session that owns the user relationship asks first).
The preflight rides the MID tier (default reasoning effort); dispatches ride
the tier the role pins (advisor-third = TOP → `--reasoning-effort high`).

## Positioning

Grok 4.6 benchmarks a tier below the frontier on code correctness
(SWE-Bench Verified 70.8 vs Opus 4.7's 87.6, 2026-08) — this lane exists for
**perspective diversity** ("different models fail differently"), not as an
authority. Findings arrive tagged `[grok:advisory]` and never flip a gate.
