#!/usr/bin/env bash
# impact-context-test.sh — core/infra/impact-context.py contract, against a
# stub codegraph (CODEGRAPH_BIN) in throwaway git repos. No real index needed.
#
# Contract covered:
#   (a) codegraph not installed                    -> no output, exit 0
#   (b) repo without .codegraph/                   -> no output, exit 0
#   (c) empty diff                                 -> no output, exit 0
#   (d) dependents outside the diff are listed; dependents inside it are not
#   (e) affected test files are listed
#   (f) output never exceeds IMPACT_CONTEXT_MAX_LINES (truncation marker)
#   (g) a hanging codegraph is cut off by IMPACT_CONTEXT_BUDGET_S, exit 0
#   (h) a range starting with '-' is not parsed as a git option, exit 0
#   (i) docs-only diff (no source files)           -> no output
#   (j) explicit range, --head, and the staged-empty fallback all list dependents
#   (k) linked worktree with no .codegraph/ of its own uses the main index
#   (l) a deleted source file is still examined and marked
#   (m) the staged-empty fallback is labelled in the output
#   (n) a header count beyond the listed names is reported as "+more"
#   (o) on timeout the whole codegraph process group is killed
#
# Usage: bash core/tests/impact-context-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IC="$REPO_ROOT/core/infra/impact-context.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# Fixture repos must not inherit the caller's git config (gpgsign, hooksPath …):
# a fixture commit that fails would make the "silent" cases pass vacuously.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# Stub codegraph. `node -f F` reports two dependents (one of them is a.ts, which
# is IN the fixture diff, so it must be filtered out); `affected` prints one test
# file. STUB_SLEEP makes every call hang; STUB_USERS overrides the dependent list.
STUB="$TMP_ROOT/codegraph"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
[[ -n "${STUB_CHILD:-}" ]] && { sleep "$STUB_CHILD" & wait; }
[[ -n "${STUB_SLEEP:-}" ]] && sleep "$STUB_SLEEP"
# real codegraph prints this warning first when the index is another worktree's
[[ -n "${STUB_WARN:-}" ]] && echo "⚠ CodeGraph results below come from a different git worktree"
case "$1" in
  node)
    f=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-f" ]] && f="$2"; shift; done
    echo "**$f** — 1 symbols, used by ${STUB_N:-2} files: ${STUB_USERS:-src/a.ts, src/caller.ts}"
    ;;
  affected) echo "tests/b.test.ts" ;;
esac
SH
chmod +x "$STUB"

# fixture_repo [index] — git repo with a committed base and a staged change to
# src/a.ts + src/b.ts. With "index", also creates .codegraph/.
fixture_repo() {
  local d; d="$(mktemp -d "$TMP_ROOT/rXXXXXX")"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
    && mkdir -p src docs && echo base > src/a.ts && echo base > src/b.ts \
    && echo base > docs/x.md && git add -A && git commit -qm base \
    && echo change >> src/a.ts && echo change >> src/b.ts && git add -A )
  [[ -n "$(cd "$d" && git diff --staged --name-only)" ]] || { echo "fixture setup failed: $d" >&2; exit 2; }
  [[ "${1:-}" == "index" ]] && mkdir -p "$d/.codegraph"
  echo "$d"
}

ic() { # ic <repo> [args...] — run in repo; sets OUT and RC
  local d="$1"; shift
  OUT="$(cd "$d" && python3 "$IC" "$@" 2>&1)"; RC=$?
}

echo "=== (a) codegraph not installed ==="
R=$(fixture_repo index)
CODEGRAPH_BIN="$TMP_ROOT/does-not-exist" ic "$R"
[[ $RC -eq 0 && -z "$OUT" ]]; check "no-codegraph-silent" $?

echo "=== (b) repo without .codegraph ==="
R=$(fixture_repo)
CODEGRAPH_BIN="$STUB" ic "$R"
[[ $RC -eq 0 && -z "$OUT" ]]; check "no-index-silent" $?

echo "=== (c) empty diff ==="
R=$(fixture_repo index); (cd "$R" && git commit -qm c2)
# staged is empty AND HEAD~1..HEAD has a.ts/b.ts, so use an explicit empty range
CODEGRAPH_BIN="$STUB" ic "$R" "HEAD..HEAD"
[[ $RC -eq 0 && -z "$OUT" ]]; check "empty-diff-silent" $?

