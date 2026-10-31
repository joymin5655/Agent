#!/usr/bin/env bash
# council-escalation-gate-test.sh — verify core/hooks/council-escalation-gate.py.
#
# PreToolUse Task|Agent gate: denies a plain `code-reviewer` dispatch when
# core/infra/council-threshold.sh judges the repo's staged diff council-scale
# (line/file threshold or a risk-area path), pointing the caller at
# `/council-review --staged` instead. Every other case is silent (empty
# stdout, allow) — non-dispatch tools, non-Task/Agent, non-code-reviewer
# subagents, and small diffs never fire.
#
# Escape-hatch state (the council-active flag and the deny ledger) lives
# OUTSIDE the reviewed repo (2026-08-21 security fix, F2) — this fixture
# points AGENT_COUNCIL_STATE_DIR at a throwaway dir under WORK so the state
# never touches $REPO, and so a hostile in-repo `.agent/state/council-active`
# file (tested explicitly below) can never be read as trusted state.
#
# Two reset helpers, used deliberately differently across sections:
#   reset_repo()           — git worktree/index back to baseline AND wipes
#                             $STATE_DIR. Use between INDEPENDENT sub-cases.
#   reset_worktree_only()  — git worktree/index only; $STATE_DIR (the deny
#                             ledger, the flag) persists. Use when a test is
#                             specifically checking that persisted state
#                             behaves correctly across two dispatches.
#
# Pattern: model-routing-advisor-test.sh (expect_silent/expect_deny helpers,
# PreToolUse JSON on stdin) + council-threshold-test.sh's git fixture.
#
# Usage: bash core/tests/council-escalation-gate-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u
# X-5: this battery reads the project-local sink, so the run-wide redirect must not apply.
unset AGENT_GATE_SINK_DIR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${COUNCIL_GATE_HOOK_UNDER_TEST:-$REPO_ROOT/core/hooks/council-escalation-gate.py}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 — $2"; }
skip() { echo "  SKIP  $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
STATE_DIR="$WORK/state"
mkdir -p "$REPO"

git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "test"
echo "baseline" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "baseline"

reset_repo() {
  git -C "$REPO" reset --hard -q HEAD
  git -C "$REPO" clean -fdq
  rm -rf "$REPO/.agent"
  rm -rf "$STATE_DIR"
}

reset_worktree_only() {
  git -C "$REPO" reset --hard -q HEAD
  git -C "$REPO" clean -fdq
  rm -rf "$REPO/.agent"
  # $STATE_DIR deliberately NOT touched — the deny ledger / flag persists.
}

gen_lines() { local n="$1"; for ((i = 0; i < n; i++)); do echo "line $i"; done; }

stage_large_diff() {
  # .dat, not .txt: .txt is docs-shaped and no longer counts toward the council size signal
  gen_lines 250 > "$REPO/big.dat"
  git -C "$REPO" add big.dat
}

stage_small_diff() {
  echo "a small tweak" >> "$REPO/README.md"
  git -C "$REPO" add README.md
}

evt() {  # evt <tool_name> <subagent_type> [cwd]
  if [[ -n "${3:-}" ]]; then
    printf '{"event":"PreToolUse","tool_name":"%s","cwd":"%s","tool_input":{"subagent_type":"%s","prompt":"x"}}' "$1" "$3" "$2"
  else
    printf '{"event":"PreToolUse","tool_name":"%s","tool_input":{"subagent_type":"%s","prompt":"x"}}' "$1" "$2"
  fi
}

evt_p() {  # evt_p <tool_name> <subagent_type> <prompt> (prompt: no quotes/backslashes)
  printf '{"event":"PreToolUse","tool_name":"%s","tool_input":{"subagent_type":"%s","prompt":"%s"}}' "$1" "$2" "$3"
}

# run <json> -> OUT, RC (cwd = fixture repo, so repo_root() resolves there).
# AGENT_COUNCIL_STATE_DIR pins escape-hatch state to the throwaway fixture
# dir; CLAUDE_PROJECT_DIR/AGENT_PROJECT_DIR are explicitly unset so a value
# leaking from the outer session can never override repo_root()'s cwd fallback.
run() {
  OUT="$(cd "$REPO" && env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
      printf '%s' "$1" | env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
      python3 "$HOOK" 2>"$WORK/stderr.log")"
  RC=$?
}

