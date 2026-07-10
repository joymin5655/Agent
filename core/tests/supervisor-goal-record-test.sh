#!/usr/bin/env bash
# supervisor-goal-record-test.sh — verify the F-2 repo-native execution ledger:
# `supervisor-goal.sh complete` must drop `.agent/plans/<slug>/RECORD.md` with
# the four ledger fields (waves / prs / audit verdict / carried), must never
# clobber a RECORD.md the skill already wrote, and a ledger failure must never
# block completion. Also a regression floor for the complete path itself
# (status flips to 'complete' and the status JSON still prints last).
#
# Isolation: every case runs inside a fresh mktemp git repo (the script derives
# its root from `git rev-parse --show-toplevel`), so the real repo's
# .agent/locks/goal-state.db is never touched.
#
# Requires sqlite3 + jq (same floor as supervisor-goal.sh itself — the script
# hard-exits 127 without them, so this battery would fail loudly, not silently).
#
# Usage: bash core/tests/supervisor-goal-record-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# build_fixture — a fresh throwaway git repo carrying just the goal machine.
build_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  (cd "$fx" && git init -q)
  mkdir -p "$fx/core/infra/sql"
  cp "$REPO_ROOT/core/infra/supervisor-goal.sh" "$fx/core/infra/"
  cp "$REPO_ROOT/core/infra/sql/001_supervisor_goals.sql" "$fx/core/infra/sql/"
  printf '%s' "$fx"
}

echo "=== (a) complete drops RECORD.md with the four ledger fields ==="
FX=$(build_fixture)
(
  cd "$FX"
  bash core/infra/supervisor-goal.sh init demo 2 >/dev/null
  bash core/infra/supervisor-goal.sh advance-wave demo 1 >/dev/null
  bash core/infra/supervisor-goal.sh advance-wave demo 2 >/dev/null
  bash core/infra/supervisor-goal.sh complete demo >/dev/null
)
REC="$FX/.agent/plans/demo/RECORD.md"
[[ -f "$REC" ]]; check "record-created" $?
grep -q '^- waves: 2/2 completed' "$REC"; check "record-waves-live-count" $?
grep -q '^- prs:' "$REC";           check "record-prs-field" $?
grep -q '^- audit verdict:' "$REC"; check "record-audit-field" $?
grep -q '^- carried:' "$REC";       check "record-carried-field" $?
grep -q 'status: complete' "$REC";  check "record-status-line" $?

echo
echo "=== (b) complete still prints the status JSON last (consumer contract) ==="
FX=$(build_fixture)
OUT_B="$(cd "$FX" && bash core/infra/supervisor-goal.sh init demo 1 >/dev/null \
  && bash core/infra/supervisor-goal.sh complete demo)"
printf '%s\n' "$OUT_B" | tail -1 | jq -e '.status == "complete"' >/dev/null
check "status-json-still-last-and-complete" $?

echo
echo "=== (c) an existing RECORD.md is never clobbered ==="
FX=$(build_fixture)
mkdir -p "$FX/.agent/plans/demo"
printf '# demo — execution record\nhand-written by the skill\n' > "$FX/.agent/plans/demo/RECORD.md"
(
  cd "$FX"
  bash core/infra/supervisor-goal.sh init demo 1 >/dev/null
  bash core/infra/supervisor-goal.sh complete demo >/dev/null
)
grep -q 'hand-written by the skill' "$FX/.agent/plans/demo/RECORD.md"
check "existing-record-preserved" $?

echo
echo "=== (d) unwritable plans dir -> completion still succeeds (fail-safe) ==="
FX=$(build_fixture)
RO_DIR="$TMP_ROOT/readonly-plans"
mkdir -p "$RO_DIR"
chmod -w "$RO_DIR"
(
  cd "$FX"
  bash core/infra/supervisor-goal.sh init demo 1 >/dev/null
  AGENT_PLANS_DIR="$RO_DIR" bash core/infra/supervisor-goal.sh complete demo >/dev/null
)
RC_D=$?
chmod +w "$RO_DIR"
[[ $RC_D -eq 0 ]]; check "ledger-failure-does-not-block-complete" $?

echo
echo "=== (e) AGENT_PLANS_DIR seam is honored ==="
FX=$(build_fixture)
ALT="$TMP_ROOT/alt-plans"
(
  cd "$FX"
  bash core/infra/supervisor-goal.sh init demo 1 >/dev/null
  AGENT_PLANS_DIR="$ALT" bash core/infra/supervisor-goal.sh complete demo >/dev/null
)
[[ -f "$ALT/demo/RECORD.md" ]]; check "plans-dir-seam-honored" $?

echo
echo "=== (f) traversal slug -> no ledger written outside the plans root, complete still succeeds ==="
FX=$(build_fixture)
(
  cd "$FX"
  bash core/infra/supervisor-goal.sh init good 1 >/dev/null
  bash core/infra/supervisor-goal.sh complete '../../escape' >/dev/null
)
RC_F=$?
[[ $RC_F -eq 0 ]]; check "traversal-slug-does-not-block-complete" $?
[[ ! -e "$TMP_ROOT/escape/RECORD.md" && ! -e "$FX/../escape" && ! -e "$FX/.agent/plans/../../escape/RECORD.md" ]]
check "traversal-slug-writes-nothing-outside" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
