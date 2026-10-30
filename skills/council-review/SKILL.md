---
name: council-review
description: Multi-vendor code review council — runs the Claude code-reviewer agent alongside external second opinions (codex, gemini) in parallel, then synthesizes with citation verification, source tagging, and disagreement surfacing. NOT a completion gate (that is /verify-completion), NOT a security audit (security findings route to security-reviewer), and NOT free for the codex/gemini lanes — those are CLI calls on a vendor subscription, approved by a usage-policy command while they fit inside it and by the user otherwise.
when_to_use: User wants a code review with independent cross-vendor opinions — "council review", "get a second opinion on this diff", "review with codex/gemini", `/council-review [--staged|--head|<range>]`; 한국어 "교차 리뷰", "다른 AI로 검토", "council 리뷰" — or `council-escalation-gate.py` denied a plain code-reviewer dispatch because the diff is council-scale (core/infra/council-threshold.sh). Applies even when the diff is pasted inline or you could review it yourself — a same-vendor self-review is not a second opinion.
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

Lane SSOT is `core/infra/backends.json`. A disabled lane (e.g. one whose CLI
or preflight is missing, or one the caller's env lists in `AGENT_WORKER_DISABLE`)
refuses loudly at dispatch; report it as absent —
never substitute another vendor for it (a fallback that shares a seated
vendor would fake the independence signal).

A lane whose vendor quota is exhausted mid-review (e.g. the Google account's
Antigravity quota) surfaces `status: rate-limited` and the council **fails
open** — the review proceeds without that lane, the lane status line says
"rate-limited, retry later", and no upgrade prompt is put to the user.

## Round cap

At most two full councils (and `security-reviewer` re-reviews) per PR/diff. From round 3,
confirm only the fix delta with one `code-reviewer` (plus one external lane when a risk file
changed, under the Step 0.5 council-active flag); leftovers go to the PR body's "Deferred
findings"; only a Critical leftover earns another round. Full rule: `${CLAUDE_PLUGIN_ROOT}/skills/council-review/reference.md`.

## Steps

### 0.5. Mark council-active before dispatching the Claude lane

Before this skill's own `code-reviewer` Agent dispatch (step 3), set the
council-active flag through the gate's own CLI — never write a flag file
directly. The escape hatch now lives OUTSIDE this repo (keyed to the project
root) and its content must be the CURRENT diff's hash, which only the CLI
can produce:

```bash
CEG="${CLAUDE_PLUGIN_ROOT}/core/hooks/council-escalation-gate.py"
python3 "$CEG" --council-flag set
```

This is the escape hatch `council-escalation-gate.py` checks first (TTL
`AGENT_COUNCIL_ACTIVE_TTL_S`, default 300s, bound to this diff's hash) —
without it, the same gate that routed the caller here would also deny the
council's own internal code-reviewer dispatch. Clear it again in step 6 once
the run is done — the flag only needs to cover this one dispatch, and a
still-fresh flag left behind would silently un-gate a later, unrelated diff.

### 1. Assemble the target

Default `--staged` (`git diff --staged`); `--head` reviews `HEAD~1..HEAD`; an
explicit `<range>` is passed through. Abort with a one-liner if the diff is
empty. Build ONE shared core, identical for every external lane:

- the diff, plus 3-5 lines of stated intent (from the commit message / user);
- the **impact context**, if any. Run
  `python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/impact-context.py" <same target>`
  and paste its block verbatim; empty output means omit it. It names files that
  depend on the changed code but are not in the diff, plus the tests the change
  reaches. Ask each lane to check whether those outside callers still hold,
  because a reviewer who sees only the diff cannot see a caller it breaks.
  Findings about an outside caller must still quote a line from the diff
  (step 4's filter is unchanged);
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

- **spec axis** (every lane, appended to the shared core) — "where does the
  diff contradict the stated intent or the spec?" Report each as a finding with
  category `spec` and quote both the diff line and the intent/spec line it
  contradicts. Correct code that does the wrong thing is invisible to a pure
  bug hunt; skip this axis only when no intent or spec was supplied (say so).

A lens states emphasis, not permission — each preamble must also say "report
any defect you see, in or out of your lens." The Claude `code-reviewer` lane
keeps its own agent charter untouched.

### 2. One cost confirmation

With `AGENT_WORKER_POLICY_CMD` set, do not ask up front: `call-worker.sh` asks that
usage-policy command before each external lane, every time, even with
`AGENT_WORKER_YES=1`. Exit 0 runs the lane; a cap (policy exit 75) skips it as
`unavailable: capped` (exit 127, lane absent) and YES does not reopen it. Only the lanes
that came back exit 3 (the policy said no, or it failed closed) go to the user, ONCE,
together. Without a policy command nobody has approved the spend: ask the user ONCE, as
their own money decision, for the external lanes about to run (2: codex and gemini).
Only on approval set `AGENT_WORKER_YES=1` — per-invocation, never exported into the
session (the env-only gate contract in call-worker.sh: the session that owns the user
relationship asks first).

**Approval declined**: skip every external lane that needed it (no YES call for it;
with no policy that means no `call-worker.sh` calls at all) and proceed with the lanes
that ran, or the Claude `code-reviewer` lane alone. When no external lane ran, this is the same
"single-vendor review" degrade the single-vendor warning (step 5) reports for,
so the report's first line must say so rather than borrow the council's
authority. This lane's own `code-reviewer` dispatch still needs the step 0.5
flag — the gate does not know approval was declined, only that the
council-active flag is fresh and bound to this diff's hash.

### 3. Dispatch all lanes in parallel

External lanes in the background (each capture path lands on stdout):

```bash
# council-lanes:begin
# Resolve the dispatcher from the plugin cache (plugin install) or the
# checkout (repo install) — never bare cwd-relative.
CW="${CLAUDE_PLUGIN_ROOT}/core/infra/call-worker.sh"
[[ -f "$CW" ]] || echo "council-review: call-worker.sh not found at $CW — harness root unresolved; external lanes are absent this run" >&2

# Bind every capture to this diff: sha256 over the staged blobs of risk-path files
# (empty when none). Pass it per call so the reviews.jsonl index row carries it.
# Only for --staged. For --head / <range> leave DK empty: the key describes the
# staged index, so a key for another diff would bind evidence to the wrong content.
DK=""
DIFF_SEL="${DIFF_SEL:---staged}"   # the selector this run reviews: --staged (default), --head or <range>
if [[ "$DIFF_SEL" == "--staged" ]]; then
  DK="$(python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/review-evidence.py" key --staged)" \
    || { echo "council-review: diff key failed — dispatch without one" >&2; DK=""; }
fi

# The authors' companies (call-worker skips their lanes). If author-vendor fails they are
# unknown, so no external lane is called: no external review this run.
NO_EXTERNAL=0
if AV="$(python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/review-evidence.py" author-vendor)" && [[ -n "$AV" ]]; then
  export AGENT_AUTHOR_VENDOR="$AV"
else
  echo "council-review: author-vendor failed — authors unknown, no external lane called (no external review)" >&2
  NO_EXTERNAL=1
fi

# per-lane prompts from step 1: lens preamble + shared core.
# lane <name> <role> <prompt> <attempt> [YES] — one call, its own capture files per attempt.
lane() {
  if [[ "${5:-}" == "yes" ]]; then
    AGENT_WORKER_YES=1 AGENT_REVIEW_DIFF_KEY="$DK" bash "$CW" "$2" < "$3" \
      > "$CAP_DIR/$1.$4.path" 2> "$CAP_DIR/$1.$4.err"
  else
    AGENT_REVIEW_DIFF_KEY="$DK" bash "$CW" "$2" < "$3" \
      > "$CAP_DIR/$1.$4.path" 2> "$CAP_DIR/$1.$4.err"
  fi
}
rc_codex=skip; rc_gemini=skip
if [[ "$NO_EXTERNAL" == 1 ]]; then
  :  # both lanes stay "skip"; step 5 reports a single-vendor review
elif [[ -n "${AGENT_WORKER_POLICY_CMD:-}" ]]; then
  # The policy decides each lane. No YES on the first call.
  lane codex  second-opinion-review "$PROMPT_CODEX"  1 & pid_codex=$!
  lane gemini third-opinion-review  "$PROMPT_GEMINI" 1 & pid_gemini=$!
  rc_codex=0;  wait "$pid_codex"  || rc_codex=$?
  rc_gemini=0; wait "$pid_gemini" || rc_gemini=$?
  # Only lanes that came back exit 3 go to the person, ONCE, for those lanes together
  # (step 2). Set APPROVED_CODEX / APPROVED_GEMINI to 1 for each lane they approve.
  # YES re-runs only the policy's exit 3; a cap (exit 127, capped) stays closed.
  if [[ "$rc_codex" == 3 && "${APPROVED_CODEX:-0}" == 1 ]]; then
    rc_codex=0; lane codex second-opinion-review "$PROMPT_CODEX" 2 yes || rc_codex=$?
  fi
  if [[ "$rc_gemini" == 3 && "${APPROVED_GEMINI:-0}" == 1 ]]; then
    rc_gemini=0; lane gemini third-opinion-review "$PROMPT_GEMINI" 2 yes || rc_gemini=$?
  fi
else
  # No policy: only the lanes the person approved in step 2, each exactly once.
  [[ "${APPROVED_CODEX:-0}"  == 1 ]] && { lane codex  second-opinion-review "$PROMPT_CODEX"  1 yes & pid_codex=$!; }
  [[ "${APPROVED_GEMINI:-0}" == 1 ]] && { lane gemini third-opinion-review  "$PROMPT_GEMINI" 1 yes & pid_gemini=$!; }
  [[ -n "${pid_codex:-}"  ]] && { rc_codex=0;  wait "$pid_codex"  || rc_codex=$?; }
  [[ -n "${pid_gemini:-}" ]] && { rc_gemini=0; wait "$pid_gemini" || rc_gemini=$?; }
fi
# Each lane's capture path is the last non-empty "$CAP_DIR/<lane>.<attempt>.path".
# council-lanes:end
```

Each lane runs once per attempt (an approved policy exit 3 retries at most once, with YES),
and every attempt writes its own `<lane>.<attempt>.path`/`.err`.
`core/tests/council-lanes-test.sh` runs the lines between the `council-lanes` markers. In
the policy branch the first wait happens before the question, because only exit 3 lanes are
asked about; the `code-reviewer` lane below still runs alongside them.

Where captures live and what the `[[ -f "$CW" ]]` line means: `${CLAUDE_PLUGIN_ROOT}/skills/council-review/reference.md`.

Simultaneously dispatch the `code-reviewer` agent (Agent tool) on the same
diff — its frontmatter model pin stands; do not override. The block above
already waits per lane and keeps each exit code in `rc_codex` / `rc_gemini`
(`skip` = not called) — the degradation table below keys off these codes, and
the pre-dispatch refusal path (exit 3) writes no capture file, so the exit code
is the only signal for it. Each lane's `timeout_s` in backends.json is the hard
cap — no sleep-polling.

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
   context yourself; external self-ratings are input, not verdict. Filter
   before bucketing (each drop is **Dismissed** with its reason, never silent):
   - A lane whose findings are all trivia or taste → say the change is
     largely fine; don't fill Act on to look useful.
   - "What if X is null / empty / huge?" counts only if a real caller can pass
     it — trace the call sites; reason = the call site that rules it out.
   - "I'd have done it differently" with no defect → Dismissed (a genuine
     trade-off → Consider).
   - A finding that ignores a repo convention → check the convention; reason =
     where it is used.
   - A security or correctness claim from one lane is verified against the
     code, never waved off on judgment; unverifiable → Consider. Security
     claims stay security-reviewer's.
5. **Source tagging**: `[claude]` `[codex]` `[gemini]`. Findings reached
   independently by ≥2 seated vendors are marked **high-signal** and listed
   first. Lenses don't weaken this rule — a defect two lanes reached through
   *different* questions is, if anything, stronger agreement than two copies of
   the same question would give.
6. **Disagreements**: where seated lanes conflict, show both positions and
   adjudicate with a stated reason — against the code, not against authority.
7. **Action bucket**: give every surviving finding exactly one bucket, separate
   from severity (severity = how risky it is; bucket = what the reader does):
   - **Act on** — fix before merge; verified against the code.
   - **Consider** — real trade-off or judgment call; owner decides.
   - **Noted** — true but out of this change's scope; carry to backlog.
   - **Dismissed** — a lane raised it, you checked, it does not hold.
   Each entry carries a one-line reason and its source lanes. Dismissed items
   stay visible (never silently dropped) so the reader can overrule you.
8. **Agreement map**: one short table or list of where the seated lanes agreed,
   where they diverged, and where only one lane spoke (a lone voice is not
   wrong, but it is unconfirmed). It summarizes the pattern across lanes; the
   per-finding detail stays in Findings.

Security-shaped findings (auth, injection, secrets, crypto) are LISTED but
not adjudicated here — route them to `security-reviewer` (the
no-double-reporting contract in agents/code-reviewer.md applies to the
council too). Dispatch that security lens at `effort: high` (advisory;
`docs/model-routing.md` → The effort axis).

### 5. Report

The report header is produced mechanically, never composed by hand. Pass the capture
path of every lane that ran (each `call-worker.sh` stdout line):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/review-evidence.py" summary <capture paths>
```

Paste its output verbatim at the top of the report. When no external-vendor lane
returned `complete`, its first line is `single-vendor review — not a council (no
external lane returned)` — keep it; the Claude lane always runs but must not borrow
the council's authority. Absent lanes (no capture) are appended by hand as
`<lane> ✗ absent (<reason>)`.

```
## Council review — <target>
<review-evidence.py summary output: [single-vendor warning,] Lane status: ...>
Citation drops: codex 1, gemini 0

### Agreement map             ...  agreed / diverged / single-lane
### High-signal (≥2 vendors)  ...
### Findings                  ...  grouped Act on / Consider / Noted / Dismissed;
                                  each: severity · [sources] · file:line · reason
### Disagreements             ...
```

The commit gate (`core/git-hooks/pre-commit`) blocks risk-area commits that have no
external `complete` review bound to the staged content; the user-only escape
`AGENT_REVIEW_OVERRIDE` is never set by an agent. Risk-area classes, the merge exemption
and the gate's stated limits: `${CLAUDE_PLUGIN_ROOT}/skills/council-review/reference.md`.

### 5.5. Record the outcome

After synthesis, append ONE line to `~/.agent/logs/review-outcomes.jsonl` (`$AGENT_LOGS_DIR`
moves the directory; best-effort, a failed append never changes the report). Labels and
counts only — no finding text, no code, no paths:

```bash
OUT_DIR="${AGENT_LOGS_DIR:-$HOME/.agent/logs}"
( umask 077
  mkdir -p "$OUT_DIR" &&
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg dk "$DK" --arg av "${AGENT_AUTHOR_VENDOR:-}" --argjson lanes "$LANES" \
    '{ts:$ts, diff_key:($dk|if .=="" then null else . end), author_vendor:($av|if .=="" then null else . end), lanes:$lanes}' \
    >> "$OUT_DIR/review-outcomes.jsonl" ) 2>/dev/null || true
```

`author_vendor` is the comma list `author-vendor` printed (e.g. `anthropic,openai`), kept
as is.

`$LANES` = one entry per lane, the Claude lane included, e.g. `{"lane":"second-opinion-review",
"vendor":"openai","status":"complete","raised":4,"accepted":2,"rejected":2}`: `raised` = findings
the lane returned, `accepted` = kept (Act on / Consider / Noted), `rejected` = dropped by the
citation check or Dismissed. An absent lane keeps its status, with zeros.

### 6. Clear the council-active flag

The flag set in step 0.5 must not outlive this run — a still-fresh flag left
behind would silently un-gate any LATER, unrelated council-scale diff for the
rest of its TTL. Clear it once the report above is produced, whether the run
succeeded or degraded:

```bash
CEG="${CLAUDE_PLUGIN_ROOT}/core/hooks/council-escalation-gate.py"
python3 "$CEG" --council-flag clear
```

## Degradation

| Signal | Meaning | Action |
|---|---|---|
| call-worker exit 3 | not approved: no `AGENT_WORKER_YES=1`, or the policy said no / failed closed | ask once (step 2, the user's money decision) and re-run with YES, or drop the lane |
| exit 127 / `status: unavailable` | lane disabled, CLI or preflight missing, capped by the policy, or the author's own vendor | lane absent, quote reason |
| exit 124 / `status: timeout` | hung CLI killed | lane absent |
| exit 1 / `status: rate-limited` | vendor quota/rate limit hit (e.g. the Antigravity account quota) | lane absent — fail-open; report "rate-limited, retry later", never an upgrade pitch |
| exit 1 / `status: failed` | backend errored | lane absent, quote stderr tail |

External failures never abort the review — the Claude lane carries it.

## Credits

The action buckets and agreement map adapt the synthesis step of the
`interrogate` skill in cursor/plugins (pstack, MIT); the spec axis adapts
`engineering/code-review` in mattpocock/skills (MIT). Rewritten in this repo's
own words.
