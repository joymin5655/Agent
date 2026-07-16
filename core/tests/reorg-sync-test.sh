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
  # boundary decoys (2026-07-15 review): none of these are hits.
  printf 'see /old/prefixed-thing/file.txt\n' > "$t/sibling.md"            # decoy: sibling path (boundary)
  printf 'slug: kebab-old-prefix-word here\n' > "$t/kebab.md"              # decoy: kebab text = encoded key shape, no consumer ctx
  printf 'mem2: ~/.claude/projects/-old-prefix2/memory/\n' > "$t/memsib.md" # decoy: sibling project's memory key
  chmod +x "$t/script.py"                                                  # shebang target is executable
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
# boundary decoys must NOT be reported (sibling path / kebab text / sibling key)
echo "$DRY" | grep -q 'sibling.md'; [[ $? -ne 0 ]]; check "dry-skips-sibling-path" $?
echo "$DRY" | grep -q 'kebab.md'; [[ $? -ne 0 ]]; check "dry-skips-kebab-text" $?
echo "$DRY" | grep -q 'memsib.md'; [[ $? -ne 0 ]]; check "dry-skips-sibling-memory-key" $?
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
# no OLD refs remain anywhere in-tree (except the skipped classes and the
# sibling decoy, which by boundary semantics legitimately keeps its longer path)
! grep -rIq "$OLD" "$T" --exclude-dir=.git --exclude=sibling.md; check "apply-no-old-refs-remain" $?
# decoys untouched: clean file and the git object store still original
grep -qx 'nothing to see here' "$T/clean.txt"; check "apply-clean-untouched" $?
grep -q "$OLD" "$T/realgit/.git/config"; check "apply-skips-git-object-store" $?
# boundary decoys untouched byte-for-byte (sibling corruption was CRITICAL-1)
grep -qx 'see /old/prefixed-thing/file.txt' "$T/sibling.md"; check "apply-sibling-path-untouched" $?
grep -qx 'slug: kebab-old-prefix-word here' "$T/kebab.md"; check "apply-kebab-text-untouched" $?
grep -qx 'mem2: ~/.claude/projects/-old-prefix2/memory/' "$T/memsib.md"; check "apply-sibling-memory-key-untouched" $?
# a deeper cwd's key ('-' continuation) DID rewrite — covered by mem.md (-old-prefix-x)
# shebang target kept its exec bit through the atomic rewrite
[[ -x "$T/script.py" ]]; check "apply-preserves-exec-bit" $?

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
bash "$TOOL" --old "$OLD" --new $'/x\ny' --root "$T3" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "guard-rejects-newline-in-new" $?
rm -rf "$T3"

echo
echo "=== (6) NEW-extends-OLD: apply converges, second run is a no-op (CRITICAL-2) ==="
T4="$(mktemp -d)"
printf 'path /proj/file.txt\n' > "$T4/a.md"
bash "$TOOL" --old /proj --new /proj_v2 --root "$T4" --apply >/dev/null 2>&1
grep -qx 'path /proj_v2/file.txt' "$T4/a.md"; check "extend-first-apply-correct" $?
E2="$(bash "$TOOL" --old /proj --new /proj_v2 --root "$T4" --apply 2>&1)"
echo "$E2" | grep -q 'applied: rewrote 0 file(s)'; check "extend-second-apply-zero" $?
grep -qx 'path /proj_v2/file.txt' "$T4/a.md"; check "extend-no-compounding" $?
rm -rf "$T4"
# NEW extends OLD via '/' continuation — the one shape the boundary anchor does
# NOT block ('/' is a legal continuation char), so nonce protection alone
# guarantees idempotency here (mutation round 2, gap D).
T4B="$(mktemp -d)"
printf 'path /proj/file.txt\n' > "$T4B/a.md"
bash "$TOOL" --old /proj --new /proj/inner --root "$T4B" --apply >/dev/null 2>&1
grep -qx 'path /proj/inner/file.txt' "$T4B/a.md"; check "slash-extend-first-apply-correct" $?
S2="$(bash "$TOOL" --old /proj --new /proj/inner --root "$T4B" --apply 2>&1)"
echo "$S2" | grep -q 'applied: rewrote 0 file(s)'; check "slash-extend-second-apply-zero" $?
grep -qx 'path /proj/inner/file.txt' "$T4B/a.md"; check "slash-extend-no-compounding" $?
rm -rf "$T4B"

