---
name: council-review
description: Multi-vendor code review council — runs the Claude code-reviewer agent alongside external second opinions (codex, gemini) in parallel, then synthesizes with citation verification, source tagging, and disagreement surfacing. Optionally seats grok as a non-voting advisor (--with-grok). NOT a completion gate (that is /verify-completion), NOT a security audit (security findings route to security-reviewer), and NOT free — every external lane is a paid CLI call the user approves first.
when_to_use: User wants a code review with independent cross-vendor opinions — "council review", "get a second opinion on this diff", "review with codex/gemini", or `/council-review [--staged|--head|<range>] [--with-grok]`.
tools: Bash, Read, Grep, Glob, Agent
---

# /council-review

## Goal

One diff, several independent reviewers, one synthesized report. Different
models fail differently — a finding two vendors reach independently outranks a
finding one vendor reaches confidently, and a synthesizer that answers to the
actual code (not to the reviewers) drops what was hallucinated.

## Lanes

| Lane | Vendor | Lens | Dispatch | Participates in verdict |
|---|---|---|---|---|
| `code-reviewer` agent | anthropic | its own agent charter | Agent tool (model pin: sonnet, unchanged) | yes |
| `second-opinion-review` | openai (codex) | implementation correctness | `core/infra/call-worker.sh` | yes |
| `third-opinion-review` | google (gemini, via antigravity) | architecture & consistency | `core/infra/call-worker.sh` | yes (when lane enabled) |
| `advisor-third` (`--with-grok`) | xai (grok) | unscoped (free perspective) | `core/infra/call-worker.sh` | **no — advisory only** |

Lane SSOT is `core/infra/backends.json`. A disabled lane (e.g. one whose CLI
or preflight is missing) refuses loudly at dispatch; report it as absent —
never substitute another vendor for it (a fallback that shares a seated
vendor would fake the independence signal).

The grok lane runs on the free tier by design (decided 2026-08-19): when its
quota is exhausted mid-review the lane surfaces `status: rate-limited` and the
council **fails open** — the review proceeds without the advisory, the lane
status line says "rate-limited, retry later", and no upgrade prompt is put to
the user.

## Steps

### 1. Assemble the target

Default `--staged` (`git diff --staged`); `--head` reviews `HEAD~1..HEAD`; an
explicit `<range>` is passed through. Abort with a one-liner if the diff is
empty. Build ONE shared core, identical for every external lane:

- the diff, plus 3-5 lines of stated intent (from the commit message / user);
- the output contract — findings only, each with:
  `file:line` · **verbatim quote of the offending line(s)** · severity
  (Blocker/Major/Minor/Note) · category · one-sentence rationale;
- "reply `NO-FINDINGS` if clean; do not restate the diff."

The verbatim-quote field is what makes step 4's hallucination filter possible
— a finding that cannot quote the code it indicts cannot be verified.

Each voting external lane's prompt = its **lens preamble** + the shared core
(decided 2026-08-20: perspective diversity over duplicate generalists — two
lanes reading one diff through different questions surface more than two
copies of the same question):

- **codex lens** (`second-opinion-review`) — implementation correctness:
  "does this diff do what it intends?" Logic errors, edge cases, off-by-one,
  error handling, concurrency, regressions.
- **gemini lens** (`third-opinion-review`) — architecture & consistency:
  "is this diff built the way the system is built?" Design and simplification
  opportunities, API/contract coherence, doc–code drift, cross-file
  consistency, naming.

A lens states emphasis, not permission — each preamble must also say "report
any defect you see, in or out of your lens." Grok (`advisor-third`) gets the
bare shared core, unscoped by design: the advisory seat exists for the
perspective the lenses didn't assign. The Claude `code-reviewer` lane keeps
its own agent charter untouched.

### 2. One cost confirmation

Count the external lanes about to run (2, or 3 with `--with-grok`) and ask the
user ONCE to approve the paid calls. Only on approval set `AGENT_WORKER_YES=1`
— per-invocation, never exported into the session (the env-only gate contract
in call-worker.sh: the session that owns the user relationship asks first).

### 3. Dispatch all lanes in parallel

External lanes in the background (each capture path lands on stdout):

