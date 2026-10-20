#!/usr/bin/env bash
# supervisor-goal-stuck-test.sh — stuck detection by side effects in
# core/infra/supervisor-goal.sh (agent-spawn / agent-effect / agent-wait / agent-resume /
# agent-done / stuck-check). The clock is pinned with AGENT_NOW_MS so no case sleeps.
#
# Each case runs in a fresh throwaway git repo (the script derives its root from
# `git rev-parse --show-toplevel`), so the harness's own goal-state.db is never touched.
#
# Usage: bash core/tests/supervisor-goal-stuck-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v sqlite3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: supervisor-goal-stuck-test.sh requires sqlite3 + jq; not installed"
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

build_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  (cd "$fx" && git init -q && git config user.email t@example.com && git config user.name t)
  mkdir -p "$fx/core/infra/sql" "$fx/work"
  cp "$REPO_ROOT/core/infra/supervisor-goal.sh" "$fx/core/infra/"
  cp "$REPO_ROOT/core/infra/sql/001_supervisor_goals.sql" "$fx/core/infra/sql/"
  (cd "$fx" && bash core/infra/supervisor-goal.sh init demo 2 >/dev/null)
  printf '%s' "$fx"
}

T0=1000000000000   # ms; far from "now" so real file mtimes can never look newer
# g <fixture> <now-ms> <args...> — run the goal script with a pinned clock.
g() { local fx="$1" now="$2"; shift 2; (cd "$fx" && AGENT_NOW_MS="$now" bash core/infra/supervisor-goal.sh "$@" 2>&1); }

echo "=== (1) silent while inside the budget ==="
FX=$(build_fixture)
g "$FX" $T0 agent-spawn demo a1 1 600 >/dev/null
check "within-budget-silent" "" "$(g "$FX" $((T0 + 599000)) stuck-check demo)"

echo "=== (2) no side effect past stuck_after -> STUCK, named once ==="
OUT=$(g "$FX" $((T0 + 601000)) stuck-check demo)
check "flagged-stuck" "STUCK a1 (wave 1): no side effect for 601s, budget 600s, last=spawn" "$OUT"
check "unchanged-tick-silent" "" "$(g "$FX" $((T0 + 700000)) stuck-check demo)"
check "still-silent-later" "" "$(g "$FX" $((T0 + 900000)) stuck-check demo)"
check "agents-json-stuck-true" "true" "$(g "$FX" $((T0 + 900000)) agents demo | jq -r '.[0].stuck')"

echo "=== (3) a new side effect clears the flag (RECOVERED once) ==="
g "$FX" $((T0 + 910000)) agent-effect demo a1 commit >/dev/null
check "recovered" "RECOVERED a1 (wave 1): new commit" "$(g "$FX" $((T0 + 920000)) stuck-check demo)"
check "recovered-then-silent" "" "$(g "$FX" $((T0 + 930000)) stuck-check demo)"
check "budget-restarts-from-effect" "" "$(g "$FX" $((T0 + 910000 + 599000)) stuck-check demo)"

echo "=== (4) waiting on the user is never stuck; resume restarts the clock ==="
FX=$(build_fixture)
g "$FX" $T0 agent-spawn demo a1 1 60 >/dev/null
g "$FX" $((T0 + 10000)) agent-wait demo a1 >/dev/null
check "awaiting-not-stuck" "" "$(g "$FX" $((T0 + 5000000)) stuck-check demo)"
g "$FX" $((T0 + 5000000)) agent-resume demo a1 >/dev/null
check "resumed-fresh-clock" "" "$(g "$FX" $((T0 + 5059000)) stuck-check demo)"
check "resumed-then-stuck" "STUCK a1 (wave 1): no side effect for 61s, budget 60s, last=resume" "$(g "$FX" $((T0 + 5061000)) stuck-check demo)"

echo "=== (5) done agents are ignored ==="
g "$FX" $((T0 + 5062000)) agent-done demo a1 >/dev/null
check "done-not-reported" "" "$(g "$FX" $((T0 + 9000000)) stuck-check demo)"

echo "=== (6) a file change in the agent's scope counts as a side effect ==="
FX=$(build_fixture)
NOW_REAL=$(python3 -c 'import time; print(int(time.time()*1000))')
g "$FX" $((NOW_REAL - 100000)) agent-spawn demo w1 1 60 work >/dev/null
printf 'x' > "$FX/work/out.txt"   # mtime ~ now, newer than the spawn
check "scope-file-change-keeps-alive" "" "$(g "$FX" $((NOW_REAL + 30000)) stuck-check demo)"
check "scope-effect-recorded" "file" "$(g "$FX" $((NOW_REAL + 30000)) agents demo | jq -r '.[0].last_effect_kind')"
# no further change: once the budget passes from that file mtime it is STUCK
OUT=$(g "$FX" $((NOW_REAL + 200000)) stuck-check demo)
check "scope-quiet-then-stuck" "STUCK w1" "${OUT%% (*}"

echo "=== (7) a commit touching the scope counts too ==="
FX=$(build_fixture)
NOW_REAL=$(python3 -c 'import time; print(int(time.time()*1000))')
g "$FX" $((NOW_REAL - 100000)) agent-spawn demo c1 1 60 work >/dev/null
( cd "$FX" && printf 'y' > work/c.txt && git add work/c.txt && git commit -q -m c && touch -t 200001010000 work/c.txt )
check "scope-commit-keeps-alive" "" "$(g "$FX" $((NOW_REAL + 30000)) stuck-check demo)"
check "scope-commit-kind" "commit" "$(g "$FX" $((NOW_REAL + 30000)) agents demo | jq -r '.[0].last_effect_kind')"

echo "=== (8) input validation ==="
FX=$(build_fixture)
g "$FX" $T0 agent-spawn demo 'bad id' 1 60 >/dev/null; check "bad-id-rejected" "2" "$(cd "$FX" && bash core/infra/supervisor-goal.sh agent-spawn demo 'bad id' 1 60 >/dev/null 2>&1; echo $?)"
check "zero-budget-rejected" "2" "$(cd "$FX" && bash core/infra/supervisor-goal.sh agent-spawn demo a 1 0 >/dev/null 2>&1; echo $?)"
check "traversal-scope-rejected" "2" "$(cd "$FX" && bash core/infra/supervisor-goal.sh agent-spawn demo a 1 60 ../x >/dev/null 2>&1; echo $?)"
check "effect-unknown-agent" "3" "$(cd "$FX" && bash core/infra/supervisor-goal.sh agent-effect demo ghost >/dev/null 2>&1; echo $?)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