echo
echo "=== (7) dotted path: '.' collapses in the encoded memory key ==="
T5="$(mktemp -d)"
printf 'mem: ~/.claude/projects/-old-2-brain-x/memory/\n' > "$T5/mem.md"
bash "$TOOL" --old /old/2.brain --new /new/2.brain --root "$T5" --apply >/dev/null 2>&1
grep -q -- '-new-2-brain-x/memory/' "$T5/mem.md"; check "dotted-key-encoded-and-rewritten" $?
rm -rf "$T5"
# underscore path: '_' must also collapse in the encoded key — an OLD like
# /mnt/wd_black whose real key is -mnt-wd-black would otherwise be a
# silent total miss (mutation round 2, gap B).
T5B="$(mktemp -d)"
printf 'mem: ~/.claude/projects/-old-wd-black-proj/memory/\n' > "$T5B/mem.md"
bash "$TOOL" --old /old/wd_black --new /new/nd_drive --root "$T5B" --apply >/dev/null 2>&1
grep -q -- '-new-nd-drive-proj/memory/' "$T5B/mem.md"; check "underscore-key-encoded-and-rewritten" $?
rm -rf "$T5B"

echo
echo "=== (8) unwritable target: reported, exit 1, rest of sweep continues ==="
T6="$(mktemp -d)"
mkdir -p "$T6/ro"
printf 'see /old/prefix/a\n' > "$T6/ro/locked.md"
printf 'see /old/prefix/b\n' > "$T6/ok.md"
chmod 555 "$T6/ro"
RO_OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T6" --apply 2>&1)"; RO_RC=$?
[[ "$RO_RC" -ne 0 ]]; check "rofail-exit-nonzero" $?
echo "$RO_OUT" | grep -q 'applied-with-errors'; check "rofail-reported" $?
grep -q '/new/loc/b' "$T6/ok.md"; check "rofail-others-still-rewritten" $?
chmod 755 "$T6/ro"; rm -rf "$T6"

echo
echo "=== (9) @keyword cron schedule classified as crontab ==="
T7="$(mktemp -d)"
printf '@daily /old/prefix/scripts/nightly.sh\n' > "$T7/jobs.crontab"
K="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T7" 2>&1)"
echo "$K" | grep -q '^  crontab '; check "at-keyword-cron-classified" $?
rm -rf "$T7"

echo
echo "=== (10) non-ASCII + punctuation sibling boundaries (MAJOR-R) ==="
T8="$(mktemp -d)"
# CJK: OLD=/old/논문, sibling /old/논문자료 must survive; real ref is rewritten.
printf 'ref /old/논문/paper.md and sib /old/논문자료/x.md\n' > "$T8/cjk.md"
# CJK memory key: -old-논문 rewrites, sibling -old-논문자료 must survive.
printf 'k ~/.claude/projects/-old-논문-x/memory/ sib ~/.claude/projects/-old-논문자료-y/memory/\n' > "$T8/cjkkey.md"
bash "$TOOL" --old /old/논문 --new /new/기사 --root "$T8" --apply >/dev/null 2>&1
grep -q '/new/기사/paper.md' "$T8/cjk.md"; check "cjk-real-ref-rewritten" $?
grep -q '/old/논문자료/x.md' "$T8/cjk.md"; check "cjk-sibling-path-untouched" $?
grep -q -- '-new-기사-x/memory/' "$T8/cjkkey.md"; check "cjk-key-rewritten" $?
grep -q -- '-old-논문자료-y/memory/' "$T8/cjkkey.md"; check "cjk-sibling-key-untouched" $?
# punctuation siblings: OLD=/old/prefix must not eat +build / @2x / ~1 / %20
printf 'p /old/prefix+build /old/prefix@2x /old/prefix~1 /old/prefix%%20 and /old/prefix/real\n' > "$T8/punct.md"
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T8" --apply >/dev/null 2>&1
grep -q '/old/prefix+build' "$T8/punct.md"; check "punct-plus-sibling-untouched" $?
grep -q '/old/prefix@2x' "$T8/punct.md"; check "punct-at-sibling-untouched" $?
grep -q '/old/prefix~1' "$T8/punct.md"; check "punct-tilde-sibling-untouched" $?
grep -q '/new/loc/real' "$T8/punct.md"; check "punct-real-ref-rewritten" $?
# delimiter boundaries DO match: quoted and colon-terminated real refs
printf 'json "%s" and path %s:/x\n' '/old/prefix' '/old/prefix' > "$T8/delim.md"
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T8" --apply >/dev/null 2>&1
grep -q '"/new/loc"' "$T8/delim.md"; check "delim-quoted-ref-rewritten" $?
grep -q '/new/loc:/x' "$T8/delim.md"; check "delim-colon-ref-rewritten" $?
# whitespace IS a boundary: a space-terminated real ref is rewritten while the
# CJK sibling on the same line survives (the reviewer MAJOR-R repro shape, on a
# domain-neutral mount path).
printf 'a /mnt/vol/논문 and /mnt/vol/논문자료 end\n' > "$T8/space.md"
bash "$TOOL" --old /mnt/vol/논문 --new /mnt/new/기사 --root "$T8" --apply >/dev/null 2>&1
grep -q '/mnt/new/기사 and' "$T8/space.md"; check "space-terminated-ref-rewritten" $?
grep -q '/mnt/vol/논문자료 end' "$T8/space.md"; check "space-line-cjk-sibling-untouched" $?
rm -rf "$T8"

