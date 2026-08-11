#!/usr/bin/env bash
# reorg-sync-test.sh — battery for W-2, core/infra/reorg-sync.sh (the orphaned
# path-reference sweeper). Builds a fixture tree carrying all five reference
# classes plus decoys, and asserts: dry-run detects all five and changes nothing;
# --apply rewrites each correctly (including the native-memory-key encoding);
# binary + non-regular files (symlink/FIFO) + the .git object store are skipped
# while a .git worktree FILE is swept; the run is idempotent; the usage guards
# reject every proven footgun (bare-/ or empty OLD, relative prefixes, any
# splitlines() separator, promote-up moves); and §17 pins the 5th adversarial
# panel's nine confirmed defects one-by-one.
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
echo "=== (16) promote-up REFUSED (5th panel CRITICAL, decision 2026-08-10) + report/apply single-source-of-truth ==="
T14="$(mktemp -d)"
# 4th panel made promote-up (NEW a boundary-prefix of OLD, /old/sub -> /old)
# rewrite via full containment; the 5th panel proved that fix created data
# corruption: after one apply a migrated ref and a FRESH /old/sub ref are
# byte-identical, so run2 eats one component per pass (/old/sub/sub/file ->
# /old/sub/file -> /old/file). No stateless rewrite can be idempotent here —
# promote-up is now REFUSED at the CLI (user decision 2026-08-10; supersedes
# the 3rd-panel "make it rewrite" direction).
printf 'ref /old/sub/backup.sh and dir /old/sub\n' > "$T14/pu"
PU="$(bash "$TOOL" --old /old/sub --new /old --root "$T14" 2>&1)"; PURC=$?
[[ "$PURC" -ne 0 ]]; check "panel5-promoteup-refused" $?
echo "$PU" | grep -qi 'promote-up'; check "panel5-promoteup-names-hazard" $?
grep -qx 'ref /old/sub/backup.sh and dir /old/sub' "$T14/pu"; check "panel5-promoteup-tree-untouched" $?
# deeper flatten /a/b/c -> /a/b: same shape, same refusal — even with --apply
printf 'p /a/b/c/x\n' > "$T14/fl"
bash "$TOOL" --old /a/b/c --new /a/b --root "$T14" --apply >/dev/null 2>&1; [[ $? -ne 0 ]]; check "panel5-flatten-refused" $?
grep -qx 'p /a/b/c/x' "$T14/fl"; check "panel5-flatten-tree-untouched" $?
# NOT promote-up: a sibling rename sharing the parent (/old/sub -> /old/sub2)
# must still run and converge.
T14B="$(mktemp -d)"
printf 's /old/sub/x\n' > "$T14B/sib"
bash "$TOOL" --old /old/sub --new /old/sub2 --root "$T14B" --apply >/dev/null 2>&1; [[ $? -eq 0 ]]; check "panel5-sibling-rename-still-allowed" $?
grep -qx 's /old/sub2/x' "$T14B/sib"; check "panel5-sibling-rename-applied" $?
rm -rf "$T14B"
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
rm -rf "$T14"

echo
echo "=== (17) panel5 regression pins: nine confirmed defects (2026-08-10) ==="
# C2 [MAJOR] key-then-path splice: both axes must rewrite at ORIGINAL-line
# positions. The old sequential re.sub let a new_key ending in ')' flip the left
# boundary of a following path ref, so --apply rewrote MORE than the report said.
T15="$(mktemp -d)"
printf 'p claude/projects/-old-x/old/x and /old/x\n' > "$T15/mix"
SP="$(bash "$TOOL" --old /old/x --new '/new (2)' --root "$T15" 2>&1)"
echo "$SP" | grep -q 'anchor=1, native-memory-key=1'; check "panel5-splice-reports-1-per-axis" $?
bash "$TOOL" --old /old/x --new '/new (2)' --root "$T15" --apply >/dev/null 2>&1
# exactly the reported matches rewrote: the mid-path /old/x (left-blocked by 'x'
# in the ORIGINAL line) survives even though the key rewrite put a ')' before it.
grep -qxF 'p claude/projects/-new (2)/old/x and /new (2)' "$T15/mix"; check "panel5-splice-apply-equals-report" $?
# C3 [MAJOR] relative OLD/NEW refused: a slash-less OLD (enc(OLD)==OLD) matched
# BOTH axes — double-counted and rewritten to the dash form.
bash "$TOOL" --old Project --new /new --root "$T15" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "panel5-relative-old-refused" $?
bash "$TOOL" --old /old --new rel/new --root "$T15" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "panel5-relative-new-refused" $?
# C4 [MAJOR] every splitlines() separator refused, not just \n: \r once passed
# the bash-only guard, was written verbatim, and each re-apply re-split the file
# and grew it without bound (15->21->33 bytes) — line injection included.
for sepname in CR VT FF LS; do
  case "$sepname" in
    CR) sep=$'\r' ;; VT) sep=$'\v' ;; FF) sep=$'\f' ;;
    LS) sep="$(printf '\xe2\x80\xa8')" ;;  # U+2028 LINE SEPARATOR (UTF-8 bytes; $' ' needs bash>=4.2)
  esac
  bash "$TOOL" --old /old --new "/x${sep}y" --root "$T15" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "panel5-separator-refused[$sepname-in-new]" $?
