#!/usr/bin/env bash
# loop-run.sh — P2-1 + P2-4 + O-2 (impl): the autonomous-loop mechanical runner.
#
# §5 (docs/harness-improvement-plan.md) describes a loop that iterates: pick an
# idea, edit ONE target, commit, grade, keep-or-discard, repeat until a cap /
# timeout / circuit-breaker stops it. This script is the SOLE place that
# enforcement lives — skills/loop and skills/harness-loop are thin callers that
# read its output and act on it (git reset on discard, etc.); no machinery is
# duplicated in either skill.
#
# Building blocks REUSED, not rebuilt (D1/D3, design 2026-08-10):
#   - core/tests/grade.sh          the grader (attempt's default backend)
#   - core/infra/loop-ledger.sh    the ONLY sanctioned .agent/loop/results.tsv writer
#   - core/infra/supervisor-goal.sh  SQLite goal state = the attempt-cap SSOT
#     (`init <slug> <cap>` treats attempts as waves; `advance-wave` runs once per
#     attempt; `abort <slug> circuit-breaker` on breaker trip; `status` is what
#     makes a fresh invocation resume attempt numbering after a restart — nothing
#     about this script is stateful in-process, it reads/writes disk every call).
#   - core/hooks/loop-write-guard.py's own default flag path
#     ($REPO_ROOT/.agent/loop/active, env AGENT_LOOP_FLAG) — init creates it,
#     stop/cap/circuit-breaker remove it, so the write-guard hook is live exactly
#     while a loop is active.
#
# What SQLite (supervisor-goal.sh) cannot hold goes in a JSON state file at
# .agent/loop/state/<slug>.json: {slug, mission, target_regex, base_ref, branch,
# cap, timeout_s, best_score, consecutive_gate_failures, status, updated_at}.
# best_score starts at -1 (sentinel below every real grade.sh score) so the first
# non-gate-failing attempt is always "an improvement". status is
# active -> stopped (cap reached, or an explicit `stop`) | aborted (circuit
# breaker); attempt refuses once status != active.
#
# Git is explicitly OUT of scope here (D1): keeping/discarding a candidate commit
# (`git reset --hard`) is a SKILL step (§5.2 step 8) done by the caller who reads
# this script's verdict — this script only records what happened.
#
# Subcommands:
#   init <slug> --target <regex> --base <ref> [--branch <b>] [--cap N]
#        [--timeout-s N] [--mission <text>]
#     cap defaults to 5 (attempts), timeout-s to 600 (10 min, §5.3), branch
#     defaults to harness-loop/<slug>. Fails if the slug's goal already exists
#     (supervisor-goal.sh init refuses on a duplicate plan_slug — clear it first).
#
#   status <slug>
#     Prints the state json, the goal json (supervisor-goal.sh status), and the
#     ledger's last 5 rows. This triple is the resume entrypoint after a restart.
#
#   attempt <slug> --desc "<=80 chars" [--keep-tie]
#     Pre-checks: state exists and is active, attempt cap not yet reached,
#     circuit breaker not already tripped. Runs the grader (default:
#     `grade.sh --base <base> --target <target>`; LOOP_RUN_GRADE_CMD overrides
#     the whole command for stubbing) in the background under a watchdog that
#     TERMs then KILLs at LOOP_RUN_TIMEOUT_S (falls back to the state's
#     timeout_s). Classifies the run:
#       timeout  — watchdog fired (TERM/KILL exit code)          -> discard
#       crash    — no `^harness_score:` line in the run log      -> discard
#       score 0  — grade.sh's own fail-closed value (GATE/TARGET/rubric
#                  failure) -> discard, counts toward the circuit breaker
#       score >0 — kept iff strictly better than best_score, or tied AND
#                  --keep-tie was passed (§5.1 simplicity rule, generalized:
#                  the loop caller decides tie-keeping, not this script)
#     Appends exactly one ledger row via loop-ledger.sh regardless of outcome,
#     advances the goal wave, and prints a final `LOOP: continue` or
#     `LOOP: stop(cap|circuit-breaker)` line — the only line callers should grep
#     for the verdict (informational lines use the `ATTEMPT:` prefix instead).
#     Two consecutive score-0 attempts trip the breaker: `supervisor-goal.sh
#     abort <slug> circuit-breaker`, state -> aborted, active flag removed.
#     Reaching the cap on this attempt: state -> stopped, active flag removed.
#
#   stop <slug> [reason]
#     Completes (no reason) or aborts (with reason) the goal, marks the state
#     stopped, and removes the active flag. For an explicit human/skill stop
#     before the cap or breaker would otherwise end the loop.
#
# Test seams:
#   LOOP_RUN_GRADE_CMD   overrides the attempt grader command (a shell command
#                        string, run via `bash -c "exec <cmd>"` so the watchdog's
#                        kill lands on the real process, not a wrapping shell).
#   LOOP_RUN_TIMEOUT_S   overrides the per-attempt timeout (else state's timeout_s).
#   AGENT_LOOP_FLAG      overrides the active-flag path (shared seam with
#                        core/hooks/loop-write-guard.py).
#   AGENT_LOOP_LEDGER    overrides the ledger path (shared seam with
#                        core/infra/loop-ledger.sh — untouched here, just inherited).
#
# set -u only (not -e/pipefail): this script branches on the exit code of grep,
# jq, and background processes throughout (grep no-match, a killed watchdog
# process, …), which are ROUTINE outcomes here, not bugs — matching
# core/infra/loop-ledger.sh's own header, which this script's style follows.
set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOOP_DIR="$REPO_ROOT/.agent/loop"
STATE_DIR="$LOOP_DIR/state"
ACTIVE_FLAG="${AGENT_LOOP_FLAG:-$LOOP_DIR/active}"
SUPERVISOR_GOAL="$REPO_ROOT/core/infra/supervisor-goal.sh"
LOOP_LEDGER="$REPO_ROOT/core/infra/loop-ledger.sh"
GRADE_SH="$REPO_ROOT/core/tests/grade.sh"