echo
echo "=== (11) left boundary: OLD as the tail of an unrelated longer path (MINOR) ==="
T9="$(mktemp -d)"
# OLD=/proj/x must NOT match inside /other/tree/proj/x (a different absolute path)
printf 'unrelated /other/tree/proj/x/file.txt\nreal /proj/x/file.txt\n' > "$T9/left.md"
bash "$TOOL" --old /proj/x --new /moved/y --root "$T9" --apply >/dev/null 2>&1
grep -q '/other/tree/proj/x/file.txt' "$T9/left.md"; check "left-tail-of-longer-path-untouched" $?
grep -q '/moved/y/file.txt' "$T9/left.md"; check "left-real-ref-rewritten" $?
# path-start delimiters DO still match on the left (=, :, quote, space, BOL)
printf 'A=/proj/x\nlist=/a:/proj/x\nq="/proj/x"\n/proj/x at BOL\n' > "$T9/leftok.md"
bash "$TOOL" --old /proj/x --new /moved/y --root "$T9" --apply >/dev/null 2>&1
[[ "$(grep -c '/moved/y' "$T9/leftok.md")" -eq 4 ]]; check "left-delimiter-starts-still-match" $?
rm -rf "$T9"

echo
echo "=== (12) key-layer whitelist: punctuation/CJK-punct sibling keys survive (workflow MAJOR) ==="
T10="$(mktemp -d)"
# sibling keys continue old_key with a char that survives the /._->- encoding
# (~ + @ %, and CJK middle-dot U+30FB '・') — must NOT be rewritten; exact + deeper rewrite.
printf 'ex ~/.claude/projects/-x-논문/memory\n'   > "$T10/keys.md"
printf 'dp ~/.claude/projects/-x-논문-sub/memory\n' >> "$T10/keys.md"
printf 's1 ~/.claude/projects/-x-논문・백업/memory\n' >> "$T10/keys.md"
printf 's2 ~/.claude/projects/-x-논문~백업/memory\n' >> "$T10/keys.md"
printf 's3 ~/.claude/projects/-x-논문+백업/memory\n' >> "$T10/keys.md"
printf 's4 ~/.claude/projects/-x-논문@백업/memory\n' >> "$T10/keys.md"
bash "$TOOL" --old /x/논문 --new /y/기사 --root "$T10" --apply >/dev/null 2>&1
grep -q -- '-y-기사/memory' "$T10/keys.md"; check "key-exact-rewritten" $?
grep -q -- '-y-기사-sub/memory' "$T10/keys.md"; check "key-deeper-rewritten" $?
grep -q -- '-x-논문・백업/memory' "$T10/keys.md"; check "key-cjkpunct-sibling-untouched" $?
grep -q -- '-x-논문~백업/memory' "$T10/keys.md"; check "key-tilde-sibling-untouched" $?
grep -q -- '-x-논문+백업/memory' "$T10/keys.md"; check "key-plus-sibling-untouched" $?
grep -q -- '-x-논문@백업/memory' "$T10/keys.md"; check "key-at-sibling-untouched" $?
rm -rf "$T10"

echo
echo "=== (13) NONCE boundary-aware: NEW-shaped prefix of a real OLD ref is not eaten (workflow MAJOR) ==="
T11="$(mktemp -d)"
# OLD=/proj, NEW=/proj/inner. /proj/innerX and /proj/innermost are real OLD refs
# whose text begins with NEW — the blind-substring mask used to silently drop them.
printf '/proj/innerX/file\n/proj/innermost\n/proj/x\n' > "$T11/f"
bash "$TOOL" --old /proj --new /proj/inner --root "$T11" --apply >/dev/null 2>&1
grep -qx '/proj/inner/innerX/file' "$T11/f"; check "nonce-newprefix-innerX-rewritten" $?
grep -qx '/proj/inner/innermost' "$T11/f"; check "nonce-newprefix-innermost-rewritten" $?
grep -qx '/proj/inner/x' "$T11/f"; check "nonce-plain-ref-rewritten" $?
# and it stays idempotent (the real NEW ref /proj/inner/x is protected on re-apply)
N2="$(bash "$TOOL" --old /proj --new /proj/inner --root "$T11" --apply 2>&1)"
echo "$N2" | grep -q 'applied: rewrote 0 file(s)'; check "nonce-newprefix-idempotent" $?
rm -rf "$T11"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