done
bash "$TOOL" --old "/o$(printf '\xe2\x80\xa9')ld" --new /new --root "$T15" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "panel5-separator-refused[PS-in-old]" $?
rm -rf "$T15"
# U1 [MAJOR] NFD combining mark is NOT a left boundary: macOS filenames are
# NFD-normalized, so /data/care<U+0301>/old/y let OLD=/old tail-match under the
# old blocklist and corrupted the path. Whitelist _LEFT blocks it.
T16="$(mktemp -d)"
printf 'x /data/care\xcc\x81/old/y\n' > "$T16/nfd"
ND="$(bash "$TOOL" --old /old --new /moved --root "$T16" 2>&1)"
echo "$ND" | grep -q 'summary: 0 reference(s)'; check "panel5-nfd-combining-mark-not-boundary" $?
bash "$TOOL" --old /old --new /moved --root "$T16" --apply >/dev/null 2>&1
grep -q '/data/care' "$T16/nfd" && ! grep -q '/moved' "$T16/nfd"; check "panel5-nfd-tree-unchanged" $?
# positive control: NFD text NEXT TO a genuine ref does not suppress detection.
printf 'y care\xcc\x81 /old/z\n' > "$T16/nfdok"
bash "$TOOL" --old /old --new /moved --root "$T16" --apply >/dev/null 2>&1
grep -q '/moved/z' "$T16/nfdok"; check "panel5-nfd-adjacent-ref-still-swept" $?
rm -rf "$T16"
# U2 [MAJOR data-loss] fixed temp name collision: a real file named
# <target>.reorg-sync-tmp was destroyed by being reused as the temp target.
# mkstemp's random names cannot collide.
T17="$(mktemp -d)"
printf 'KEEP-ME sentinel\n' > "$T17/victim.reorg-sync-tmp"
printf 'r /old/q\n' > "$T17/victim"
bash "$TOOL" --old /old --new /new --root "$T17" --apply >/dev/null 2>&1
grep -qx 'KEEP-ME sentinel' "$T17/victim.reorg-sync-tmp"; check "panel5-tmp-collision-file-survives" $?
grep -qx 'r /new/q' "$T17/victim"; check "panel5-tmp-collision-target-still-swept" $?
rm -rf "$T17"
# U3 [MINOR] FIFO must be skipped, not opened: open(FIFO) blocks forever on a
# writer that never comes — the old islink-only filter hung the whole sweep.
T18="$(mktemp -d)"
mkfifo "$T18/pipe"
printf 'f /old/w\n' > "$T18/norm"
bash "$TOOL" --old /old --new /new --root "$T18" --apply >/dev/null 2>&1 &
TPID=$!
FIN=1
for _ in $(seq 1 50); do kill -0 "$TPID" 2>/dev/null || { FIN=0; break; }; sleep 0.2; done
[[ "$FIN" -eq 0 ]]; check "panel5-fifo-no-hang" $?
[[ "$FIN" -ne 0 ]] && kill "$TPID" 2>/dev/null
grep -qx 'f /new/w' "$T18/norm"; check "panel5-fifo-normal-file-swept" $?
rm -rf "$T18"
# U4 [documented residual ⑧] whitespace-as-boundary sibling: the hit inside
# `/x/AB<U+3000>C` is the ACCEPTED trade-off (decision 2026-08-10: keep the
# whitespace boundary) — the pin is that the dry-run SURFACES it for review,
# never silently.
T19="$(mktemp -d)"
printf 'd /x/AB\xe3\x80\x80C/f\n' > "$T19/ws"
WS="$(bash "$TOOL" --old /x/AB --new /y/AB --root "$T19" 2>&1)"
echo "$WS" | grep -q 'anchor=1'; check "panel5-whitespace-residual-surfaced" $?
# U5 [documented residual ⑨] lossy enc(): the sibling key -x-10-Reference
# (from /x/10-Reference) is byte-identical to enc(/x/10_Reference); the pin is
# that the dry-run surfaces the collision as a key hit — reviewable, not silent.
printf 'k ~/.claude/projects/-x-10-Reference/memory\n' > "$T19/key"
KE="$(bash "$TOOL" --old /x/10_Reference --new /z/10_Reference --root "$T19" 2>&1)"
echo "$KE" | grep -q 'native-memory-key=1'; check "panel5-lossy-key-residual-surfaced" $?
rm -rf "$T19"
# ⑧⑨ must stay DOCUMENTED residuals: the skill sheet has an explicit residuals
# section naming both, and the promote-up refusal.
SKILL="$REPO_ROOT/skills/reorg-sync/SKILL.md"
grep -qi 'residual' "$SKILL" && grep -q 'U+3000\|whitespace' "$SKILL"; check "panel5-skill-documents-whitespace-residual" $?
grep -q '10_Ref\|non-injective\|lossy' "$SKILL"; check "panel5-skill-documents-lossy-key-residual" $?
grep -qi 'promote-up' "$SKILL"; check "panel5-skill-documents-promoteup-refusal" $?