for c in jq sqlite3 git awk; do
  command -v "$c" >/dev/null 2>&1 || { echo "loop-run: $c missing. Install it (e.g. brew install $c)" >&2; exit 127; }
done

die() { printf 'loop-run: %s\n' "$1" >&2; exit 1; }

_state_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }

# float-safe numeric helpers (bash has no float arithmetic; grade.sh scores are
# X.Y). Exit-code convention: 0 = true, matching bash `if` usage.
_score_is_zero() { awk -v a="$1" 'BEGIN{exit !(a+0==0)}'; }
_score_gt()      { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }
_score_eq()      { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0==b+0)}'; }

_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# _write_state <slug> <best_score> <consecutive_gate_failures> <status> — the
# only writer of state/<slug>.json past init. Read-modify-write via jq so
# fields init wrote (mission/target_regex/base_ref/branch/cap/timeout_s) are
# never clobbered; write via tmp+mv so a crash mid-write can't corrupt it.
_write_state() {
  local slug="$1" best="$2" gate_fails="$3" status="$4"
  local sf; sf="$(_state_file "$slug")"
  local tmp; tmp="$(mktemp "$STATE_DIR/.tmp.XXXXXX")" || die "cannot create temp state file"
  jq --argjson best "$best" --argjson gf "$gate_fails" --arg status "$status" --arg ts "$(_now_iso)" \
     '.best_score = $best | .consecutive_gate_failures = $gf | .status = $status | .updated_at = $ts' \
     "$sf" > "$tmp" && mv "$tmp" "$sf"
}

# _halt <slug> <best> <gate_fails> <msg> — a write the stop conditions depend on
# failed. Fail CLOSED: mark the loop aborted, drop the active flag, and emit a
# stop verdict, so a broken counter or ledger cannot degrade into an unbounded
# run. Never called for ordinary attempt outcomes — only for infrastructure
# failures the loop cannot safely continue past.
_halt() {
  local slug="$1" best="$2" gate_fails="$3" msg="$4"
  printf 'loop-run: FATAL: %s\n' "$msg" >&2
  bash "$SUPERVISOR_GOAL" abort "$slug" runner-error >/dev/null 2>&1 || true
  _write_state "$slug" "$best" "$gate_fails" "aborted" || true
  rm -f "$ACTIVE_FLAG"
  echo "LOOP: stop(error)"
  exit 1
}

