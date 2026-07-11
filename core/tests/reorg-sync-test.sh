#!/usr/bin/env bash
# reorg-sync-test.sh — battery for W-2, core/infra/reorg-sync.sh (the orphaned
# path-reference sweeper). Builds a fixture tree carrying all five reference
# classes plus decoys, and asserts: dry-run detects all five and changes nothing;
# --apply rewrites each correctly (including the native-memory-key encoding);
# binary + symlink + the .git object store are skipped while a .git worktree FILE
# is swept; the run is idempotent; and the usage guards reject a footgun.
#
# Usage: bash core/tests/reorg-sync-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO_ROOT/core/infra/reorg-sync.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

OLD="/old/prefix"
NEW="/new/loc"

# build a fresh fixture tree; echoes its path.
make_tree() {
  local t; t="$(mktemp -d)"
  mkdir -p "$t/sub" "$t/realgit/.git"
  printf '#!/old/prefix/bin/python3\nprint("x")\n' > "$t/script.py"        # shebang
  printf 'gitdir: /old/prefix/repo/.git/worktrees/wt1\n' > "$t/sub/.git"   # worktree-gitfile
  printf '0 3 * * * /old/prefix/scripts/backup.sh\n' > "$t/jobs.crontab"   # crontab
  printf 'see /old/prefix/docs/README.md\n' > "$t/notes.md"                # anchor
  printf 'mem: ~/.claude/projects/-old-prefix-x/memory/\n' > "$t/mem.md"   # native-memory-key
  printf 'nothing to see here\n' > "$t/clean.txt"                          # decoy: no match
  printf '\x00\x01/old/prefix binary\x00\n' > "$t/blob.bin"                # decoy: binary (skip)
  ln -s "$t/script.py" "$t/link.py"                                        # decoy: symlink (skip)
  printf 'config = /old/prefix/inside-object-store\n' > "$t/realgit/.git/config"  # decoy: .git store (skip)
  echo "$t"
}

echo "=== (1) dry-run: detects all 5 classes, changes nothing ==="
T="$(make_tree)"
DRY="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T" 2>&1)"
for cls in shebang worktree-gitfile crontab anchor native-memory-key; do
  echo "$DRY" | grep -q "^  $cls "; check "dry-detects:$cls" $?
done
echo "$DRY" | grep -q 'summary: 5 reference(s) across 5 class(es)'; check "dry-summary-5-across-5" $?
echo "$DRY" | grep -q 'dry-run: no files changed'; check "dry-declares-no-change" $?
# dry-run must NOT mutate: old refs still present
grep -q "$OLD" "$T/script.py"; check "dry-left-file-unchanged" $?
# the .git OBJECT STORE must be skipped even in the report
echo "$DRY" | grep -q 'inside-object-store'; [[ $? -ne 0 ]]; check "dry-skips-git-object-store" $?
# the binary decoy must be skipped
echo "$DRY" | grep -q 'blob.bin'; [[ $? -ne 0 ]]; check "dry-skips-binary" $?
rm -rf "$T"

echo
echo "=== (2) --apply: rewrites each class correctly ==="
T="$(make_tree)"
APP="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T" --apply 2>&1)"
echo "$APP" | grep -q 'applied: rewrote 5 file(s)'; check "apply-rewrote-5-files" $?
grep -qx '#!/new/loc/bin/python3' "$T/script.py"; check "apply-shebang" $?
grep -q 'gitdir: /new/loc/repo/.git/worktrees/wt1' "$T/sub/.git"; check "apply-worktree-gitfile" $?
grep -q '/new/loc/scripts/backup.sh' "$T/jobs.crontab"; check "apply-crontab" $?
grep -q '/new/loc/docs/README.md' "$T/notes.md"; check "apply-anchor" $?
# native-memory-key: encoded /old/prefix (-old-prefix) -> encoded /new/loc (-new-loc)
grep -q '~/.claude/projects/-new-loc-x/memory/' "$T/mem.md"; check "apply-native-memory-key-encoded" $?
# no OLD refs remain anywhere in-tree (except the skipped classes)
! grep -rIq "$OLD" "$T" --exclude-dir=.git; check "apply-no-old-refs-remain" $?
# decoys untouched: clean file and the git object store still original
grep -qx 'nothing to see here' "$T/clean.txt"; check "apply-clean-untouched" $?
grep -q "$OLD" "$T/realgit/.git/config"; check "apply-skips-git-object-store" $?

echo
echo "=== (3) idempotence: a second apply changes nothing ==="
APP2="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T" --apply 2>&1)"
echo "$APP2" | grep -q 'applied: rewrote 0 file(s)'; check "idempotent-second-apply-zero" $?
rm -rf "$T"

echo
echo "=== (4) no-match tree: summary 0, exit 0 (not a false hit) ==="
T2="$(mktemp -d)"; printf 'totally unrelated\n' > "$T2/a.txt"
NM="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T2" 2>&1)"; RC=$?
echo "$NM" | grep -q 'summary: 0 reference(s) across 0 class(es)'; check "no-match-summary-zero" $?
[[ "$RC" -eq 0 ]]; check "no-match-exit-0" $?
rm -rf "$T2"

echo
echo "=== (5) usage guards reject footguns ==="
T3="$(mktemp -d)"
bash "$TOOL" --old / --new "$NEW" --root "$T3" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "guard-rejects-root-slash-old" $?
bash "$TOOL" --old "$OLD" --new "$NEW" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "guard-rejects-missing-root" $?
bash "$TOOL" --old "$OLD" --root "$T3" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "guard-rejects-missing-new" $?
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T3/nope" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "guard-rejects-nonexistent-root" $?
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T3" --bogus >/dev/null 2>&1; [[ $? -ne 0 ]]; check "guard-rejects-unknown-flag" $?
rm -rf "$T3"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