echo
echo "=== (18) panel6 regression pins (2026-08-10) ==="
# C1 [CRITICAL] NEW whose LAST char is itself a boundary char flipped the left
# boundary of whatever followed it, so a component that was mid-path (unmatchable)
# before apply became matchable on the NEXT run: re-apply ate one component per
# pass (/data/data/data/x -> /backup (2026)/data/data/x -> /backup (2026)/backup
# (2026)/data/x -> ...). Fixed by _abuts: an OLD starting exactly where a
# literal-NEW span ends is migration residue, not a fresh ref.
T20="$(mktemp -d)"
for pair in "/backup (2026)" "/srv:" "/b!" "/q,"; do
  d="$(mktemp -d)"; printf 'ref /old/old/old/x\n' > "$d/f"
  bash "$TOOL" --old /old --new "$pair" --root "$d" --apply >/dev/null 2>&1
  R1="$(cat "$d/f")"
  A2="$(bash "$TOOL" --old /old --new "$pair" --root "$d" --apply 2>&1)"
  R2="$(cat "$d/f")"
  [[ "$R1" == "$R2" ]] && echo "$A2" | grep -q 'rewrote 0 file(s)'
  check "panel6-boundary-tail-NEW-idempotent[${pair}]" $?
  # and the first apply was the CORRECT single rewrite (no component eaten)
  [[ "$R1" == "ref ${pair}/old/old/x" ]]; check "panel6-boundary-tail-NEW-first-apply-exact[${pair}]" $?
  rm -rf "$d"
done
# the span guard's own case must still hold: NEW re-introducing OLD after a
# delimiter stays protected (control — this is NOT what _abuts changed).
printf 'ref /a/x\n' > "$T20/ctl"
bash "$TOOL" --old /a --new '/b!/a' --root "$T20" --apply >/dev/null 2>&1
C1="$(cat "$T20/ctl")"
bash "$TOOL" --old /a --new '/b!/a' --root "$T20" --apply >/dev/null 2>&1
[[ "$C1" == "$(cat "$T20/ctl")" && "$C1" == 'ref /b!/a/x' ]]; check "panel6-span-guard-control-still-holds" $?
# C2 [MINOR] bare '!' / '#' are no longer left boundaries — they let OLD
# tail-match inside legal directory names — while the two-char shebang sigil
# '#!' still is (both bare and leading-whitespace forms).
printf 'see /proj/c#/old/x\nsee /proj/dir!/old/x\n' > "$T20/tail"
TL="$(bash "$TOOL" --old /old --new /MOVED --root "$T20" 2>&1)"
echo "$TL" | grep -q 'summary: 0 reference(s)'; check "panel6-bang-hash-no-tail-match" $?
printf '#!/old/bin/python3\n' > "$T20/sb1"; printf '   #!/old/bin/sh\n' > "$T20/sb2"
SB="$(bash "$TOOL" --old /old --new /MOVED --root "$T20" 2>&1)"
echo "$SB" | grep -q 'shebang=2'; check "panel6-shebang-sigil-still-boundary" $?
rm -rf "$T20"
# C3 [MINOR] the key axis is anchored to the 'claude/projects/' consumer
# context: an unrelated path component that merely equals the encoded key is no
# longer rewritten, while the real memory-key ref still is.
T21="$(mktemp -d)"
printf 'claude/projects note: backup at /backup/-old-x/f\n' > "$T21/decoy"
printf 'k ~/.claude/projects/-old-x/memory\n' > "$T21/real"
KA="$(bash "$TOOL" --old /old-x --new /new-y --root "$T21" 2>&1)"
echo "$KA" | grep -q 'decoy'; [[ $? -ne 0 ]]; check "panel6-key-not-anchored-path-skipped" $?
echo "$KA" | grep -q 'native-memory-key=1'; check "panel6-key-anchored-real-ref-hit" $?
bash "$TOOL" --old /old-x --new /new-y --root "$T21" --apply >/dev/null 2>&1
grep -qxF 'claude/projects note: backup at /backup/-old-x/f' "$T21/decoy"; check "panel6-key-decoy-byte-identical" $?
rm -rf "$T21"
# C4 [MINOR] trailing slashes normalize instead of tripping the promote-up glob
# (`/a/` matched `/a/*` because '*' matches empty) or breaking the boundary match.
T22="$(mktemp -d)"
printf 'cd /a/x done\n' > "$T22/t"
bash "$TOOL" --old /a/ --new /zz --root "$T22" --apply >/dev/null 2>&1; [[ $? -eq 0 ]]; check "panel6-trailing-slash-old-accepted" $?
grep -qx 'cd /zz/x done' "$T22/t"; check "panel6-trailing-slash-old-applied" $?
bash "$TOOL" --old /old/sub/ --new /old --root "$T22" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "panel6-trailing-slash-promoteup-still-refused" $?
bash "$TOOL" --old /old/sub --new /old/ --root "$T22" >/dev/null 2>&1; [[ $? -ne 0 ]]; check "panel6-trailing-slash-new-promoteup-still-refused" $?
rm -rf "$T22"

