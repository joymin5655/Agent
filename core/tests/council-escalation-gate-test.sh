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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/council-escalation-gate.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 — $2"; }

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
  gen_lines 250 > "$REPO/big.txt"
  git -C "$REPO" add big.txt
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
echo "=== same-diff-hash single-deny: escape 2 ==="
reset_repo
stage_large_diff
run "$(evt Task code-reviewer)"
first_deny_ok=0
[[ "$RC" -eq 0 && "$OUT" == *"deny"* ]] && first_deny_ok=1
run "$(evt Task code-reviewer)"
if [[ "$first_deny_ok" -eq 1 && "$RC" -eq 0 && -z "$OUT" ]] \
   && grep -q "loop-safety escape" "$WORK/stderr.log"; then
  ok "d1-second-attempt-same-diff-allowed-with-warning"
else
  bad "d1-second-attempt-same-diff-allowed-with-warning" "rc=$RC out='$OUT' stderr=$(cat "$WORK/stderr.log" 2>/dev/null)"
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
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