echo "=== (d)(e) dependents outside the diff + affected tests ==="
R=$(fixture_repo index)
CODEGRAPH_BIN="$STUB" ic "$R"
[[ $RC -eq 0 ]]; check "exit-0" $?
printf '%s' "$OUT" | grep -q 'src/caller.ts'; check "outside-dependent-listed" $?
printf '%s' "$OUT" | grep -q 'used by src/a.ts'; [[ $? -ne 0 ]]; check "in-diff-dependent-filtered" $?
printf '%s' "$OUT" | grep -q 'tests/b.test.ts'; check "affected-test-listed" $?

echo "=== (f) line cap ==="
R=$(fixture_repo index)
CODEGRAPH_BIN="$STUB" IMPACT_CONTEXT_MAX_LINES=4 ic "$R"
n=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
[[ $RC -eq 0 && $n -le 4 ]]; check "capped-at-4-lines (got $n)" $?
printf '%s' "$OUT" | grep -q 'truncated at 4 lines'; check "truncation-marker" $?

echo "=== (g) budget cuts off a hanging codegraph ==="
R=$(fixture_repo index)
start=$(date +%s)
CODEGRAPH_BIN="$STUB" STUB_SLEEP=30 IMPACT_CONTEXT_BUDGET_S=2 ic "$R"
el=$(( $(date +%s) - start ))
[[ $RC -eq 0 && $el -le 6 ]]; check "budget-respected (${el}s)" $?

echo "=== (h) range starting with '-' is not a git option ==="
R=$(fixture_repo index)
CANARY="$TMP_ROOT/canary-out"
CODEGRAPH_BIN="$STUB" ic "$R" "--output=$CANARY"
[[ $RC -eq 0 && ! -e "$CANARY" ]]; check "dash-range-not-an-option" $?

echo "=== (i) docs-only diff ==="
R=$(fixture_repo index)
(cd "$R" && git reset -q && echo more >> docs/x.md && git add docs/x.md)
CODEGRAPH_BIN="$STUB" ic "$R"
[[ $RC -eq 0 && -z "$OUT" ]]; check "docs-only-silent" $?

echo "=== (j) explicit range, --head and staged-empty fallback ==="
R=$(fixture_repo index); (cd "$R" && git commit -qm c2)
for t in "HEAD~1..HEAD" "--head" ""; do
  if [[ -n "$t" ]]; then CODEGRAPH_BIN="$STUB" ic "$R" "$t"; else CODEGRAPH_BIN="$STUB" ic "$R"; fi
  printf '%s' "$OUT" | grep -q 'src/caller.ts'; check "dependents-listed: ${t:-staged-empty fallback}" $?
done

echo "=== (k) linked worktree uses the main checkout's index ==="
R=$(fixture_repo index); (cd "$R" && git commit -qm c2)
W="$TMP_ROOT/wt-$RANDOM"; (cd "$R" && git worktree add -q "$W" -b wt-test)
(cd "$W" && echo again >> src/a.ts && git add src/a.ts)
[[ ! -e "$W/.codegraph" ]]; check "worktree-has-no-own-index" $?
CODEGRAPH_BIN="$STUB" STUB_WARN=1 ic "$W"
printf '%s' "$OUT" | grep -q 'src/caller.ts'; check "worktree-falls-back-to-main-index (warning line first)" $?
printf '%s' "$OUT" | grep -q 'different git worktree'; [[ $? -ne 0 ]]; check "warning-line-not-rendered-as-a-test-file" $?

echo "=== (l) deleted source file is examined and marked ==="
R=$(fixture_repo index); (cd "$R" && git commit -qm c2 && git rm -q src/b.ts)
CODEGRAPH_BIN="$STUB" ic "$R"
printf '%s' "$OUT" | grep -q 'src/b.ts` (deleted/renamed in this diff)'; check "deleted-file-marked" $?

echo "=== (m) staged-empty fallback is labelled ==="
R=$(fixture_repo index); (cd "$R" && git commit -qm c2)
CODEGRAPH_BIN="$STUB" ic "$R"
printf '%s' "$OUT" | grep -q 'nothing staged — showing HEAD~1..HEAD'; check "fallback-labelled" $?

echo "=== (n) header count beyond the listed names shows as +more ==="
R=$(fixture_repo index)
CODEGRAPH_BIN="$STUB" STUB_N=9 ic "$R"
printf '%s' "$OUT" | grep -q 'used by src/caller.ts (+7)'; check "unlisted-dependents-counted" $?

echo "=== (o) timeout kills the codegraph process group ==="
R=$(fixture_repo index)
CODEGRAPH_BIN="$STUB" STUB_CHILD=31.4159 IMPACT_CONTEXT_BUDGET_S=2 ic "$R"
sleep 1
pgrep -f "sleep 31.4159" >/dev/null; [[ $? -ne 0 ]]; check "no-orphaned-children" $?
pkill -f "sleep 31.4159" 2>/dev/null || true

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
