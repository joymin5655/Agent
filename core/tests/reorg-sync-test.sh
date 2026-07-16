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
  printf 'mem: ~/.claude/projects/-old-prefix/memory/\n' > "$t/mem.md"     # native-memory-key (EXACT key: cwd==OLD)
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
# native-memory-key: EXACT encoded /old/prefix (-old-prefix) -> encoded /new/loc (-new-loc)
grep -q '~/.claude/projects/-new-loc/memory/' "$T/mem.md"; check "apply-native-memory-key-encoded" $?
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
# only the EXACT key rewrites (mem.md -old-prefix). A '-'-continuation key is a
# safe skip because it is indistinguishable from a dash/dot/underscore sibling
# after the /._->- fold (2026-07-16 workflow MAJOR-B) — covered in §12/§14.
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
# NOT block ('/' is a legal continuation char), so the negative lookahead (skip an
# OLD whose continuation already spells NEW) is what guarantees idempotency here
# (mutation round 2, gap D; nonce mask retired 2026-07-16 after it self-corrupted).
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
printf 'mem: ~/.claude/projects/-old-2-brain/memory/\n' > "$T5/mem.md"
bash "$TOOL" --old /old/2.brain --new /new/2.brain --root "$T5" --apply >/dev/null 2>&1
grep -q -- '-new-2-brain/memory/' "$T5/mem.md"; check "dotted-key-encoded-and-rewritten" $?
rm -rf "$T5"
# underscore path: '_' must also collapse in the encoded key — an OLD like
# /mnt/wd_black whose real key is -mnt-wd-black would otherwise be a
# silent total miss (mutation round 2, gap B).
T5B="$(mktemp -d)"
printf 'mem: ~/.claude/projects/-old-wd-black/memory/\n' > "$T5B/mem.md"
bash "$TOOL" --old /old/wd_black --new /new/nd_drive --root "$T5B" --apply >/dev/null 2>&1
grep -q -- '-new-nd-drive/memory/' "$T5B/mem.md"; check "underscore-key-encoded-and-rewritten" $?
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
# CJK memory key: EXACT -old-논문 rewrites, CJK sibling -old-논문자료 must survive.
printf 'k ~/.claude/projects/-old-논문/memory/ sib ~/.claude/projects/-old-논문자료-y/memory/\n' > "$T8/cjkkey.md"
bash "$TOOL" --old /old/논문 --new /new/기사 --root "$T8" --apply >/dev/null 2>&1
grep -q '/new/기사/paper.md' "$T8/cjk.md"; check "cjk-real-ref-rewritten" $?
grep -q '/old/논문자료/x.md' "$T8/cjk.md"; check "cjk-sibling-path-untouched" $?
grep -q -- '-new-기사/memory/' "$T8/cjkkey.md"; check "cjk-key-rewritten" $?
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
echo "=== (12) key-layer: only the EXACT key rewrites; every continuation survives (workflow MAJOR) ==="
T10="$(mktemp -d)"
# The /._->- fold is lossy, so a '-'-continuation key is ambiguous: '-x-논문-sub'
# is enc('/x/논문/sub') (deeper, would-be rewrite) AND enc('/x/논문-sub') (a dash
# sibling, must NOT). We resolve conservatively — rewrite ONLY the exact key, and
# leave EVERY continuation (dash-deeper, dash-sibling, and the punctuation/CJK-punct
# siblings ~ + @ ・) untouched. A skipped deeper key is a safe miss, not corruption.
printf 'ex ~/.claude/projects/-x-논문/memory\n'   > "$T10/keys.md"
printf 'dp ~/.claude/projects/-x-논문-sub/memory\n' >> "$T10/keys.md"
printf 's1 ~/.claude/projects/-x-논문・백업/memory\n' >> "$T10/keys.md"
printf 's2 ~/.claude/projects/-x-논문~백업/memory\n' >> "$T10/keys.md"
printf 's3 ~/.claude/projects/-x-논문+백업/memory\n' >> "$T10/keys.md"
printf 's4 ~/.claude/projects/-x-논문@백업/memory\n' >> "$T10/keys.md"
bash "$TOOL" --old /x/논문 --new /y/기사 --root "$T10" --apply >/dev/null 2>&1
grep -q -- '-y-기사/memory' "$T10/keys.md"; check "key-exact-rewritten" $?
grep -q -- '-x-논문-sub/memory' "$T10/keys.md"; check "key-dash-continuation-skipped" $?
grep -q -- '-x-논문・백업/memory' "$T10/keys.md"; check "key-cjkpunct-sibling-untouched" $?
grep -q -- '-x-논문~백업/memory' "$T10/keys.md"; check "key-tilde-sibling-untouched" $?
grep -q -- '-x-논문+백업/memory' "$T10/keys.md"; check "key-plus-sibling-untouched" $?
grep -q -- '-x-논문@백업/memory' "$T10/keys.md"; check "key-at-sibling-untouched" $?
rm -rf "$T10"