# CLI helpers for the --council-flag set|clear escape hatch.
flag_set() {
  (cd "$REPO" && env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
      python3 "$HOOK" --council-flag set) 2>"$WORK/cli-stderr.log"
}
flag_clear() {
  (cd "$REPO" && env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
      python3 "$HOOK" --council-flag clear) 2>"$WORK/cli-stderr.log"
}

expect_silent() {
  local name="$1" json="$2"
  run "$json"
  if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "$name"; else bad "$name" "rc=$RC out='$OUT'"; fi
}

expect_deny() {
  local name="$1" json="$2"
  run "$json"
  if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" == *"council-review"* ]]; then
    ok "$name"
  else
    bad "$name" "rc=$RC out='$OUT'"
  fi
}

# Unique wording of ESCAPE_CLOSED_REASON (the "pass could not be recorded" refusal).
CLOSED_PHRASE="could not be recorded safely"

# run_timed <json> [ENV=val ...] -> OUT, RC (124 = the hook ran past 10s and was killed).
RUN_LIMIT_PY='
import subprocess, sys
try:
    p = subprocess.run([sys.executable, sys.argv[1]], stdin=sys.stdin, capture_output=True, text=True, timeout=10)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.stdout.write(p.stdout)
sys.exit(p.returncode)
'
run_timed() {
  local json="$1"; shift
  OUT="$(cd "$REPO" && printf '%s' "$json" \
      | env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" "$@" \
        python3 -c "$RUN_LIMIT_PY" "$HOOK" 2>/dev/null)"
  RC=$?
}

# Another process holding the ledger lock: writes a ready file once it holds it,
# and lives until stop_lock_holder (hard cap 60s so it can never outlive the run).
start_lock_holder() {  # start_lock_holder <ledger-dir>
  LOCK_READY="$WORK/lock-ready"
  rm -f "$LOCK_READY"
  python3 - "$1/escaped.lock" "$LOCK_READY" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "a+")
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(60)
PY
  HOLDER=$!
  for _ in $(seq 1 50); do [[ -e "$LOCK_READY" ]] && break; sleep 0.1; done
}
stop_lock_holder() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }

echo "=== small diff: code-reviewer dispatch is silent (not council-scale) ==="
reset_repo
stage_small_diff
expect_silent "a1-small-diff-silent" "$(evt Task code-reviewer)"

echo
echo "=== large diff: code-reviewer dispatch is denied ==="
# Each sub-case resets first (reset_repo wipes $STATE_DIR too) — the
# same-diff-hash escape (tested separately below) would otherwise turn
# b2/b3 into "already denied" retries instead of the fresh first-denial
# this section is checking.
reset_repo; stage_large_diff
expect_deny "b1-large-diff-denied" "$(evt Task code-reviewer)"
reset_repo; stage_large_diff
expect_deny "b2-large-diff-denied-agent-tool" "$(evt Agent code-reviewer)"
reset_repo; stage_large_diff
expect_deny "b3-namespaced-code-reviewer-denied" "$(evt Task agent-harness:code-reviewer)"

echo
echo "=== council-active flag (via --council-flag CLI): escape 1 -> silent ==="
reset_repo
stage_large_diff
flag_set
expect_silent "c1-council-active-silent" "$(evt Task code-reviewer)"

echo "=== council-active flag: stale (TTL 0) -> denies again ==="
reset_repo
stage_large_diff
flag_set
OUT="$(cd "$REPO" && env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
    printf '%s' "$(evt Task code-reviewer)" \
    | env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" AGENT_COUNCIL_ACTIVE_TTL_S=0 python3 "$HOOK" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "c2-stale-flag-denies"
else
  bad "c2-stale-flag-denies" "rc=$RC out='$OUT'"
fi

echo "=== forged in-repo flag (.agent/state/council-active): ignored, still denies ==="
# F2: escape-hatch state must not be trusted from inside the reviewed
# workspace. A cloned/unpacked repo can ship this exact path with a fresh
# mtime (git sets mtime on checkout) — the gate must not read it at all.
reset_repo
stage_large_diff
mkdir -p "$REPO/.agent/state"
touch "$REPO/.agent/state/council-active"
expect_deny "c3-forged-in-repo-flag-ignored" "$(evt Task code-reviewer)"

echo "=== flag set via CLI silences, clear via CLI restores deny ==="
reset_repo
stage_large_diff
flag_set
expect_silent "c4a-flag-set-silences" "$(evt Task code-reviewer)"
flag_clear
expect_deny "c4b-flag-clear-restores-deny" "$(evt Task code-reviewer)"

