#!/usr/bin/env bash
# Test the post-commit auto-sync DECISION logic with AGENT_AUTOSYNC_DRYRUN=1.
#
# Each case builds a throwaway git repo in $(mktemp -d), wires the hook as
# .git/hooks/post-commit, makes a commit, and asserts whether the hook emits
# "DRYRUN push origin <branch>". DRYRUN means no gitleaks/push/gh ever runs, so
# this is network-free and side-effect-free.
#
# Usage: bash core/tests/post-commit-autosync-test.sh
# Exit 0: all cases pass. Exit 1: one or more fail.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/core/git-hooks/post-commit"

PASS=0
FAIL=0

if [ ! -x "$HOOK" ]; then
  echo "FAIL — hook not found or not executable: $HOOK"
  exit 1
fi

# make_repo <branch> — create a temp repo on <branch>, echo its path
make_repo() {
  local branch="$1"
  local d
  d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "autosync test"
    git config commit.gpgsign false
    git symbolic-ref HEAD "refs/heads/$branch"
    mkdir -p "$d/.git/hooks"
    # Seed a base commit so the commit-under-test is never the ROOT commit
    # (the hook also handles root commits via --root, but real-world commits
    # have a parent; this keeps the fixture realistic).
    echo "seed" > "$d/.seed"
    git add .seed
    git commit -q -m "test: seed base commit" --no-verify
    # We invoke the hook manually (not via git) so a real commit's own
    # post-commit doesn't fire; the hook reads HEAD itself.
  )
  echo "$d"
}

# run_case <name> <repo> <expect: yes|no> — invoke hook in DRYRUN, assert push line
run_case() {
  local name="$1" repo="$2" expect="$3"
  local out
  out="$( cd "$repo" && AGENT_AUTOSYNC_DRYRUN=1 GITHUB_ACTIONS= bash "$HOOK" 2>/dev/null )"
  local got="no"
  if printf '%s\n' "$out" | grep -q "^DRYRUN push origin "; then
    got="yes"
  fi
  if [ "$got" = "$expect" ]; then
    echo "PASS — $name (expected push=$expect)"
    PASS=$((PASS + 1))
  else
    echo "FAIL — $name (expected push=$expect, got push=$got)"
    echo "  hook output: ${out:-<empty>}"
    FAIL=$((FAIL + 1))
  fi
}

# commit_file <repo> <path> — stage a file and commit on the current branch
commit_file() {
  local repo="$1" path="$2"
  (
    cd "$repo" || exit 1
    mkdir -p "$(dirname "$path")"
    echo "content $(date +%s%N)" > "$path"
    git add "$path"
    git commit -q -m "test: add $path" --no-verify
  )
}

# --- (a) agent.autosync unset/false -> inert (no DRYRUN push) -----------------
R_A="$(make_repo feat-x)"
commit_file "$R_A" "core/x.txt"
# explicitly false (also covers "unset" since git config returns nothing)
( cd "$R_A" && git config agent.autosync false )
run_case "(a) opt-in unset/false -> inert" "$R_A" "no"
rm -rf "$R_A"

# --- (b) enabled + on main -> branch gate, no push ---------------------------
R_B="$(make_repo main)"
commit_file "$R_B" "core/x.txt"
( cd "$R_B" && git config agent.autosync true )
run_case "(b) enabled on main -> branch gate" "$R_B" "no"
rm -rf "$R_B"

# --- (c) enabled + feature branch + agent-system path -> would push ----------
R_C="$(make_repo feat-sync)"
commit_file "$R_C" "core/x.txt"
( cd "$R_C" && git config agent.autosync true )
run_case "(c) enabled + feature + agent path -> push" "$R_C" "yes"
rm -rf "$R_C"

# --- (d) enabled + feature branch + non-agent path -> scope gate, no push ----
R_D="$(make_repo feat-scope)"
commit_file "$R_D" "UNRELATED_TOPLEVEL.txt"
( cd "$R_D" && git config agent.autosync true )
run_case "(d) enabled + feature + non-agent path -> scope gate" "$R_D" "no"
rm -rf "$R_D"

# --- (e) agent.autosync truly UNSET (not set at all) -> inert ---------------
R_E="$(make_repo feat-e)"
commit_file "$R_E" "core/x.txt"
# Do NOT call git config agent.autosync at all
run_case "(e) autosync truly unset -> inert" "$R_E" "no"
rm -rf "$R_E"

# --- (f) enabled + on master -> branch gate, no push -------------------------
R_F="$(make_repo master)"
commit_file "$R_F" "core/x.txt"
( cd "$R_F" && git config agent.autosync true )
run_case "(f) enabled on master -> branch gate" "$R_F" "no"
rm -rf "$R_F"

# --- (g) enabled + detached HEAD + agent-system path -> no push --------------
R_G="$(make_repo feat-g)"
commit_file "$R_G" "core/x.txt"
( cd "$R_G" && git config agent.autosync true )
# Create detached HEAD state
( cd "$R_G" && git checkout --detach -q )
run_case "(g) enabled + detached HEAD -> detached HEAD guard" "$R_G" "no"
rm -rf "$R_G"

echo ""
echo "==== Results: $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ] && exit 0
exit 1