echo
echo "=== (13) NEW-extends-OLD via '/': fresh OLD refs whose text begins with NEW are still rewritten (workflow MAJOR) ==="
T11="$(mktemp -d)"
# OLD=/proj, NEW=/proj/inner. /proj/innerX and /proj/innermost are FRESH OLD refs
# whose text merely begins with NEW's prefix — the negative lookahead only skips a
# continuation that spells NEW *at a boundary* (/proj/inner then '/'|end), so these
# (inner then 'X'|'most', no boundary) still rewrite. The single true migrated ref
# /proj/x -> /proj/inner/x is what re-apply must leave alone.
printf '/proj/innerX/file\n/proj/innermost\n/proj/x\n' > "$T11/f"
bash "$TOOL" --old /proj --new /proj/inner --root "$T11" --apply >/dev/null 2>&1
grep -qx '/proj/inner/innerX/file' "$T11/f"; check "newprefix-innerX-rewritten" $?
grep -qx '/proj/inner/innermost' "$T11/f"; check "newprefix-innermost-rewritten" $?
grep -qx '/proj/inner/x' "$T11/f"; check "newprefix-plain-ref-rewritten" $?
# idempotent: on re-apply the migrated /proj/inner/x reads as "already NEW" (the
# lookahead sees /proj followed by /inner<boundary>) and is left alone.
N2="$(bash "$TOOL" --old /proj --new /proj/inner --root "$T11" --apply 2>&1)"
echo "$N2" | grep -q 'applied: rewrote 0 file(s)'; check "newprefix-idempotent" $?
rm -rf "$T11"

echo
echo "=== (14) workflow panel regressions: NONCE self-corruption + dash-key sibling (2026-07-16) ==="
T12="$(mktemp -d)"
# MAJOR-A: a subdir literally named like OLD's last component, nested under NEW.
# The old NUL-nonce mask flipped the trailing component's left-neighbor to a
# boundary and grew /proj/inner/proj unboundedly. Correct: unchanged & stable
# (leading reads as already-migrated NEW; trailing is a mid-path sibling).
printf '/proj/inner/proj\n' > "$T12/a"
bash "$TOOL" --old /proj --new /proj/inner --root "$T12" --apply >/dev/null 2>&1
A1="$(cat "$T12/a")"
bash "$TOOL" --old /proj --new /proj/inner --root "$T12" --apply >/dev/null 2>&1
A2="$(cat "$T12/a")"
[[ "$A1" == '/proj/inner/proj' && "$A2" == '/proj/inner/proj' ]]; check "panelA-nested-sibling-stable" $?
# MAJOR-A2: the pathological /a -> /a/a on /a/a/a — nonce grew it without bound.
printf '/a/a/a\n' > "$T12/b"
bash "$TOOL" --old /a --new /a/a --root "$T12" --apply >/dev/null 2>&1
B1="$(cat "$T12/b")"
bash "$TOOL" --old /a --new /a/a --root "$T12" --apply >/dev/null 2>&1
B2="$(cat "$T12/b")"
[[ "$B1" == '/a/a/a' && "$B2" == '/a/a/a' ]]; check "panelA-single-char-stable" $?
# MAJOR-B: a dash-named sibling key (enc('/Volumes/x/old-prefix2')) is byte-identical
# to a deeper key after the fold, so exact-only must leave it — while the exact key
# on the same file rewrites and the dry-run reports exactly one key hit.
printf 'ex  ~/.claude/projects/-Volumes-x-old/memory/\n'         > "$T12/k.md"
printf 'sib ~/.claude/projects/-Volumes-x-old-prefix2/memory/\n' >> "$T12/k.md"
KD="$(bash "$TOOL" --old /Volumes/x/old --new /Volumes/y/new --root "$T12" 2>&1)"
echo "$KD" | grep -q 'native-memory-key=1'; check "panelB-dryrun-reports-exact-only" $?
bash "$TOOL" --old /Volumes/x/old --new /Volumes/y/new --root "$T12" --apply >/dev/null 2>&1
grep -q -- '-Volumes-y-new/memory/' "$T12/k.md"; check "panelB-exact-key-rewritten" $?
grep -q -- '-Volumes-x-old-prefix2/memory/' "$T12/k.md"; check "panelB-dash-sibling-key-untouched" $?
rm -rf "$T12"

echo
echo "=== (15) panel3: NEW embeds OLD after a non-'/' delimiter + co-resident key/path report (2026-07-16) ==="
T13="$(mktemp -d)"
# MAJOR: NEW reintroduces OLD after a boundary delimiter (':' , space, '=') that
# _LEFT does not block. The leading-only lookahead missed the inner OLD and grew
# ':/a' per apply (/a:/a -> /a:/a:/a -> ...). Protected-span guard must make every
# apply after the first a no-op.
for pair in "/a:/a" "/a /a" "/a=/a"; do
  d="$(mktemp -d)"; printf 'ref /a/x\n' > "$d/f"
  bash "$TOOL" --old /a --new "$pair" --root "$d" --apply >/dev/null 2>&1
  A1="$(cat "$d/f")"
  bash "$TOOL" --old /a --new "$pair" --root "$d" --apply >/dev/null 2>&1
  A2="$(cat "$d/f")"
  bash "$TOOL" --old /a --new "$pair" --root "$d" --apply >/dev/null 2>&1
  A3="$(cat "$d/f")"
  [[ "$A1" == "$A2" && "$A2" == "$A3" && "$A1" == "ref ${pair}/x" ]]
  check "panel3-delim-idempotent[${pair}]" $?
  rm -rf "$d"