```bash
# Resolve the dispatcher from the plugin cache (plugin install) or the
# checkout (repo install) — never bare cwd-relative.
CW="${CLAUDE_PLUGIN_ROOT:-$PWD}/core/infra/call-worker.sh"
[[ -f "$CW" ]] || echo "council-review: call-worker.sh not found at $CW — harness root unresolved; external lanes are absent this run" >&2

# per-lane prompts from step 1: lens preamble + shared core (grok: core only)
AGENT_WORKER_YES=1 bash "$CW" second-opinion-review < "$PROMPT_CODEX"  > "$CAP_DIR/codex.path" 2> "$CAP_DIR/codex.err" &
AGENT_WORKER_YES=1 bash "$CW" third-opinion-review  < "$PROMPT_GEMINI" > "$CAP_DIR/gemini.path" 2> "$CAP_DIR/gemini.err" &
# --with-grok only:
AGENT_WORKER_YES=1 bash "$CW" advisor-third         < "$PROMPT_CORE"   > "$CAP_DIR/grok.path" 2> "$CAP_DIR/grok.err" &
```

The `[[ -f "$CW" ]]` line is a diagnostic, not a short-circuit: if the path is
missing the dispatches below still run and each exits 127, which the
degradation table already maps to "lane absent" — the echo just names the
unresolved root instead of leaving a bare shell error. A missing `$CW`
therefore means every external lane is reported absent this run (step 5's
false-council guard applies) — never substitute a different resolution.

Simultaneously dispatch the `code-reviewer` agent (Agent tool) on the same
diff — its frontmatter model pin stands; do not override. Then wait per lane
capturing each exit code (`wait "$pid_codex" || rc_codex=$?` …) — the
degradation table below keys off these codes, and the pre-dispatch refusal
path (exit 3) writes no capture file, so the exit code is the only signal for
it. Each lane's `timeout_s` in backends.json is the hard cap — no
sleep-polling.

### 4. Synthesize — in this order

1. **Mechanical truth first**: read each capture file's frontmatter; only
   `status: complete` lanes are seated. Anything else → the lane status table
   (step 5), with `unavailable_reason`/`fallback_reason` quoted.
2. **Dedup** across lanes: same file + overlapping lines + same essential
   issue = one finding, all sources credited.
3. **Citation check** — the hallucination filter: `Read` the actual file at
   each finding's `file:line` and compare against the finding's verbatim
   quote. No match after dedup → DROP the finding, and count drops per lane
   (reported — a lane's drop rate is signal about that lane).
4. **Severity re-rating**: re-rate every surviving finding against repo
   context yourself; external self-ratings are input, not verdict.
5. **Source tagging**: `[claude]` `[codex]` `[gemini]` `[grok:advisory]`.
   Findings reached independently by ≥2 seated vendors are marked
   **high-signal** and listed first. Lenses don't weaken this rule — a defect
   two lanes reached through *different* questions is, if anything, stronger
   agreement than two copies of the same question would give.
6. **Disagreements**: where seated lanes conflict, show both positions and
   adjudicate with a stated reason — against the code, not against authority.
7. **Grok section** (when present): separate, labeled
   "advisory — not part of the verdict"; its findings never flip severity or
   the overall verdict.

Security-shaped findings (auth, injection, secrets, crypto) are LISTED but
not adjudicated here — route them to `security-reviewer` (the
no-double-reporting contract in agents/code-reviewer.md applies to the
council too).

### 5. Report

```
## Council review — <target>
Lane status: claude ✓ | codex ✓ | gemini ✗ absent (<reason>) | grok ✓ advisory
Citation drops: codex 1, gemini 0

### High-signal (≥2 vendors)  ...
### Findings                  ...
### Disagreements             ...
### Advisory (grok)           ...
```

**False-council guard**: if EVERY external lane is absent, the first line of
the report must say this was a single-vendor review, not a council — the
Claude lane always runs, but it must not borrow the council's authority.

## Degradation

| Signal | Meaning | Action |
|---|---|---|
| call-worker exit 3 | not approved | re-ask or drop the lane |
| exit 127 / `status: unavailable` | lane disabled / CLI or preflight missing | lane absent, quote reason |
| exit 124 / `status: timeout` | hung CLI killed | lane absent |
| exit 1 / `status: rate-limited` | vendor quota/rate limit hit (e.g. grok free tier) | lane absent — fail-open; report "rate-limited, retry later", never an upgrade pitch |
| exit 1 / `status: failed` | backend errored | lane absent, quote stderr tail |

External failures never abort the review — the Claude lane carries it.