echo "=== flag bound to a different diff: no blanket bypass ==="
reset_repo
stage_large_diff
flag_set                      # flag content = hash(diff A, the 250-line add)
reset_worktree_only           # ledger/flag persist; git tree resets
mkdir -p "$REPO/secrets"
echo "TOKEN=x" > "$REPO/secrets/prod.env"
git -C "$REPO" add secrets/prod.env   # diff B — different hash, still council-scale (risk path)
expect_deny "c5-flag-diff-mismatch-denies" "$(evt Task code-reviewer)"

echo
echo "=== same-diff-hash single-deny: escape 2 (requires stated reason) ==="
REASON_PROMPT='review it. council-unavailable: no worker CLI installed on this host'
reset_repo
stage_large_diff
run "$(evt Task code-reviewer)"
first_deny_ok=0
[[ "$RC" -eq 0 && "$OUT" == *"deny"* ]] && first_deny_ok=1
# 2026-10-01: a bare identical retry is denied again (the old escape let it
# through and models retried reflexively without trying council-review).
run "$(evt Task code-reviewer)"
if [[ "$first_deny_ok" -eq 1 && "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "d1-bare-retry-same-diff-denied-again"
else
  bad "d1-bare-retry-same-diff-denied-again" "first=$first_deny_ok rc=$RC out='$OUT'"
fi
if [[ "$OUT" == *"council-unavailable"* ]]; then
  ok "d1a-deny-text-names-reason-marker"
else
  bad "d1a-deny-text-names-reason-marker" "$OUT"
fi
run "$(evt_p Task code-reviewer 'council-unavailable: short')"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "d1b-too-short-reason-denied"
else
  bad "d1b-too-short-reason-denied" "rc=$RC out='$OUT'"
fi
run "$(evt_p Task code-reviewer 'council-unavailable: x            ')"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "d1b2-whitespace-padded-reason-denied"
else
  bad "d1b2-whitespace-padded-reason-denied" "rc=$RC out='$OUT'"
fi
run "$(evt_p Task code-reviewer 'council-unavailable: <concrete reason>')"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "d1b3-pasted-placeholder-denied"
else
  bad "d1b3-pasted-placeholder-denied" "rc=$RC out='$OUT'"
fi
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
# The escape emits a PreToolUse additionalContext advisory, never a decision.
if [[ "$RC" -eq 0 && "$OUT" == *"additionalContext"* && "$OUT" != *"permissionDecision"* ]] \
   && grep -q "loop-safety escape" "$WORK/stderr.log" \
   && grep -q "no worker CLI installed" "$WORK/stderr.log"; then
  ok "d1c-retry-with-reason-allowed-with-advisory"
else
  bad "d1c-retry-with-reason-allowed-with-advisory" "rc=$RC out='$OUT' stderr=$(cat "$WORK/stderr.log" 2>/dev/null)"
fi
if [[ "$OUT" == *"council-review"* ]]; then
  ok "d1d-escape-advisory-recommends-council-review"
else
  bad "d1d-escape-advisory-recommends-council-review" "$OUT"
fi
if grep -q "stated reason: no worker CLI installed" "$REPO/.agent/logs/security-violations.jsonl" 2>/dev/null; then
  ok "d1e-stated-reason-written-to-audit-sink"
else
  bad "d1e-stated-reason-written-to-audit-sink" "$(tail -n 2 "$REPO/.agent/logs/security-violations.jsonl" 2>/dev/null)"
fi
reset_repo
stage_large_diff
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "d1f-reason-on-first-dispatch-still-denied"
else
  bad "d1f-reason-on-first-dispatch-still-denied" "rc=$RC out='$OUT'"
fi

echo "=== a genuinely different diff after a deny is denied again (hash changed) ==="
# reset_worktree_only (NOT reset_repo) between the two dispatches — the
# ledger from the first denial must survive into the second check, so this
# test actually exercises hash-specific dedup instead of passing vacuously
# because the ledger got wiped between sub-cases (the bug this rewrite
# fixes: reset_repo used to also delete the (then in-repo) ledger).
reset_repo
stage_large_diff
run "$(evt Task code-reviewer)"
first_ok=$([[ "$OUT" == *"deny"* ]] && echo 1 || echo 0)
reset_worktree_only
mkdir -p "$REPO/secrets"
echo "TOKEN=x" > "$REPO/secrets/prod.env"
git -C "$REPO" add secrets/prod.env
run "$(evt Task code-reviewer)"
if [[ "$first_ok" -eq 1 && "$RC" -eq 0 && "$OUT" == *"deny"* ]]; then
  ok "d2-different-diff-denied-independently"
else
  bad "d2-different-diff-denied-independently" "first_ok=$first_ok rc=$RC out='$OUT'"
fi

echo "=== deny ledger entry past AGENT_COUNCIL_DENY_TTL_S: denies again (not an escape) ==="
reset_repo
stage_large_diff
run "$(evt Task code-reviewer)"   # first deny -> ledger entry ts=now
first_ok=$([[ "$OUT" == *"deny"* ]] && echo 1 || echo 0)
OUT="$(cd "$REPO" && env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
    printf '%s' "$(evt Task code-reviewer)" \
    | env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" AGENT_COUNCIL_DENY_TTL_S=0 python3 "$HOOK" 2>/dev/null)"; RC=$?
if [[ "$first_ok" -eq 1 && "$RC" -eq 0 && "$OUT" == *"deny"* ]]; then
  ok "d3-expired-ledger-entry-denies-again"
else
  bad "d3-expired-ledger-entry-denies-again" "first_ok=$first_ok rc=$RC out='$OUT'"
fi

echo
echo "=== event cwd resolution (F8): process cwd != event cwd, event cwd wins ==="
reset_repo
stage_large_diff
OUT="$(cd "$WORK" && env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
    printf '%s' "$(evt Task code-reviewer "$REPO")" \
    | env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" python3 "$HOOK" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "d4-event-cwd-resolves-repo-root"
else
  bad "d4-event-cwd-resolves-repo-root" "rc=$RC out='$OUT'"
fi

echo
echo "=== non-targets: silent regardless of diff size ==="
reset_repo
stage_large_diff
expect_silent "e1-non-dispatch-tool" '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
expect_silent "e2-write-tool" '{"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"x.py"}}'
expect_silent "e3-different-subagent" "$(evt Task general-purpose)"
expect_silent "e4-missing-subagent" '{"event":"PreToolUse","tool_name":"Task","tool_input":{"prompt":"x"}}'
expect_silent "e5-empty-subagent" '{"event":"PreToolUse","tool_name":"Task","tool_input":{"subagent_type":"","prompt":"x"}}'

echo
echo "=== fail-open: malformed / empty stdin never blocks ==="
OUT="$(cd "$REPO" && printf 'not json {[' | python3 "$HOOK" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "f1-malformed-stdin-silent-rc0"; else bad "f1-malformed" "rc=$RC out=$OUT"; fi
OUT="$(cd "$REPO" && printf '' | python3 "$HOOK" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "f2-empty-stdin-silent-rc0"; else bad "f2-empty-stdin" "rc=$RC out=$OUT"; fi

echo
echo "=== fail-open: broken threshold script never blocks ==="
reset_repo
stage_large_diff
BROKEN_HOOK_DIR="$WORK/broken-hook"
mkdir -p "$BROKEN_HOOK_DIR/core/infra" "$BROKEN_HOOK_DIR/core/hooks"
cp "$HOOK" "$BROKEN_HOOK_DIR/core/hooks/council-escalation-gate.py"
# no council-threshold.sh under $BROKEN_HOOK_DIR/core/infra/ -> bash exits
# 127 (script not found) rather than raising a Python exception, so this
# exercises the "threshold exit code other than 0/10" fail-open path, not
# F7's exception-logging path (see F7 note in the module docstring).
OUT="$(cd "$REPO" && python3 "$BROKEN_HOOK_DIR/core/hooks/council-escalation-gate.py" <<<"$(evt Task code-reviewer)" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then
  ok "g1-missing-threshold-script-fails-open"
else
  bad "g1-missing-threshold-script-fails-open" "rc=$RC out='$OUT'"
fi

echo
echo "=== F13: one repo, one state key (CLI and hook must agree) ==="
# The flag is written by the `--council-flag set` CLI and read by the hook.
# If those two spell the repo root differently, state_dir() keys them apart
# and the council's own escape hatch silently never opens. Two spellings that
# diverge in practice: a session whose cwd is a SUBDIRECTORY of the repo, and
# a checkout reached through a symlink (this fixture lives under macOS
# /var -> /private/var, so both halves are exercised at once).
reset_repo
stage_large_diff
SUBDIR="$REPO/pkg/deep"
mkdir -p "$SUBDIR"
(cd "$SUBDIR" && env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR AGENT_COUNCIL_STATE_DIR="$STATE_DIR" \
    python3 "$HOOK" --council-flag set) 2>"$WORK/cli-stderr.log"
expect_silent "h1-flag-set-in-subdir-opens-gate-for-subdir-cwd" "$(evt Task code-reviewer "$SUBDIR")"
# ...and clearing from the ROOT must kill a flag that was set from the subdir,
# or /council-review step 6 would leave a live flag behind for the whole TTL.
flag_clear
if [[ -n "$(find "$STATE_DIR" -name active -type f 2>/dev/null)" ]]; then
  bad "h2-clear-at-root-removes-subdir-flag" "an 'active' flag survived under $STATE_DIR"
else
  ok "h2-clear-at-root-removes-subdir-flag"
fi

echo
echo "=== W3: risk-area diff — council-unavailable escape is refused ==="
reset_repo
mkdir -p "$REPO/billing"; gen_lines 5 > "$REPO/billing/pay.py"
git -C "$REPO" add billing/pay.py
run "$(evt Task code-reviewer)"
[[ "$RC" -eq 0 && "$OUT" == *"deny"* ]] && ok "w3a-risk-first-dispatch-denied" || bad "w3a-risk-first-dispatch-denied" "rc=$RC out='$OUT'"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" == *"AGENT_REVIEW_OVERRIDE"* ]]; then
  ok "w3b-risk-escape-with-reason-still-denied"
else
  bad "w3b-risk-escape-with-reason-still-denied" "rc=$RC out='$OUT'"
fi
reset_repo
stage_large_diff
run "$(evt Task code-reviewer)"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" != *"permissionDecision"*"deny"* ]]; then
  ok "w3c-non-risk-escape-unchanged"
else
  bad "w3c-non-risk-escape-unchanged" "rc=$RC out='$OUT'"
fi

echo
echo "=== 2026-10-31: decision-id reasons refused; stated-reason pass is single-use per diff ==="
reset_repo
stage_large_diff
run "$(evt Task code-reviewer)"   # first deny records the hash
run "$(evt_p Task code-reviewer 'council-unavailable: per the user standing decision D-20261025-7d7f skip council')"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" == *"delegation decision id"* \
      && "$OUT" != *"re-issue"* ]]; then
  ok "t1-decision-id-reason-denied"
else
  bad "t1-decision-id-reason-denied" "rc=$RC out='$OUT'"
fi
if grep -q "cites a delegation decision id" "$REPO/.agent/logs/security-violations.jsonl"; then
  ok "t1b-decision-id-denial-logged"
else
  bad "t1b-decision-id-denial-logged" "no log record"
fi
# A refused id reason must not have spent the pass: a legitimate reason still passes once.
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"additionalContext"* && "$OUT" != *"permissionDecision"* ]]; then
  ok "t2-legit-reason-passes-once"