usage() {
  cat >&2 <<'EOF'
loop-run.sh — autonomous-loop mechanical runner (P2-1/P2-4/O-2)

Commands:
  init <slug> --target <regex> --base <ref> [--branch <b>] [--cap N]
       [--timeout-s N] [--mission <text>]
  status <slug>
  attempt <slug> --desc "<=80 chars" [--keep-tie]
  stop <slug> [reason]
EOF
}

cmd_init() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || { usage; exit 2; }
  shift
  local target="" base="" branch="" cap=5 timeout_s=600 mission="$slug"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)     target="${2:-}"; shift 2 ;;
      --base)       base="${2:-}"; shift 2 ;;
      --branch)     branch="${2:-}"; shift 2 ;;
      --cap)        cap="${2:-}"; shift 2 ;;
      --timeout-s)  timeout_s="${2:-}"; shift 2 ;;
      --mission)    mission="${2:-}"; shift 2 ;;
      *) die "init: unknown argument: $1" ;;
    esac
  done
  [[ -n "$target" && -n "$base" ]] || die "init requires --target <regex> and --base <ref>"
  [[ "$cap" =~ ^[0-9]+$ && "$cap" -gt 0 ]] || die "--cap must be a positive integer (got '$cap')"
  [[ "$timeout_s" =~ ^[0-9]+$ && "$timeout_s" -gt 0 ]] || die "--timeout-s must be a positive integer (got '$timeout_s')"
  [[ -n "$branch" ]] || branch="harness-loop/$slug"

  mkdir -p "$STATE_DIR" "$LOOP_DIR" || die "cannot create $STATE_DIR"

  local sf; sf="$(_state_file "$slug")"
  [[ -f "$sf" ]] && die "state already exists for '$slug' at $sf — stop it or remove the file first"

  if ! bash "$SUPERVISOR_GOAL" init "$slug" "$cap" "" "$mission" >/dev/null 2>&1; then
    die "supervisor-goal.sh init failed for '$slug' (already exists? \`bash $SUPERVISOR_GOAL clear $slug\` to reset)"
  fi

  jq -n --arg slug "$slug" --arg mission "$mission" --arg target "$target" \
        --arg base "$base" --arg branch "$branch" --argjson cap "$cap" \
        --argjson timeout_s "$timeout_s" --arg ts "$(_now_iso)" \
    '{slug: $slug, mission: $mission, target_regex: $target, base_ref: $base,
      branch: $branch, cap: $cap, timeout_s: $timeout_s, best_score: -1,
      consecutive_gate_failures: 0, status: "active", updated_at: $ts}' > "$sf" \
    || die "cannot write state file $sf"

  : > "$ACTIVE_FLAG" || die "cannot create active flag $ACTIVE_FLAG"

  echo "loop-run: initialized '$slug' (cap=$cap timeout_s=${timeout_s}s target='$target' base=$base branch=$branch)" >&2
  cat "$sf"
}

cmd_status() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || { usage; exit 2; }
  local sf; sf="$(_state_file "$slug")"
  [[ -f "$sf" ]] || die "status: unknown slug '$slug' (no state file at $sf)"
  echo "=== state ==="
  cat "$sf"
  echo
  echo "=== goal ==="
  bash "$SUPERVISOR_GOAL" status "$slug" 2>&1
  echo
  echo "=== ledger (tail) ==="
  local ledger; ledger="$(bash "$LOOP_LEDGER" path)"
  if [[ -f "$ledger" ]]; then tail -n 5 "$ledger"; else echo "(no ledger yet)"; fi
}