done
# MINOR: a line carrying BOTH a native-memory-key ref and a co-resident plain path
# ref must be reported as 2 refs across 2 classes (native-memory-key=1 AND anchor=1),
# because --apply rewrites both — the old single-class report undercounted it.
printf 'both ~/.claude/projects/-old-prefix/memory and /old/prefix/docs\n' > "$T13/mix.md"
MX="$(bash "$TOOL" --old /old/prefix --new /new/loc --root "$T13" 2>&1)"
echo "$MX" | grep -q 'summary: 2 reference(s) across 2 class(es)'; check "panel3-coresident-count-2" $?
echo "$MX" | grep -q 'anchor=1, native-memory-key=1'; check "panel3-coresident-both-classes" $?
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T13" --apply >/dev/null 2>&1
grep -q 'projects/-new-loc/memory and /new/loc/docs' "$T13/mix.md"; check "panel3-coresident-both-rewritten" $?
M2="$(bash "$TOOL" --old /old/prefix --new /new/loc --root "$T13" --apply 2>&1)"
echo "$M2" | grep -q 'rewrote 0 file(s)'; check "panel3-coresident-idempotent" $?
rm -rf "$T13"

echo
echo "=== (16) panel4: promote-up (NEW prefix of OLD) + report/apply single-source-of-truth (2026-07-16) ==="
T14="$(mktemp -d)"
# MAJOR: promote-up reorg — NEW is a boundary-prefix of OLD (/old/sub -> /old). The
# start-inside-only span guard swallowed EVERY OLD ref (rewrote 0 while report said
# anchor). Full containment must let the longer OLD (overrunning the NEW span)
# rewrite. Both refs migrate; report count == substitutions; idempotent.
printf 'ref /old/sub/backup.sh and dir /old/sub\n' > "$T14/pu"
PU="$(bash "$TOOL" --old /old/sub --new /old --root "$T14" 2>&1)"
echo "$PU" | grep -q 'summary: 2 reference(s) across 1 class(es)'; check "panel4-promoteup-reports-2" $?
bash "$TOOL" --old /old/sub --new /old --root "$T14" --apply >/dev/null 2>&1
grep -qx 'ref /old/backup.sh and dir /old' "$T14/pu"; check "panel4-promoteup-both-rewritten" $?
PU2="$(bash "$TOOL" --old /old/sub --new /old --root "$T14" --apply 2>&1)"
echo "$PU2" | grep -q 'rewrote 0 file(s)'; check "panel4-promoteup-idempotent" $?
# deeper flatten /a/b/c -> /a/b
printf 'p /a/b/c/x\n' > "$T14/fl"
bash "$TOOL" --old /a/b/c --new /a/b --root "$T14" --apply >/dev/null 2>&1
grep -qx 'p /a/b/x' "$T14/fl"; check "panel4-flatten-rewritten" $?
# MINOR (report==apply, overcount side): a fresh OLD sitting inside a literal-NEW
# span is a documented safe-miss; the dry-run must NOT count it (was reported
# anchor=1 while apply did 0 — divergence). Now honestly 0/0.
printf 'ref /data/data/backup.sh\n' > "$T14/dv"
DV="$(bash "$TOOL" --old /data --new /data/data --root "$T14" 2>&1)"
echo "$DV" | grep -q 'summary: 0 reference(s) across 0 class(es)'; check "panel4-safemiss-not-counted" $?
DVA="$(bash "$TOOL" --old /data --new /data/data --root "$T14" --apply 2>&1)"
echo "$DVA" | grep -q 'rewrote 0 file(s)'; check "panel4-safemiss-apply-0" $?
grep -qx 'ref /data/data/backup.sh' "$T14/dv"; check "panel4-safemiss-unchanged" $?
# MINOR/MAJOR (undercount side): N same-class refs on one line must count N, not 1.
printf 'see /old/prefix/a and /old/prefix/b end\n' > "$T14/mc"
MC="$(bash "$TOOL" --old /old/prefix --new /new/loc --root "$T14" 2>&1)"
echo "$MC" | grep -q 'summary: 2 reference(s) across 1 class(es)'; check "panel4-multiref-counts-2" $?
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T14" --apply >/dev/null 2>&1
grep -qx 'see /new/loc/a and /new/loc/b end' "$T14/mc"; check "panel4-multiref-both-rewritten" $?
# half-migration guard: promote-up with a co-resident memory key — key AND path both
# migrate (never a half-migrated tree where the key moved but the paths did not).
printf 'k ~/.claude/projects/-old-sub/memory and p /old/sub/x\n' > "$T14/hm"
bash "$TOOL" --old /old/sub --new /old --root "$T14" --apply >/dev/null 2>&1
grep -q 'projects/-old/memory and p /old/x' "$T14/hm"; check "panel4-promoteup-key-and-path" $?
rm -rf "$T14"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