echo
echo "=== §19 7th panel: promote-up refusal must use the MATCHER's boundary set, not '/' ==="
# The guard was a shell glob (`$OLD == $NEW/*`) that knew only '/', while the
# matcher accepts 19 boundary characters. Every non-'/' boundary therefore walked
# past the refusal and hit the exact corruption it exists to prevent: one path
# component eaten per --apply, unbounded. The panel reproduced it on all 18.
# Enumerated here rather than spot-checked, because a spot check is what let the
# class survive two review rounds.
for b in ':' ' ' ',' ';' '=' '|' '<' '>' '(' ')' '{' '}' '[' ']' '"' "'" '`' '/'; do
  TB="$(mktemp -d)"
  printf 'x /a%sb%sb%sb\n' "$b" "$b" "$b" > "$TB/f.txt"
  out="$(bash "$TOOL" --old "/a${b}b" --new /a --root "$TB" --apply 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -q 'refusing promote-up'; then ok=0; else ok=1; fi
  check "panel7-promote-up-refused-across-boundary[$b]" $ok
  rm -rf "$TB"
done
# ... and the refusal must not over-fire on the moves a real reorg actually makes
T23="$(mktemp -d)"
printf 'x /old/sub/f\n' > "$T23/f.txt"
bash "$TOOL" --old /old/sub --new /dest --root "$T23" --apply >/dev/null 2>&1
check "panel7-unrelated-destination-still-allowed" $?
grep -qF '/dest/f' "$T23/f.txt"; check "panel7-unrelated-destination-rewrote" $?
printf 'y /old/sub/f\n' > "$T23/g.txt"
bash "$TOOL" --old /old/sub --new /old/sub2 --root "$T23" --apply >/dev/null 2>&1
check "panel7-sibling-rename-still-allowed" $?
grep -qF '/old/sub2/f' "$T23/g.txt"; check "panel7-sibling-rename-rewrote" $?
rm -rf "$T23"
# The refusal also runs on the KEY axis, but that arm is currently UNREACHABLE:
# enc() folds only '/', '.' and '_' — all to '-' — and '-' is not a boundary on
# either axis, so no input makes the key arm fire without the path arm firing
# first (enumerated over every separator in U+0020..U+02FF). It is kept as
# defense in depth, and deliberately NOT asserted as coverage. What IS asserted
# is the reachable neighbour: '.' is not a boundary, so /a.b -> /a is an ordinary
# rename on both axes, and it must rewrite and then be idempotent — the property
# a wrongly-widened refusal or a wrongly-widened boundary would each break.
T24="$(mktemp -d)"
printf 'k ~/.claude/projects/-a-b/memory\np /a.b/f\n' > "$T24/f.txt"
bash "$TOOL" --old '/a.b' --new '/a' --root "$T24" --apply >/dev/null 2>&1
check "panel7-dot-separated-rename-allowed" $?
grep -qF 'claude/projects/-a/memory' "$T24/f.txt"; check "panel7-dot-rename-key-rewritten" $?
grep -qF '/a/f' "$T24/f.txt"; check "panel7-dot-rename-path-rewritten" $?
BEFORE24="$(cat "$T24/f.txt")"
bash "$TOOL" --old '/a.b' --new '/a' --root "$T24" --apply >/dev/null 2>&1
[[ "$BEFORE24" == "$(cat "$T24/f.txt")" ]]; check "panel7-dot-rename-idempotent" $?
rm -rf "$T24"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