cmd_attempt() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || { usage; exit 2; }
  shift
  local desc="" keep_tie=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --desc)      desc="${2:-}"; shift 2 ;;
      --keep-tie)  keep_tie=1; shift ;;
      *) die "attempt: unknown argument: $1" ;;
    esac
  done
  [[ -n "$desc" ]] || die "attempt requires --desc <text>"
  [[ "${#desc}" -le 80 ]] || die "attempt: --desc must be <=80 chars (got ${#desc})"

  local sf; sf="$(_state_file "$slug")"
  [[ -f "$sf" ]] || die "attempt: unknown slug '$slug' (no state file at $sf; run init first)"

  local state; state="$(cat "$sf")"
  local st; st="$(jq -r '.status' <<<"$state")"
  [[ "$st" == "active" ]] || die "attempt: slug '$slug' is not active (status=$st) — refusing"

  local cap timeout_s target base best_score gate_fails
  cap="$(jq -r '.cap' <<<"$state")"
  timeout_s="${LOOP_RUN_TIMEOUT_S:-$(jq -r '.timeout_s' <<<"$state")}"
  target="$(jq -r '.target_regex' <<<"$state")"
  base="$(jq -r '.base_ref' <<<"$state")"
  best_score="$(jq -r '.best_score' <<<"$state")"
  gate_fails="$(jq -r '.consecutive_gate_failures' <<<"$state")"
  [[ "$gate_fails" -lt 2 ]] || die "attempt: slug '$slug' already tripped the circuit breaker — refusing"

  local goal_json current_wave total_waves goal_status
  goal_json="$(bash "$SUPERVISOR_GOAL" status "$slug" 2>/dev/null)"
  current_wave="$(jq -r '.current_wave // empty' <<<"$goal_json")"
  total_waves="$(jq -r '.total_waves // empty' <<<"$goal_json")"
  goal_status="$(jq -r '.status // empty' <<<"$goal_json")"
  [[ -n "$current_wave" && -n "$total_waves" ]] || die "attempt: could not read goal state for '$slug'"
  # The goal DB is the SSOT for whether this loop may run; the local JSON above
  # is only a cache of it. Gating on the cache alone meant a loop the circuit
  # breaker had already aborted could be resurrected by hand-editing one
  # untracked file (.agent/loop/state/<slug>.json) while the DB still read
  # "aborted". Check the authority itself, and refuse when the two disagree
  # rather than picking the more permissive one.
  [[ -n "$goal_status" ]] || die "attempt: could not read goal status for '$slug'"
  [[ "$goal_status" == "active" ]] || die "attempt: goal state for '$slug' is '$goal_status', not active — refusing (the local state file is a cache, not the authority)"
  [[ "$current_wave" -le "$total_waves" ]] || die "attempt: slug '$slug' already reached its attempt cap ($total_waves) — refusing"

  local n="$current_wave"
  local log="$LOOP_DIR/run-$slug-$n.log"
  mkdir -p "$LOOP_DIR"

  local grade_cmd
  if [[ -n "${LOOP_RUN_GRADE_CMD:-}" ]]; then
    grade_cmd=(bash -c "exec $LOOP_RUN_GRADE_CMD")
  else
    grade_cmd=(bash "$GRADE_SH" --base "$base" --target "$target")
  fi

  local start_ts end_ts duration rc pid wpid
  start_ts="$(date +%s)"
  "${grade_cmd[@]}" > "$log" 2>&1 &
  pid=$!
  # Watchdog's own fds are redirected (not inherited): `kill "$wpid"` below
  # terminates the watchdog SUBSHELL, not the `sleep` it forked (a separate
  # process) — an uncancelled sleep would otherwise orphan and keep holding
  # this script's stdout/stderr open for the rest of its duration, which
  # hangs any caller capturing our output via `$(...)` (command substitution
  # only returns once every writer of the pipe has closed it).
  ( sleep "$timeout_s"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wpid=$!
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  end_ts="$(date +%s)"
  duration=$((end_ts - start_ts))

  local commit; commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)"
  [[ -n "$commit" ]] || commit="-"

  local run_status score reason
  score=""
  if [[ $rc -eq 143 || $rc -eq 137 ]]; then
    run_status="timeout"
    reason="killed at timeout (${timeout_s}s)"
  else
    score="$(grep '^harness_score:' "$log" 2>/dev/null | tail -n1 | awk '{print $2}')"
    if [[ -z "$score" ]]; then
      run_status="crash"
      reason="no harness_score line in $log — tail: $(tail -n 3 "$log" 2>/dev/null | tr '\n' ' ')"
    elif _score_is_zero "$score"; then
      run_status="discard"
      gate_fails=$((gate_fails + 1))
      reason="GATE/boundary failure (harness_score: $score)"
    else
      gate_fails=0
      if _score_gt "$score" "$best_score" || { [[ "$keep_tie" -eq 1 ]] && _score_eq "$score" "$best_score"; }; then
        run_status="keep"
        reason="improved over best ($best_score)"
        best_score="$score"
      else
        run_status="discard"
        reason="not an improvement over best ($best_score)"
      fi
    fi
  fi
  [[ -n "$score" ]] || score=0

  # Both writes below are load-bearing for STOPPING, so neither may fail quietly.
  # As warnings they were fail-OPEN in the worst direction: advance-wave is the
  # only thing that increments the wave counter, and the next attempt re-reads
  # that counter to decide the cap — so a failed write (locked or read-only DB)
  # meant n never advanced, `$((n+1)) -gt $cap` never fired, and the loop ran
  # unbounded while still printing `LOOP: continue`. A dropped ledger append is
  # the audit-trail equivalent: a verdict the caller trusts that was never
  # durably recorded. Halt instead, with the loop marked aborted, so the failure
  # needs a human rather than silently removing the stop condition.
  if ! bash "$LOOP_LEDGER" append --commit "$commit" --score "$score" --duration "$duration" \
       --status "$run_status" --desc "$desc"; then
    _halt "$slug" "$best_score" "$gate_fails" \
      "ledger append failed for attempt $n — outcome not durably recorded"
  fi

  if ! bash "$SUPERVISOR_GOAL" advance-wave "$slug" "$n" >/dev/null 2>&1; then
    _halt "$slug" "$best_score" "$gate_fails" \
      "advance-wave failed for attempt $n — the wave counter did not advance, so the attempt cap can no longer stop this loop"
  fi

  echo "ATTEMPT: n=$n status=$run_status score=$score commit=$commit duration_s=$duration desc=\"$desc\""
  echo "ATTEMPT: reason: $reason"

  local final_status="active" verdict
  if [[ "$gate_fails" -ge 2 ]]; then
    bash "$SUPERVISOR_GOAL" abort "$slug" circuit-breaker >/dev/null 2>&1
    final_status="aborted"
    rm -f "$ACTIVE_FLAG"
    verdict="stop(circuit-breaker)"
  elif [[ $((n + 1)) -gt "$cap" ]]; then
    bash "$SUPERVISOR_GOAL" complete "$slug" >/dev/null 2>&1
    final_status="stopped"
    rm -f "$ACTIVE_FLAG"
    verdict="stop(cap)"
  else
    verdict="continue"
  fi

  _write_state "$slug" "$best_score" "$gate_fails" "$final_status"
  echo "LOOP: $verdict"
}

cmd_stop() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || { usage; exit 2; }
  local reason="${2:-}"
  local sf; sf="$(_state_file "$slug")"
  [[ -f "$sf" ]] || die "stop: unknown slug '$slug' (no state file at $sf)"

  if [[ -n "$reason" ]]; then
    bash "$SUPERVISOR_GOAL" abort "$slug" "$reason" >/dev/null 2>&1
  else
    bash "$SUPERVISOR_GOAL" complete "$slug" >/dev/null 2>&1
  fi

  local best gate_fails
  best="$(jq -r '.best_score' "$sf")"
  gate_fails="$(jq -r '.consecutive_gate_failures' "$sf")"
  _write_state "$slug" "$best" "$gate_fails" "stopped"
  rm -f "$ACTIVE_FLAG"
  echo "loop-run: stopped '$slug'${reason:+ ($reason)}"
}

case "${1:-}" in
  init)    shift; cmd_init "$@" ;;
  status)  shift; cmd_status "$@" ;;
  attempt) shift; cmd_attempt "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  *) usage; exit 2 ;;
esac
