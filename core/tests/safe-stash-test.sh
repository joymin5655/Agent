#!/usr/bin/env bash
# safe-stash-test.sh — verify core/infra/safe-stash.sh (save / restore / list / prune).
#
# Runs entirely in a temp git repo with SAFE_STASH_ROOT and HOME pointed at temp dirs
# (never the real ~/.agent/backup).
#
# Covers: (a) save snapshots untracked files, (b) save with explicit paths, (c) missing
# path skipped, (d) nothing-to-save leaves no empty snapshot, (e) restore brings files
# back and never overwrites existing ones, (f) restore picks the newest snapshot,
# (g) restore unknown slug -> exit 1, (h) list empty / populated, (i) prune removes only
# old snapshots, (j) prune rejects non-numeric days, (k) no args / unknown cmd -> exit 2.
#
# Usage: bash core/tests/safe-stash-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/safe-stash.sh"

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home"
export SAFE_STASH_ROOT="$TMP_DIR/backup"
mkdir -p "$HOME"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
echo tracked > "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" commit -qm init

run() { (cd "$REPO" && bash "$SCRIPT" "$@"); }

# (h) empty list
out="$(run list 2>&1)"
[[ "$out" == *"(no snapshots)"* ]]; check "list empty" $?

# (d) nothing untracked -> no snapshot dir left behind
out="$(run save empty 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"no untracked files"* ]]; check "save with nothing untracked exits 0" $?
[[ -z "$(find "$SAFE_STASH_ROOT" -mindepth 1 -maxdepth 1)" ]]; check "no empty snapshot dir left" $?

# (a) save all untracked
mkdir -p "$REPO/sub/dir"
echo a > "$REPO/a.txt"
echo b > "$REPO/sub/dir/b.txt"
run save feat >/dev/null 2>&1; rc=$?
snap="$(find "$SAFE_STASH_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*-feat' | head -1)"
[[ $rc -eq 0 && -f "$snap/a.txt" && -f "$snap/sub/dir/b.txt" ]]; check "save snapshots untracked files incl. nested" $?
[[ ! -e "$snap/tracked.txt" ]]; check "save skips tracked files" $?

# (h) populated list
out="$(run list 2>&1)"
[[ "$out" == *"-feat"* && "$out" == *"2 files"* ]]; check "list shows snapshot with file count" $?

# (e) restore never overwrites; restores missing
rm "$REPO/a.txt"
echo local-edit > "$REPO/sub/dir/b.txt"
out="$(run restore feat 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$REPO/a.txt")" == "a" ]]; check "restore recreates deleted file" $?
[[ "$(cat "$REPO/sub/dir/b.txt")" == "local-edit" && "$out" == *"skipped"* ]]; check "restore preserves existing file" $?

# (b)(c) explicit paths + missing path
out="$(run save pick a.txt nope.txt 2>&1)"; rc=$?
psnap="$(find "$SAFE_STASH_ROOT" -mindepth 1 -maxdepth 1 -type d -name '*-pick' | head -1)"
[[ $rc -eq 0 && -f "$psnap/a.txt" && ! -e "$psnap/sub" ]]; check "save with explicit path only copies it" $?
[[ "$out" == *"skip missing nope.txt"* ]]; check "missing explicit path skipped with notice" $?

# (f) restore picks newest by name
mkdir -p "$SAFE_STASH_ROOT/2020-01-01-000000-multi" "$SAFE_STASH_ROOT/2030-01-01-000000-multi"
echo old > "$SAFE_STASH_ROOT/2020-01-01-000000-multi/m.txt"
echo new > "$SAFE_STASH_ROOT/2030-01-01-000000-multi/m.txt"
run restore multi >/dev/null 2>&1
[[ "$(cat "$REPO/m.txt")" == "new" ]]; check "restore picks newest snapshot" $?

# (g) unknown slug
run restore ghost >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]]; check "restore unknown slug exits 1" $?

# (i) prune only old
touch -d '40 days ago' "$SAFE_STASH_ROOT/2020-01-01-000000-multi"
out="$(run prune 30 2>&1)"; rc=$?
[[ $rc -eq 0 && ! -d "$SAFE_STASH_ROOT/2020-01-01-000000-multi" && -d "$SAFE_STASH_ROOT/2030-01-01-000000-multi" ]]
check "prune removes only snapshots older than N days" $?
[[ "$out" == *"pruned 1 snapshot(s)"* ]]; check "prune reports count" $?

# (j) invalid prune arg
run prune abc >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]]; check "prune non-numeric exits 1" $?

# (k) usage errors
run >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]]; check "no args -> usage exit 2" $?
run bogus >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]]; check "unknown command exit 2" $?
run save >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]]; check "save without slug exit 2" $?

echo "safe-stash-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
