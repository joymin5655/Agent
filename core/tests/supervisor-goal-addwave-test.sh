#!/usr/bin/env bash
# supervisor-goal-addwave-test.sh — `supervisor-goal.sh add-wave <slug>` grows
# total_waves by one for a live goal (the /supervise --converge hook) and refuses
# on a missing, complete, or aborted goal without touching the row.
#
# Isolation: every case runs in a fresh mktemp git repo (the script derives its
# root from `git rev-parse --show-toplevel`), so the real goal-state.db is never
# touched. Requires sqlite3 + jq; without them it emits `SKIP:` and exits 2.
#
# Usage: bash core/tests/supervisor-goal-addwave-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v sqlite3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: supervisor-goal-addwave-test.sh requires sqlite3 + jq; not installed"
  exit 2
fi

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FX="$TMP_ROOT/fx"
mkdir -p "$FX/core/infra/sql"
(cd "$FX" && git init -q)
cp "$REPO_ROOT/core/infra/supervisor-goal.sh" "$FX/core/infra/"
cp "$REPO_ROOT/core/infra/sql/001_supervisor_goals.sql" "$FX/core/infra/sql/"
cd "$FX" || exit 1
sg() { bash core/infra/supervisor-goal.sh "$@"; }
total() { sg status "$1" | jq -r '.total_waves'; }

echo "=== add-wave on a live goal ==="
sg init demo 2 >/dev/null
sg add-wave demo >/dev/null
check "total-incremented" "3" "$(total demo)"
sg add-wave demo >/dev/null
check "total-incremented-again" "4" "$(total demo)"
check "status-json-printed" "demo" "$(sg add-wave demo | jq -r '.plan_slug')"

echo "=== a goal on its last wave can still grow before advance-wave ==="
sg init last 1 >/dev/null
sg add-wave last >/dev/null
sg advance-wave last 1 >/dev/null
check "still-active-after-first-advance" "active" "$(sg status last | jq -r '.status')"

echo "=== refusals leave the row untouched ==="
sg add-wave ghost >/dev/null 2>&1
check "missing-goal-exits-3" "3" "$?"
sg init done1 1 >/dev/null
sg complete done1 >/dev/null 2>&1
sg add-wave done1 >/dev/null 2>&1
check "complete-goal-exits-3" "3" "$?"
check "complete-goal-total-unchanged" "1" "$(total done1)"
sg init dead 2 >/dev/null
sg abort dead "test" >/dev/null
sg add-wave dead >/dev/null 2>&1
check "aborted-goal-exits-3" "3" "$?"
check "aborted-goal-total-unchanged" "2" "$(total dead)"
sg add-wave >/dev/null 2>&1
check "no-slug-exits-2" "2" "$?"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
