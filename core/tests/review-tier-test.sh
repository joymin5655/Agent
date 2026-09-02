#!/usr/bin/env bash
# review-tier-test.sh — verify core/infra/review-tier.sh.
#
# Review-cadence SSOT: assigns tier 0 (skip)/1 (standard)/2 (council-scale)
# to a diff, delegating the tier-2 judgment (and the lines/files/risk
# numbers) to core/infra/council-threshold.sh rather than re-mirroring its
# risk-area patterns. Exit codes: 0=tier0, 5=tier1, 10=tier2 (10 shared with
# council-threshold.sh's own "escalate" exit, by design).
#
# Fixture: a throwaway git repo. AGENT_REVIEW_SKIP_LINES is left at its
# default (50) throughout — the 30/60-line cases are chosen to straddle it.
#
# Pattern: council-escalation-gate-test.sh's git fixture + reset_repo().
#
# Usage: bash core/tests/review-tier-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/review-tier.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   [$1]"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL [$1] $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
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
}

gen_lines() {  # gen_lines <n> <file>
  local n="$1" file="$2" i
  for ((i = 0; i < n; i++)); do echo "line $i"; done > "$file"
}

# run -> OUT, RC (cwd = fixture repo, so --staged resolves there).
run() {
  OUT="$(cd "$REPO" && bash "$SCRIPT" --staged 2>/dev/null)"
  RC=$?
}

echo "=== docs-only diff -> tier 0 ==="
reset_repo
echo "more docs" >> "$REPO/README.md"
git -C "$REPO" add README.md
run
if [[ "$RC" -eq 0 && "$OUT" == *"tier=0"* ]]; then
  ok "a1-docs-only-tier0"
else
  bad "a1-docs-only-tier0" "rc=$RC out='$OUT'"
fi

echo "=== 30 code lines -> tier 0 (at/below AGENT_REVIEW_SKIP_LINES default 50) ==="
reset_repo
gen_lines 30 "$REPO/a.py"
git -C "$REPO" add a.py
run
if [[ "$RC" -eq 0 && "$OUT" == *"tier=0"* ]]; then
  ok "b1-30-lines-tier0"
else
  bad "b1-30-lines-tier0" "rc=$RC out='$OUT'"
fi

echo "=== 60 code lines -> tier 1 (above AGENT_REVIEW_SKIP_LINES default 50) ==="
reset_repo
gen_lines 60 "$REPO/b.py"
git -C "$REPO" add b.py
run
if [[ "$RC" -eq 5 && "$OUT" == *"tier=1"* ]]; then
  ok "c1-60-lines-tier1"
else
  bad "c1-60-lines-tier1" "rc=$RC out='$OUT'"
fi

echo "=== risk-area path -> tier 2 regardless of size ==="
reset_repo
mkdir -p "$REPO/secrets"
echo "TOKEN=x" > "$REPO/secrets/x"
git -C "$REPO" add secrets/x
run
if [[ "$RC" -eq 10 && "$OUT" == *"tier=2"* && "$OUT" == *"risk=secret"* ]]; then
  ok "d1-risk-path-tier2"
else
  bad "d1-risk-path-tier2" "rc=$RC out='$OUT'"
fi

echo "=== 250-line diff -> tier 2 (line-count threshold, council-threshold.sh's own signal) ==="
reset_repo
gen_lines 250 "$REPO/big.py"
git -C "$REPO" add big.py
run
if [[ "$RC" -eq 10 && "$OUT" == *"tier=2"* ]]; then
  ok "e1-250-lines-tier2"
else
  bad "e1-250-lines-tier2" "rc=$RC out='$OUT'"
fi

echo "=== output line format: tier=/lines=/files=/code_lines=/risk=, single line ==="
reset_repo
gen_lines 5 "$REPO/c.py"
git -C "$REPO" add c.py
run
if [[ "$OUT" != *$'\n'* && "$OUT" == *"tier="* && "$OUT" == *"lines="* \
    && "$OUT" == *"files="* && "$OUT" == *"code_lines="* && "$OUT" == *"risk="* ]]; then
  ok "f1-output-line-format"
else
  bad "f1-output-line-format" "out='$OUT'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