else
  bad "t2-legit-reason-passes-once" "rc=$RC out='$OUT'"
fi
if grep -q "same-diff-hash escape with stated reason: no worker CLI" "$REPO/.agent/logs/security-violations.jsonl"; then
  ok "t2b-pass-logged-with-reason"
else
  bad "t2b-pass-logged-with-reason" "no allow record"
fi
run "$(evt_p Task code-reviewer 'council-unavailable: a different but still long reason text')"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" == *"/council-review"* \
      && "$OUT" != *"council-unavailable:"* ]]; then
  ok "t3-second-reason-same-hash-denied"
else
  bad "t3-second-reason-same-hash-denied" "rc=$RC out='$OUT'"
fi
# Spent state survives the deny entry: still refused after the deny ledger is gone.
rm -f "$STATE_DIR"/*/denied.json
run "$(evt Task code-reviewer)"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* ]]; then
  ok "t4-spent-pass-outlives-deny-entry"
else
  bad "t4-spent-pass-outlives-deny-entry" "rc=$RC out='$OUT'"
fi
# A different diff hash gets its own single pass.
reset_worktree_only
gen_lines 260 > "$REPO/big2.dat"
git -C "$REPO" add big2.dat
run "$(evt Task code-reviewer)"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"additionalContext"* && "$OUT" != *"permissionDecision"* ]]; then
  ok "t5-different-diff-gets-own-pass"
else
  bad "t5-different-diff-gets-own-pass" "rc=$RC out='$OUT'"
fi
reset_repo
mkdir -p "$REPO/billing"; gen_lines 5 > "$REPO/billing/pay.py"
git -C "$REPO" add billing/pay.py
run "$(evt Task code-reviewer)"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"AGENT_REVIEW_OVERRIDE"* ]]; then
  ok "t6-risk-path-reason-still-refused"
else
  bad "t6-risk-path-reason-still-refused" "rc=$RC out='$OUT'"
fi

echo
echo "=== 2026-10-31 round 1: concurrency, no fingerprint, ledger cap, write failure, first-request id ==="
state_ledger() { find "$STATE_DIR" -name "$1" -type f 2>/dev/null | head -n 1; }

# (a) two simultaneous reason dispatches for one diff -> exactly one passes,
# exactly one is an explicit deny, both exit 0 (the delay makes them contend for the lock).
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
EVT_R="$(evt_p Task code-reviewer "$REASON_PROMPT")"
for n in 1 2; do
  (cd "$REPO" && printf '%s' "$EVT_R" | env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR \
      AGENT_COUNCIL_STATE_DIR="$STATE_DIR" AGENT_COUNCIL_TEST_ESCAPE_DELAY_S=1 \
      python3 "$HOOK" >"$WORK/conc$n.out" 2>/dev/null; echo $? >"$WORK/conc$n.rc") &
done
wait
PASSES=0; DENIES=0; RCS_OK=1
for n in 1 2; do
  grep -q additionalContext "$WORK/conc$n.out" && PASSES=$((PASSES + 1))
  grep -q '"permissionDecision": *"deny"' "$WORK/conc$n.out" && DENIES=$((DENIES + 1))
  [[ "$(cat "$WORK/conc$n.rc")" == "0" ]] || RCS_OK=0
done
if [[ "$PASSES" -eq 1 && "$DENIES" -eq 1 && "$RCS_OK" -eq 1 ]]; then ok "r1a-concurrent-same-diff-exactly-one-pass-one-deny"; else bad "r1a-concurrent-same-diff-exactly-one-pass-one-deny" "passes=$PASSES denies=$DENIES rcs_ok=$RCS_OK"; fi

# (b) diff fingerprint unavailable -> no reason pass, text promises no resend.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<SH
#!/usr/bin/env bash
# fail only the gate's fingerprint diff (has --no-ext-diff, no --numstat)
case " \$* " in *" --numstat "*) ;; *" --no-ext-diff "*) exit 1 ;; esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$SHIM/git"
run_nofp() {
  OUT="$(cd "$REPO" && printf '%s' "$1" | env -u CLAUDE_PROJECT_DIR -u AGENT_PROJECT_DIR PATH="$SHIM:$PATH" \
      AGENT_COUNCIL_STATE_DIR="$STATE_DIR" python3 "$HOOK" 2>/dev/null)"; RC=$?
}
reset_repo; stage_large_diff
run_nofp "$(evt Task code-reviewer)"
NOFP1="$OUT"
run_nofp "$(evt_p Task code-reviewer "$REASON_PROMPT")"
NOFP2="$OUT"
run_nofp "$(evt_p Task code-reviewer "$REASON_PROMPT")"
NOFP3="$OUT"
NOFP_OK=1
for o in "$NOFP1" "$NOFP2" "$NOFP3"; do
  [[ "$o" == *"permissionDecision"*"deny"* && "$o" != *"additionalContext"* \
     && "$o" != *"council-unavailable"* && "$o" != *"re-issue"* && "$o" == *"/council-review"* ]] || NOFP_OK=0
done
if [[ "$NOFP_OK" -eq 1 ]]; then
  ok "r1b-no-fingerprint-no-pass-no-resend-promise"
else
  bad "r1b-no-fingerprint-no-pass-no-resend-promise" "1='$NOFP1' 2='$NOFP2' 3='$NOFP3'"
fi
if grep -q "fingerprint unavailable" "$REPO/.agent/logs/security-violations.jsonl" 2>/dev/null; then
  ok "r1b2-no-fingerprint-logged"
else
  bad "r1b2-no-fingerprint-logged" "no log record"
fi

# (c) corrupted escaped.json -> the very first reason request is refused, the
# corruption is logged, and the corrupt file is left byte-for-byte untouched.
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
LEDGER_DIR="$(dirname "$(state_ledger denied.json)")"
printf '{not json' > "$LEDGER_DIR/escaped.json"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"; C1="$OUT"
run "$(evt_p Task code-reviewer 'council-unavailable: yet another long enough reason')"; C2="$OUT"
if [[ "$C1" == *"permissionDecision"*"deny"* && "$C1" != *"additionalContext"* && "$C1" == *"$CLOSED_PHRASE"* \
      && "$C2" == *"permissionDecision"*"deny"* && "$C2" != *"additionalContext"* && "$C2" == *"$CLOSED_PHRASE"* ]]; then
  ok "r1c-corrupt-ledger-refuses-first-request"
else
  bad "r1c-corrupt-ledger-refuses-first-request" "c1='$C1' c2='$C2'"
fi
if [[ "$(cat "$LEDGER_DIR/escaped.json")" == '{not json' ]]; then
  ok "r1c3-corrupt-ledger-left-untouched"
else
  bad "r1c3-corrupt-ledger-left-untouched" "content='$(cat "$LEDGER_DIR/escaped.json")'"
fi
if grep -q "unreadable" "$REPO/.agent/logs/security-violations.jsonl" 2>/dev/null; then
  ok "r1c2-corrupt-ledger-logged"
else
  bad "r1c2-corrupt-ledger-logged" "no log record"
fi

# (d) state dir not writable -> no pass (skipped when root ignores modes).
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
LEDGER_DIR="$(dirname "$(state_ledger denied.json)")"
if [[ "$(id -u)" -ne 0 ]]; then
  chmod a-w "$LEDGER_DIR"
  run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
  chmod u+w "$LEDGER_DIR"
  if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" != *"additionalContext"* ]]; then
    ok "r1d-unwritable-state-refuses-pass"
  else
    bad "r1d-unwritable-state-refuses-pass" "rc=$RC out='$OUT'"
  fi
else
  skip "r1d-unwritable-state-refuses-pass (running as root; modes are ignored)"
fi
# (d2) ledger write fails (escaped.json is a directory) -> no pass.
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
LEDGER_DIR="$(dirname "$(state_ledger denied.json)")"
mkdir -p "$LEDGER_DIR/escaped.json"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" != *"additionalContext"* ]]; then
  ok "r1d2-ledger-write-failure-refuses-pass"
else
  bad "r1d2-ledger-write-failure-refuses-pass" "rc=$RC out='$OUT'"
fi

# (e) 51+ distinct valid entries never evict the first spent hash.
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
LEDGER_DIR="$(dirname "$(state_ledger escaped.json)")"
python3 - "$LEDGER_DIR/escaped.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["entries"] += [{"hash": "fake%02d" % i, "ts": time.time()} for i in range(49)]
json.dump(d, open(p, "w"))
PY
reset_worktree_only
gen_lines 260 > "$REPO/big2.dat"; git -C "$REPO" add big2.dat
run "$(evt Task code-reviewer)"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"   # 51st valid entry
reset_worktree_only; stage_large_diff               # back to the first diff
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" != *"additionalContext"* ]]; then
  ok "r1e-first-hash-stays-spent-after-51-entries"
else
  bad "r1e-first-hash-stays-spent-after-51-entries" "rc=$RC out='$OUT'"
fi

# (f) an entry past AGENT_COUNCIL_SPENT_TTL_S earns one more pass.
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
# (a TTL below 1 is invalid and falls back to 24h, so age the entry instead)
LEDGER_DIR="$(dirname "$(state_ledger escaped.json)")"
python3 - "$LEDGER_DIR/escaped.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
for e in d["entries"]:
    e["ts"] = time.time() - 90000
json.dump(d, open(p, "w"))
PY
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$OUT" == *"additionalContext"* ]]; then ok "r1f-expired-spent-entry-allows-one-more"; else bad "r1f-expired-spent-entry-allows-one-more" "out='$OUT'"; fi

# (g) a decision-id reason on the very first dispatch still counts as the first deny.
reset_repo; stage_large_diff
run "$(evt_p Task code-reviewer 'council-unavailable: per the user standing decision D-20261025-7d7f skip council')"
G1="$OUT"
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$G1" == *"delegation decision id"* && "$OUT" == *"additionalContext"* && "$OUT" != *"permissionDecision"* ]]; then
  ok "r1g-first-request-id-reason-then-legit-reason-passes"
else
  bad "r1g-first-request-id-reason-then-legit-reason-passes" "g1='$G1' out='$OUT'"
fi

# (h) a decision id after the 300-character log cap is still refused.
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
LONG="$(printf 'a%.0s' $(seq 1 320))"
run "$(evt_p Task code-reviewer "council-unavailable: $LONG D-20261025-7d7f")"
if [[ "$RC" -eq 0 && "$OUT" == *"delegation decision id"* ]]; then ok "r1h-id-past-300-chars-refused"; else bad "r1h-id-past-300-chars-refused" "out='$OUT'"; fi

# (i) another process holds the ledger lock past the wait limit -> pass refused.
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
LEDGER_DIR="$(dirname "$(state_ledger denied.json)")"
start_lock_holder "$LEDGER_DIR"
if [[ ! -e "$LOCK_READY" ]]; then
  stop_lock_holder
  bad "r2i-lock-held-past-wait-limit-refuses-pass" "lock holder never became ready"
else
  run_timed "$(evt_p Task code-reviewer "$REASON_PROMPT")" AGENT_COUNCIL_SPENT_LOCK_WAIT_S=0.3
  stop_lock_holder
  if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" != *"additionalContext"* && "$OUT" == *"$CLOSED_PHRASE"* ]]; then
    ok "r2i-lock-held-past-wait-limit-refuses-pass"
  else
    bad "r2i-lock-held-past-wait-limit-refuses-pass" "rc=$RC out='$OUT'"
  fi

  # (i2) a non-finite wait value must not mean waiting forever (nan) and must stay
  # bounded (inf): the hook ends inside 10s and refuses the pass.
  for W in nan inf; do
    reset_repo; stage_large_diff
    run "$(evt Task code-reviewer)"
    LEDGER_DIR="$(dirname "$(state_ledger denied.json)")"
    start_lock_holder "$LEDGER_DIR"
    run_timed "$(evt_p Task code-reviewer "$REASON_PROMPT")" AGENT_COUNCIL_SPENT_LOCK_WAIT_S="$W"
    stop_lock_holder
    if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" != *"additionalContext"* && "$OUT" == *"$CLOSED_PHRASE"* ]]; then
      ok "r2i2-lock-wait-$W-ends-within-10s-and-refuses"
    else
      bad "r2i2-lock-wait-$W-ends-within-10s-and-refuses" "rc=$RC (124 = timed out) out='$OUT'"
    fi
  done
fi

# (k) a huge or non-finite test delay is bounded: the hook still ends inside 10s and passes once.
for D in 30 nan; do
  reset_repo; stage_large_diff
  run "$(evt Task code-reviewer)"
  run_timed "$(evt_p Task code-reviewer "$REASON_PROMPT")" AGENT_COUNCIL_TEST_ESCAPE_DELAY_S="$D"
  if [[ "$RC" -eq 0 && "$OUT" == *"additionalContext"* && "$OUT" != *"permissionDecision"* ]]; then
    ok "r2k-escape-delay-$D-bounded-and-pass-recorded"
  else
    bad "r2k-escape-delay-$D-bounded-and-pass-recorded" "rc=$RC (124 = timed out) out='$OUT'"
  fi
done

# (l) a non-numeric AGENT_COUNCIL_SPENT_TTL_S must not crash the hook at import.
reset_repo; stage_large_diff
for T in abc nan inf -5; do
  run_timed "$(evt Task code-reviewer)" AGENT_COUNCIL_SPENT_TTL_S="$T"
  if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" == *"council-review"* ]]; then
    ok "r2l-spent-ttl-$T-hook-still-decides"
  else
    bad "r2l-spent-ttl-$T-hook-still-decides" "rc=$RC out='$OUT'"
  fi
done

# (j) exactly SPENT_CAP (1000) valid entries -> a new pass is refused.
reset_repo; stage_large_diff
run "$(evt Task code-reviewer)"
LEDGER_DIR="$(dirname "$(state_ledger denied.json)")"
python3 - "$LEDGER_DIR/escaped.json" <<'PY'
import json, sys, time
json.dump({"entries": [{"hash": "cap%04d" % i, "ts": time.time()} for i in range(1000)]}, open(sys.argv[1], "w"))
PY
run "$(evt_p Task code-reviewer "$REASON_PROMPT")"
if [[ "$RC" -eq 0 && "$OUT" == *"permissionDecision"*"deny"* && "$OUT" != *"additionalContext"* && "$OUT" == *"$CLOSED_PHRASE"* ]]; then
  ok "r2j-ledger-at-1000-entries-refuses-new-pass"
else
  bad "r2j-ledger-at-1000-entries-refuses-new-pass" "rc=$RC out='$OUT'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
