#!/usr/bin/env bash
# worktree-link-deps-test.sh — verify core/infra/worktree-link-deps.sh.
#
# Builds a temp main checkout + `git worktree add` worktree (never a real repo).
#
# Covers: (a) links node_modules/.venv from main, (b) already-linked idempotent,
# (c) existing real dir in worktree is skipped, (d) missing-in-main reported,
# (e) refuses main checkout (exit 1), (f) non-directory target (exit 2),
# (g) AGENT_LINK_DIRS override incl. nested dir, (h) AGENT_WORKSPACE_SCOPE rewrites
# relative workspace symlinks to absolute, (i) warning when not under .worktrees/.
#
# Usage: bash core/tests/worktree-link-deps-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/worktree-link-deps.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then
    echo "  ok   [$name]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name]"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
unset AGENT_LINK_DIRS AGENT_WORKSPACE_SCOPE

MAIN="$TMP_DIR/main"
mkdir -p "$MAIN"
git -C "$MAIN" init -q
git -C "$MAIN" config user.email t@example.com
git -C "$MAIN" config user.name t
echo x > "$MAIN/f.txt"
git -C "$MAIN" add f.txt
git -C "$MAIN" commit -qm init
mkdir -p "$MAIN/.worktrees"
git -C "$MAIN" worktree add -q "$MAIN/.worktrees/wt" -b wt-branch
WT="$MAIN/.worktrees/wt"

mkdir -p "$MAIN/node_modules/pkg"
# .venv intentionally absent in main

run() { (cd "$MAIN" && bash "$SCRIPT" "$@"); }

# (a)(d)
out="$(run "$WT" 2>&1)"; rc=$?
[[ $rc -eq 0 && -L "$WT/node_modules" ]]; check "links node_modules as symlink" $?
[[ "$(readlink "$WT/node_modules")" == "$MAIN/node_modules" ]]; check "symlink points to main's node_modules" $?
[[ "$out" == *".venv -> missing in main"* && ! -e "$WT/.venv" ]]; check "missing dir in main reported, not linked" $?

# (b)
out="$(run "$WT" 2>&1)"
[[ "$out" == *"node_modules -> already linked"* ]]; check "second run idempotent" $?

# (c)
rm "$WT/node_modules"
mkdir -p "$WT/node_modules"
echo keep > "$WT/node_modules/keep"
out="$(run "$WT" 2>&1)"
[[ ! -L "$WT/node_modules" && -f "$WT/node_modules/keep" && "$out" == *"skipped"* ]]; check "existing real dir preserved" $?

# (e)
run "$MAIN" >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]]; check "refuses main checkout exit 1" $?

# (f)
run "$TMP_DIR/does-not-exist" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]]; check "nonexistent target exit 2" $?

# (g) AGENT_LINK_DIRS with nested path
mkdir -p "$MAIN/apps/web/node_modules"
rm -rf "$WT/node_modules"
out="$(cd "$MAIN" && AGENT_LINK_DIRS="apps/web/node_modules" bash "$SCRIPT" "$WT" 2>&1)"
[[ -L "$WT/apps/web/node_modules" && ! -e "$WT/node_modules" ]]; check "AGENT_LINK_DIRS override with nested dir" $?

# (h) workspace scope fix-up
rm -rf "$WT/apps"
mkdir -p "$MAIN/packages/core" "$MAIN/node_modules/@org"
ln -s ../../packages/core "$MAIN/node_modules/@org/core"
(cd "$MAIN" && AGENT_WORKSPACE_SCOPE="@org" AGENT_LINK_DIRS="node_modules" bash "$SCRIPT" "$WT" >/dev/null 2>&1)
tgt="$(readlink "$MAIN/node_modules/@org/core")"
[[ "$tgt" == "$MAIN/packages/core" ]]; check "workspace symlink rewritten to absolute" $?

# (i) target outside .worktrees warns
OUT_WT="$TMP_DIR/plain"
mkdir -p "$OUT_WT"
out="$(cd "$MAIN" && AGENT_LINK_DIRS="node_modules" bash "$SCRIPT" "$OUT_WT" 2>&1)"
[[ "$out" == *"not under .worktrees/"* && -L "$OUT_WT/node_modules" ]]; check "warns but proceeds outside .worktrees/" $?

echo "worktree-link-deps-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
