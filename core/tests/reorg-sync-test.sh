#!/usr/bin/env bash
# reorg-sync-test.sh — battery for W-2, core/infra/reorg-sync.sh (the orphaned
# path-reference sweeper). Builds a fixture tree carrying all five reference
# classes plus decoys, and asserts: dry-run detects all five and changes nothing;
# --apply rewrites each correctly (including the native-memory-key encoding);
# binary + non-regular files (symlink/FIFO) + the .git object store are skipped
# while a .git worktree FILE is swept; the run is idempotent; the usage guards
# reject every proven footgun (bare-/ or empty OLD, relative prefixes, any
# splitlines() separator, promote-up moves, suffix-overlap/demote moves —
# while ACCEPTING identity and enc()-collision renames); and §17 pins the 5th
# adversarial panel's nine confirmed defects one-by-one.
#
# Usage: bash core/tests/reorg-sync-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO_ROOT/core/infra/reorg-sync.sh"

# every mktemp in this file lands in one scratch dir, removed on exit; the hang-path
# child (FIFO test) runs in its own process group and is killed as a group.
TMPDIR="$(mktemp -d)"; export TMPDIR
TPID=""
cleanup() {
  [[ -n "$TPID" ]] && kill -- "-$TPID" 2>/dev/null
  chmod -R u+rwx "$TMPDIR" 2>/dev/null
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" == 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
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
  echo "$DRY" | grep -q "^  $cls " && rc=0 || rc=$?; check "dry-detects:$cls" "$rc"
done
echo "$DRY" | grep -q 'summary: 5 reference(s) across 5 class(es)' && rc=0 || rc=$?; check "dry-summary-5-across-5" "$rc"
echo "$DRY" | grep -q 'dry-run: no files changed' && rc=0 || rc=$?; check "dry-declares-no-change" "$rc"
# dry-run must NOT mutate: old refs still present
grep -q "$OLD" "$T/script.py" && rc=0 || rc=$?; check "dry-left-file-unchanged" "$rc"
# the .git OBJECT STORE must be skipped even in the report
echo "$DRY" | grep -q 'inside-object-store' && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "dry-skips-git-object-store" "$rc"
# the binary decoy must be skipped
echo "$DRY" | grep -q 'blob.bin' && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "dry-skips-binary" "$rc"
# boundary decoys must NOT be reported (sibling path / kebab text / sibling key)
echo "$DRY" | grep -q 'sibling.md' && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "dry-skips-sibling-path" "$rc"
echo "$DRY" | grep -q 'kebab.md' && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "dry-skips-kebab-text" "$rc"
echo "$DRY" | grep -q 'memsib.md' && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "dry-skips-sibling-memory-key" "$rc"
rm -rf "$T"

echo
echo "=== (2) --apply: rewrites each class correctly ==="
T="$(make_tree)"
APP="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T" --apply 2>&1)"
echo "$APP" | grep -q 'applied: rewrote 5 file(s)' && rc=0 || rc=$?; check "apply-rewrote-5-files" "$rc"
grep -qx '#!/new/loc/bin/python3' "$T/script.py" && rc=0 || rc=$?; check "apply-shebang" "$rc"
grep -q 'gitdir: /new/loc/repo/.git/worktrees/wt1' "$T/sub/.git" && rc=0 || rc=$?; check "apply-worktree-gitfile" "$rc"
grep -q '/new/loc/scripts/backup.sh' "$T/jobs.crontab" && rc=0 || rc=$?; check "apply-crontab" "$rc"
grep -q '/new/loc/docs/README.md' "$T/notes.md" && rc=0 || rc=$?; check "apply-anchor" "$rc"
# native-memory-key: EXACT encoded /old/prefix (-old-prefix) -> encoded /new/loc (-new-loc)
# shellcheck disable=SC2088  # literal tilde is the text under test
grep -q '~/.claude/projects/-new-loc/memory/' "$T/mem.md" && rc=0 || rc=$?; check "apply-native-memory-key-encoded" "$rc"
# no OLD refs remain anywhere in-tree (except the skipped classes and the
# sibling decoy, which by boundary semantics legitimately keeps its longer path)
! grep -rIq "$OLD" "$T" --exclude-dir=.git --exclude=sibling.md && rc=0 || rc=$?; check "apply-no-old-refs-remain" "$rc"
# decoys untouched: clean file and the git object store still original
grep -qx 'nothing to see here' "$T/clean.txt" && rc=0 || rc=$?; check "apply-clean-untouched" "$rc"
grep -q "$OLD" "$T/realgit/.git/config" && rc=0 || rc=$?; check "apply-skips-git-object-store" "$rc"
# boundary decoys untouched byte-for-byte (sibling corruption was CRITICAL-1)
grep -qx 'see /old/prefixed-thing/file.txt' "$T/sibling.md" && rc=0 || rc=$?; check "apply-sibling-path-untouched" "$rc"
grep -qx 'slug: kebab-old-prefix-word here' "$T/kebab.md" && rc=0 || rc=$?; check "apply-kebab-text-untouched" "$rc"
grep -qx 'mem2: ~/.claude/projects/-old-prefix2/memory/' "$T/memsib.md" && rc=0 || rc=$?; check "apply-sibling-memory-key-untouched" "$rc"
# only the EXACT key rewrites (mem.md -old-prefix). A '-'-continuation key is a
# safe skip because it is indistinguishable from a dash/dot/underscore sibling
# after the /._->- fold (2026-07-16 workflow MAJOR-B) — covered in §12/§14.
# shebang target kept its exec bit through the atomic rewrite
[[ -x "$T/script.py" ]] && rc=0 || rc=1; check "apply-preserves-exec-bit" "$rc"

echo
echo "=== (3) idempotence: a second apply changes nothing ==="
APP2="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T" --apply 2>&1)"
echo "$APP2" | grep -q 'applied: rewrote 0 file(s)' && rc=0 || rc=$?; check "idempotent-second-apply-zero" "$rc"
rm -rf "$T"

echo
echo "=== (4) no-match tree: summary 0, exit 0 (not a false hit) ==="
T2="$(mktemp -d)"; printf 'totally unrelated\n' > "$T2/a.txt"
NM="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T2" 2>&1)"; RC=$?
echo "$NM" | grep -q 'summary: 0 reference(s) across 0 class(es)' && rc=0 || rc=$?; check "no-match-summary-zero" "$rc"
[[ "$RC" -eq 0 ]] && rc=0 || rc=1; check "no-match-exit-0" "$rc"
rm -rf "$T2"

echo
echo "=== (5) usage guards reject footguns ==="
T3="$(mktemp -d)"
bash "$TOOL" --old / --new "$NEW" --root "$T3" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "guard-rejects-root-slash-old" "$rc"
bash "$TOOL" --old "$OLD" --new "$NEW" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "guard-rejects-missing-root" "$rc"
bash "$TOOL" --old "$OLD" --root "$T3" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "guard-rejects-missing-new" "$rc"
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T3/nope" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "guard-rejects-nonexistent-root" "$rc"
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T3" --bogus >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "guard-rejects-unknown-flag" "$rc"
bash "$TOOL" --old "$OLD" --new $'/x\ny' --root "$T3" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "guard-rejects-newline-in-new" "$rc"
rm -rf "$T3"

echo
echo "=== (6) NEW-extends-OLD: apply converges, second run is a no-op (CRITICAL-2) ==="
T4="$(mktemp -d)"
printf 'path /proj/file.txt\n' > "$T4/a.md"
bash "$TOOL" --old /proj --new /proj_v2 --root "$T4" --apply >/dev/null 2>&1
grep -qx 'path /proj_v2/file.txt' "$T4/a.md" && rc=0 || rc=$?; check "extend-first-apply-correct" "$rc"
E2="$(bash "$TOOL" --old /proj --new /proj_v2 --root "$T4" --apply 2>&1)"
echo "$E2" | grep -q 'applied: rewrote 0 file(s)' && rc=0 || rc=$?; check "extend-second-apply-zero" "$rc"
grep -qx 'path /proj_v2/file.txt' "$T4/a.md" && rc=0 || rc=$?; check "extend-no-compounding" "$rc"
rm -rf "$T4"
# NEW extends OLD via '/' continuation — the one shape the boundary anchor does
# NOT block ('/' is a legal continuation char), so the negative lookahead (skip an
# OLD whose continuation already spells NEW) is what guarantees idempotency here
# (mutation round 2, gap D; nonce mask retired 2026-07-16 after it self-corrupted).
T4B="$(mktemp -d)"
printf 'path /proj/file.txt\n' > "$T4B/a.md"
bash "$TOOL" --old /proj --new /proj/inner --root "$T4B" --apply >/dev/null 2>&1
grep -qx 'path /proj/inner/file.txt' "$T4B/a.md" && rc=0 || rc=$?; check "slash-extend-first-apply-correct" "$rc"
S2="$(bash "$TOOL" --old /proj --new /proj/inner --root "$T4B" --apply 2>&1)"
echo "$S2" | grep -q 'applied: rewrote 0 file(s)' && rc=0 || rc=$?; check "slash-extend-second-apply-zero" "$rc"
grep -qx 'path /proj/inner/file.txt' "$T4B/a.md" && rc=0 || rc=$?; check "slash-extend-no-compounding" "$rc"
rm -rf "$T4B"

echo
echo "=== (7) dotted path: '.' collapses in the encoded memory key ==="
T5="$(mktemp -d)"
printf 'mem: ~/.claude/projects/-old-2-brain/memory/\n' > "$T5/mem.md"
bash "$TOOL" --old /old/2.brain --new /new/2.brain --root "$T5" --apply >/dev/null 2>&1
grep -q -- '-new-2-brain/memory/' "$T5/mem.md" && rc=0 || rc=$?; check "dotted-key-encoded-and-rewritten" "$rc"
rm -rf "$T5"
# underscore path: '_' must also collapse in the encoded key — an OLD like
# /mnt/wd_black whose real key is -mnt-wd-black would otherwise be a
# silent total miss (mutation round 2, gap B).
T5B="$(mktemp -d)"
printf 'mem: ~/.claude/projects/-old-wd-black/memory/\n' > "$T5B/mem.md"
bash "$TOOL" --old /old/wd_black --new /new/nd_drive --root "$T5B" --apply >/dev/null 2>&1
grep -q -- '-new-nd-drive/memory/' "$T5B/mem.md" && rc=0 || rc=$?; check "underscore-key-encoded-and-rewritten" "$rc"
rm -rf "$T5B"

echo
echo "=== (8) unwritable target: reported, exit 1, rest of sweep continues ==="
T6="$(mktemp -d)"
mkdir -p "$T6/ro"
printf 'see /old/prefix/a\n' > "$T6/ro/locked.md"
printf 'see /old/prefix/b\n' > "$T6/ok.md"
if [[ "$EUID" -eq 0 ]]; then
  echo "  skip [rofail-*: chmod-based cases do not bind root]"
else
chmod 555 "$T6/ro"
RO_OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T6" --apply 2>&1)"; RO_RC=$?
[[ "$RO_RC" -ne 0 ]] && rc=0 || rc=1; check "rofail-exit-nonzero" "$rc"
echo "$RO_OUT" | grep -q 'applied-with-errors' && rc=0 || rc=$?; check "rofail-reported" "$rc"
grep -q '/new/loc/b' "$T6/ok.md" && rc=0 || rc=$?; check "rofail-others-still-rewritten" "$rc"
chmod 755 "$T6/ro"
fi
rm -rf "$T6"

echo
echo "=== (9) @keyword cron schedule classified as crontab ==="
T7="$(mktemp -d)"
printf '@daily /old/prefix/scripts/nightly.sh\n' > "$T7/jobs.crontab"
K="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$T7" 2>&1)"
echo "$K" | grep -q '^  crontab ' && rc=0 || rc=$?; check "at-keyword-cron-classified" "$rc"
rm -rf "$T7"

echo
echo "=== (10) non-ASCII + punctuation sibling boundaries (MAJOR-R) ==="
T8="$(mktemp -d)"
# CJK: OLD=/old/논문, sibling /old/논문자료 must survive; real ref is rewritten.
printf 'ref /old/논문/paper.md and sib /old/논문자료/x.md\n' > "$T8/cjk.md"
# CJK memory key: EXACT -old-논문 rewrites, CJK sibling -old-논문자료 must survive.
printf 'k ~/.claude/projects/-old-논문/memory/ sib ~/.claude/projects/-old-논문자료-y/memory/\n' > "$T8/cjkkey.md"
bash "$TOOL" --old /old/논문 --new /new/기사 --root "$T8" --apply >/dev/null 2>&1
grep -q '/new/기사/paper.md' "$T8/cjk.md" && rc=0 || rc=$?; check "cjk-real-ref-rewritten" "$rc"
grep -q '/old/논문자료/x.md' "$T8/cjk.md" && rc=0 || rc=$?; check "cjk-sibling-path-untouched" "$rc"
grep -q -- '-new-기사/memory/' "$T8/cjkkey.md" && rc=0 || rc=$?; check "cjk-key-rewritten" "$rc"
grep -q -- '-old-논문자료-y/memory/' "$T8/cjkkey.md" && rc=0 || rc=$?; check "cjk-sibling-key-untouched" "$rc"
# punctuation siblings: OLD=/old/prefix must not eat +build / @2x / ~1 / %20
printf 'p /old/prefix+build /old/prefix@2x /old/prefix~1 /old/prefix%%20 and /old/prefix/real\n' > "$T8/punct.md"
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T8" --apply >/dev/null 2>&1
grep -q '/old/prefix+build' "$T8/punct.md" && rc=0 || rc=$?; check "punct-plus-sibling-untouched" "$rc"
grep -q '/old/prefix@2x' "$T8/punct.md" && rc=0 || rc=$?; check "punct-at-sibling-untouched" "$rc"
grep -q '/old/prefix~1' "$T8/punct.md" && rc=0 || rc=$?; check "punct-tilde-sibling-untouched" "$rc"
grep -q '/new/loc/real' "$T8/punct.md" && rc=0 || rc=$?; check "punct-real-ref-rewritten" "$rc"
# delimiter boundaries DO match: quoted and colon-terminated real refs
printf 'json "%s" and path %s:/x\n' '/old/prefix' '/old/prefix' > "$T8/delim.md"
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T8" --apply >/dev/null 2>&1
grep -q '"/new/loc"' "$T8/delim.md" && rc=0 || rc=$?; check "delim-quoted-ref-rewritten" "$rc"
grep -q '/new/loc:/x' "$T8/delim.md" && rc=0 || rc=$?; check "delim-colon-ref-rewritten" "$rc"
# whitespace IS a boundary: a space-terminated real ref is rewritten while the
# CJK sibling on the same line survives (the reviewer MAJOR-R repro shape, on a
# domain-neutral mount path).
printf 'a /mnt/vol/논문 and /mnt/vol/논문자료 end\n' > "$T8/space.md"
bash "$TOOL" --old /mnt/vol/논문 --new /mnt/new/기사 --root "$T8" --apply >/dev/null 2>&1
grep -q '/mnt/new/기사 and' "$T8/space.md" && rc=0 || rc=$?; check "space-terminated-ref-rewritten" "$rc"
grep -q '/mnt/vol/논문자료 end' "$T8/space.md" && rc=0 || rc=$?; check "space-line-cjk-sibling-untouched" "$rc"
rm -rf "$T8"

echo
echo "=== (11) left boundary: OLD as the tail of an unrelated longer path (MINOR) ==="
T9="$(mktemp -d)"
# OLD=/proj/x must NOT match inside /other/tree/proj/x (a different absolute path)
printf 'unrelated /other/tree/proj/x/file.txt\nreal /proj/x/file.txt\n' > "$T9/left.md"
bash "$TOOL" --old /proj/x --new /moved/y --root "$T9" --apply >/dev/null 2>&1
grep -q '/other/tree/proj/x/file.txt' "$T9/left.md" && rc=0 || rc=$?; check "left-tail-of-longer-path-untouched" "$rc"
grep -q '/moved/y/file.txt' "$T9/left.md" && rc=0 || rc=$?; check "left-real-ref-rewritten" "$rc"
# path-start delimiters DO still match on the left (=, :, quote, space, BOL)
printf 'A=/proj/x\nlist=/a:/proj/x\nq="/proj/x"\n/proj/x at BOL\n' > "$T9/leftok.md"
bash "$TOOL" --old /proj/x --new /moved/y --root "$T9" --apply >/dev/null 2>&1
[[ "$(grep -c '/moved/y' "$T9/leftok.md")" -eq 4 ]] && rc=0 || rc=1; check "left-delimiter-starts-still-match" "$rc"
rm -rf "$T9"

echo
echo "=== (12) key-layer: only the EXACT key rewrites; every continuation survives (workflow MAJOR) ==="
T10="$(mktemp -d)"
# The /._->- fold is lossy, so a '-'-continuation key is ambiguous: '-x-논문-sub'
# is enc('/x/논문/sub') (deeper, would-be rewrite) AND enc('/x/논문-sub') (a dash
# sibling, must NOT). We resolve conservatively — rewrite ONLY the exact key, and
# leave EVERY continuation (dash-deeper, dash-sibling, and the punctuation/CJK-punct
# siblings ~ + @ ・) untouched. A skipped deeper key is a safe miss, not corruption.
{
  printf 'ex ~/.claude/projects/-x-논문/memory\n'
  printf 'dp ~/.claude/projects/-x-논문-sub/memory\n'
  printf 's1 ~/.claude/projects/-x-논문・백업/memory\n'
  printf 's2 ~/.claude/projects/-x-논문~백업/memory\n'
  printf 's3 ~/.claude/projects/-x-논문+백업/memory\n'
  printf 's4 ~/.claude/projects/-x-논문@백업/memory\n'
} > "$T10/keys.md"
bash "$TOOL" --old /x/논문 --new /y/기사 --root "$T10" --apply >/dev/null 2>&1
grep -q -- '-y-기사/memory' "$T10/keys.md" && rc=0 || rc=$?; check "key-exact-rewritten" "$rc"
grep -q -- '-x-논문-sub/memory' "$T10/keys.md" && rc=0 || rc=$?; check "key-dash-continuation-skipped" "$rc"
grep -q -- '-x-논문・백업/memory' "$T10/keys.md" && rc=0 || rc=$?; check "key-cjkpunct-sibling-untouched" "$rc"
grep -q -- '-x-논문~백업/memory' "$T10/keys.md" && rc=0 || rc=$?; check "key-tilde-sibling-untouched" "$rc"
grep -q -- '-x-논문+백업/memory' "$T10/keys.md" && rc=0 || rc=$?; check "key-plus-sibling-untouched" "$rc"
grep -q -- '-x-논문@백업/memory' "$T10/keys.md" && rc=0 || rc=$?; check "key-at-sibling-untouched" "$rc"
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
grep -qx '/proj/inner/innerX/file' "$T11/f" && rc=0 || rc=$?; check "newprefix-innerX-rewritten" "$rc"
grep -qx '/proj/inner/innermost' "$T11/f" && rc=0 || rc=$?; check "newprefix-innermost-rewritten" "$rc"
grep -qx '/proj/inner/x' "$T11/f" && rc=0 || rc=$?; check "newprefix-plain-ref-rewritten" "$rc"
# idempotent: on re-apply the migrated /proj/inner/x reads as "already NEW" (the
# lookahead sees /proj followed by /inner<boundary>) and is left alone.
N2="$(bash "$TOOL" --old /proj --new /proj/inner --root "$T11" --apply 2>&1)"
echo "$N2" | grep -q 'applied: rewrote 0 file(s)' && rc=0 || rc=$?; check "newprefix-idempotent" "$rc"
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
[[ "$A1" == '/proj/inner/proj' && "$A2" == '/proj/inner/proj' ]] && rc=0 || rc=1; check "panelA-nested-sibling-stable" "$rc"
# MAJOR-A2: the pathological /a -> /a/a on /a/a/a — nonce grew it without bound.
printf '/a/a/a\n' > "$T12/b"
bash "$TOOL" --old /a --new /a/a --root "$T12" --apply >/dev/null 2>&1
B1="$(cat "$T12/b")"
bash "$TOOL" --old /a --new /a/a --root "$T12" --apply >/dev/null 2>&1
B2="$(cat "$T12/b")"
[[ "$B1" == '/a/a/a' && "$B2" == '/a/a/a' ]] && rc=0 || rc=1; check "panelA-single-char-stable" "$rc"
# MAJOR-B: a dash-named sibling key (enc('/Volumes/x/old-prefix2')) is byte-identical
# to a deeper key after the fold, so exact-only must leave it — while the exact key
# on the same file rewrites and the dry-run reports exactly one key hit.
printf 'ex  ~/.claude/projects/-Volumes-x-old/memory/\n'         > "$T12/k.md"
printf 'sib ~/.claude/projects/-Volumes-x-old-prefix2/memory/\n' >> "$T12/k.md"
KD="$(bash "$TOOL" --old /Volumes/x/old --new /Volumes/y/new --root "$T12" 2>&1)"
echo "$KD" | grep -q 'native-memory-key=1' && rc=0 || rc=$?; check "panelB-dryrun-reports-exact-only" "$rc"
bash "$TOOL" --old /Volumes/x/old --new /Volumes/y/new --root "$T12" --apply >/dev/null 2>&1
grep -q -- '-Volumes-y-new/memory/' "$T12/k.md" && rc=0 || rc=$?; check "panelB-exact-key-rewritten" "$rc"
grep -q -- '-Volumes-x-old-prefix2/memory/' "$T12/k.md" && rc=0 || rc=$?; check "panelB-dash-sibling-key-untouched" "$rc"
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
  [[ "$A1" == "$A2" && "$A2" == "$A3" && "$A1" == "ref ${pair}/x" ]] && rc=0 || rc=1
  check "panel3-delim-idempotent[${pair}]" "$rc"
  rm -rf "$d"
done
# MINOR: a line carrying BOTH a native-memory-key ref and a co-resident plain path
# ref must be reported as 2 refs across 2 classes (native-memory-key=1 AND anchor=1),
# because --apply rewrites both — the old single-class report undercounted it.
printf 'both ~/.claude/projects/-old-prefix/memory and /old/prefix/docs\n' > "$T13/mix.md"
MX="$(bash "$TOOL" --old /old/prefix --new /new/loc --root "$T13" 2>&1)"
echo "$MX" | grep -q 'summary: 2 reference(s) across 2 class(es)' && rc=0 || rc=$?; check "panel3-coresident-count-2" "$rc"
echo "$MX" | grep -q 'anchor=1, native-memory-key=1' && rc=0 || rc=$?; check "panel3-coresident-both-classes" "$rc"
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T13" --apply >/dev/null 2>&1
grep -q 'projects/-new-loc/memory and /new/loc/docs' "$T13/mix.md" && rc=0 || rc=$?; check "panel3-coresident-both-rewritten" "$rc"
M2="$(bash "$TOOL" --old /old/prefix --new /new/loc --root "$T13" --apply 2>&1)"
echo "$M2" | grep -q 'rewrote 0 file(s)' && rc=0 || rc=$?; check "panel3-coresident-idempotent" "$rc"
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
[[ "$PURC" -ne 0 ]] && rc=0 || rc=1; check "panel5-promoteup-refused" "$rc"
echo "$PU" | grep -qi 'promote-up' && rc=0 || rc=$?; check "panel5-promoteup-names-hazard" "$rc"
grep -qx 'ref /old/sub/backup.sh and dir /old/sub' "$T14/pu" && rc=0 || rc=$?; check "panel5-promoteup-tree-untouched" "$rc"
# deeper flatten /a/b/c -> /a/b: same shape, same refusal — even with --apply
printf 'p /a/b/c/x\n' > "$T14/fl"
bash "$TOOL" --old /a/b/c --new /a/b --root "$T14" --apply >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel5-flatten-refused" "$rc"
grep -qx 'p /a/b/c/x' "$T14/fl" && rc=0 || rc=$?; check "panel5-flatten-tree-untouched" "$rc"
# NOT promote-up: a sibling rename sharing the parent (/old/sub -> /old/sub2)
# must still run and converge.
T14B="$(mktemp -d)"
printf 's /old/sub/x\n' > "$T14B/sib"
bash "$TOOL" --old /old/sub --new /old/sub2 --root "$T14B" --apply >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -eq 0 ]] && rc=0 || rc=1; check "panel5-sibling-rename-still-allowed" "$rc"
grep -qx 's /old/sub2/x' "$T14B/sib" && rc=0 || rc=$?; check "panel5-sibling-rename-applied" "$rc"
rm -rf "$T14B"
# MINOR (report==apply, overcount side): a fresh OLD sitting inside a literal-NEW
# span is a documented safe-miss; the dry-run must NOT count it (was reported
# anchor=1 while apply did 0 — divergence). Now honestly 0/0.
printf 'ref /data/data/backup.sh\n' > "$T14/dv"
DV="$(bash "$TOOL" --old /data --new /data/data --root "$T14" 2>&1)"
echo "$DV" | grep -q 'summary: 0 reference(s) across 0 class(es)' && rc=0 || rc=$?; check "panel4-safemiss-not-counted" "$rc"
DVA="$(bash "$TOOL" --old /data --new /data/data --root "$T14" --apply 2>&1)"
echo "$DVA" | grep -q 'rewrote 0 file(s)' && rc=0 || rc=$?; check "panel4-safemiss-apply-0" "$rc"
grep -qx 'ref /data/data/backup.sh' "$T14/dv" && rc=0 || rc=$?; check "panel4-safemiss-unchanged" "$rc"
# MINOR/MAJOR (undercount side): N same-class refs on one line must count N, not 1.
printf 'see /old/prefix/a and /old/prefix/b end\n' > "$T14/mc"
MC="$(bash "$TOOL" --old /old/prefix --new /new/loc --root "$T14" 2>&1)"
echo "$MC" | grep -q 'summary: 2 reference(s) across 1 class(es)' && rc=0 || rc=$?; check "panel4-multiref-counts-2" "$rc"
bash "$TOOL" --old /old/prefix --new /new/loc --root "$T14" --apply >/dev/null 2>&1
grep -qx 'see /new/loc/a and /new/loc/b end' "$T14/mc" && rc=0 || rc=$?; check "panel4-multiref-both-rewritten" "$rc"
rm -rf "$T14"

echo
echo "=== (17) panel5 regression pins: nine confirmed defects (2026-08-10) ==="
# C2 [MAJOR] key-then-path splice: both axes must rewrite at ORIGINAL-line
# positions. The old sequential re.sub let a new_key ending in ')' flip the left
# boundary of a following path ref, so --apply rewrote MORE than the report said.
T15="$(mktemp -d)"
printf 'p claude/projects/-old-x/old/x and /old/x\n' > "$T15/mix"
SP="$(bash "$TOOL" --old /old/x --new '/new (2)' --root "$T15" 2>&1)"
echo "$SP" | grep -q 'anchor=1, native-memory-key=1' && rc=0 || rc=$?; check "panel5-splice-reports-1-per-axis" "$rc"
bash "$TOOL" --old /old/x --new '/new (2)' --root "$T15" --apply >/dev/null 2>&1
# exactly the reported matches rewrote: the mid-path /old/x (left-blocked by 'x'
# in the ORIGINAL line) survives even though the key rewrite put a ')' before it.
grep -qxF 'p claude/projects/-new (2)/old/x and /new (2)' "$T15/mix" && rc=0 || rc=$?; check "panel5-splice-apply-equals-report" "$rc"
# C3 [MAJOR] relative OLD/NEW refused: a slash-less OLD (enc(OLD)==OLD) matched
# BOTH axes — double-counted and rewritten to the dash form.
bash "$TOOL" --old Project --new /new --root "$T15" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel5-relative-old-refused" "$rc"
bash "$TOOL" --old /old --new rel/new --root "$T15" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel5-relative-new-refused" "$rc"
# C4 [MAJOR] every splitlines() separator refused, not just \n: \r once passed
# the bash-only guard, was written verbatim, and each re-apply re-split the file
# and grew it without bound (15->21->33 bytes) — line injection included.
for sepname in CR VT FF LS; do
  case "$sepname" in
    CR) sep=$'\r' ;; VT) sep=$'\v' ;; FF) sep=$'\f' ;;
    LS) sep="$(printf '\xe2\x80\xa8')" ;;  # U+2028 LINE SEPARATOR (UTF-8 bytes; $' ' needs bash>=4.2)
  esac
  bash "$TOOL" --old /old --new "/x${sep}y" --root "$T15" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel5-separator-refused[$sepname-in-new]" "$rc"
done
bash "$TOOL" --old "/o$(printf '\xe2\x80\xa9')ld" --new /new --root "$T15" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel5-separator-refused[PS-in-old]" "$rc"
rm -rf "$T15"
# U1 [MAJOR] NFD combining mark is NOT a left boundary: macOS filenames are
# NFD-normalized, so /data/care<U+0301>/old/y let OLD=/old tail-match under the
# old blocklist and corrupted the path. Whitelist _LEFT blocks it.
T16="$(mktemp -d)"
printf 'x /data/care\xcc\x81/old/y\n' > "$T16/nfd"
ND="$(bash "$TOOL" --old /old --new /moved --root "$T16" 2>&1)"
echo "$ND" | grep -q 'summary: 0 reference(s)' && rc=0 || rc=$?; check "panel5-nfd-combining-mark-not-boundary" "$rc"
bash "$TOOL" --old /old --new /moved --root "$T16" --apply >/dev/null 2>&1
grep -q '/data/care' "$T16/nfd" && ! grep -q '/moved' "$T16/nfd" && rc=0 || rc=$?; check "panel5-nfd-tree-unchanged" "$rc"
# positive control: NFD text NEXT TO a genuine ref does not suppress detection.
printf 'y care\xcc\x81 /old/z\n' > "$T16/nfdok"
bash "$TOOL" --old /old --new /moved --root "$T16" --apply >/dev/null 2>&1
grep -q '/moved/z' "$T16/nfdok" && rc=0 || rc=$?; check "panel5-nfd-adjacent-ref-still-swept" "$rc"
rm -rf "$T16"
# U2 [MAJOR data-loss] fixed temp name collision: a real file named
# <target>.reorg-sync-tmp was destroyed by being reused as the temp target.
# mkstemp's random names cannot collide.
T17="$(mktemp -d)"
printf 'KEEP-ME sentinel\n' > "$T17/victim.reorg-sync-tmp"
printf 'r /old/q\n' > "$T17/victim"
bash "$TOOL" --old /old --new /new --root "$T17" --apply >/dev/null 2>&1
grep -qx 'KEEP-ME sentinel' "$T17/victim.reorg-sync-tmp" && rc=0 || rc=$?; check "panel5-tmp-collision-file-survives" "$rc"
grep -qx 'r /new/q' "$T17/victim" && rc=0 || rc=$?; check "panel5-tmp-collision-target-still-swept" "$rc"
rm -rf "$T17"
# U3 [MINOR] FIFO must be skipped, not opened: open(FIFO) blocks forever on a
# writer that never comes — the old islink-only filter hung the whole sweep.
T18="$(mktemp -d)"
mkfifo "$T18/pipe"
printf 'f /old/w\n' > "$T18/norm"
set -m
bash "$TOOL" --old /old --new /new --root "$T18" --apply >/dev/null 2>&1 &
TPID=$!
set +m
FIN=1
for _ in $(seq 1 50); do kill -0 "$TPID" 2>/dev/null || { FIN=0; break; }; sleep 0.2; done
[[ "$FIN" -eq 0 ]] && rc=0 || rc=1; check "panel5-fifo-no-hang" "$rc"
[[ "$FIN" -ne 0 ]] && kill "$TPID" 2>/dev/null
grep -qx 'f /new/w' "$T18/norm" && rc=0 || rc=$?; check "panel5-fifo-normal-file-swept" "$rc"
rm -rf "$T18"
# U4 [documented residual ⑧] whitespace-as-boundary sibling: the hit inside
# `/x/AB<U+3000>C` is the ACCEPTED trade-off (decision 2026-08-10: keep the
# whitespace boundary) — the pin is that the dry-run SURFACES it for review,
# never silently.
T19="$(mktemp -d)"
printf 'd /x/AB\xe3\x80\x80C/f\n' > "$T19/ws"
WS="$(bash "$TOOL" --old /x/AB --new /y/AB --root "$T19" 2>&1)"
echo "$WS" | grep -q 'anchor=1' && rc=0 || rc=$?; check "panel5-whitespace-residual-surfaced" "$rc"
# U5 [documented residual ⑨] lossy enc(): the sibling key -x-10-Reference
# (from /x/10-Reference) is byte-identical to enc(/x/10_Reference); the pin is
# that the dry-run surfaces the collision as a key hit — reviewable, not silent.
printf 'k ~/.claude/projects/-x-10-Reference/memory\n' > "$T19/key"
KE="$(bash "$TOOL" --old /x/10_Reference --new /z/10_Reference --root "$T19" 2>&1)"
echo "$KE" | grep -q 'native-memory-key=1' && rc=0 || rc=$?; check "panel5-lossy-key-residual-surfaced" "$rc"
rm -rf "$T19"
# ⑧⑨ must stay DOCUMENTED residuals: the skill sheet has an explicit residuals
# section naming both, and the promote-up refusal.
SKILL="$REPO_ROOT/skills/reorg-sync/SKILL.md"
grep -qi 'residual' "$SKILL" && grep -q 'U+3000\|whitespace' "$SKILL" && rc=0 || rc=$?; check "panel5-skill-documents-whitespace-residual" "$rc"
grep -q '10_Ref\|non-injective\|lossy' "$SKILL" && rc=0 || rc=$?; check "panel5-skill-documents-lossy-key-residual" "$rc"
grep -qi 'promote-up' "$SKILL" && rc=0 || rc=$?; check "panel5-skill-documents-promoteup-refusal" "$rc"

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
  [[ "$R1" == "$R2" ]] && echo "$A2" | grep -q 'rewrote 0 file(s)' && rc=0 || rc=1
  check "panel6-boundary-tail-NEW-idempotent[${pair}]" "$rc"
  # and the first apply was the CORRECT single rewrite (no component eaten)
  [[ "$R1" == "ref ${pair}/old/old/x" ]] && rc=0 || rc=1; check "panel6-boundary-tail-NEW-first-apply-exact[${pair}]" "$rc"
  rm -rf "$d"
done
# the span guard's own case must still hold: NEW re-introducing OLD after a
# delimiter stays protected (control — this is NOT what _abuts changed).
printf 'ref /a/x\n' > "$T20/ctl"
bash "$TOOL" --old /a --new '/b!/a' --root "$T20" --apply >/dev/null 2>&1
C1="$(cat "$T20/ctl")"
bash "$TOOL" --old /a --new '/b!/a' --root "$T20" --apply >/dev/null 2>&1
[[ "$C1" == "$(cat "$T20/ctl")" && "$C1" == 'ref /b!/a/x' ]] && rc=0 || rc=1; check "panel6-span-guard-control-still-holds" "$rc"
# C2 [MINOR] bare '!' / '#' are no longer left boundaries — they let OLD
# tail-match inside legal directory names — while the two-char shebang sigil
# '#!' still is (both bare and leading-whitespace forms).
printf 'see /proj/c#/old/x\nsee /proj/dir!/old/x\n' > "$T20/tail"
TL="$(bash "$TOOL" --old /old --new /MOVED --root "$T20" 2>&1)"
echo "$TL" | grep -q 'summary: 0 reference(s)' && rc=0 || rc=$?; check "panel6-bang-hash-no-tail-match" "$rc"
printf '#!/old/bin/python3\n' > "$T20/sb1"; printf '   #!/old/bin/sh\n' > "$T20/sb2"
SB="$(bash "$TOOL" --old /old --new /MOVED --root "$T20" 2>&1)"
echo "$SB" | grep -q 'shebang=2' && rc=0 || rc=$?; check "panel6-shebang-sigil-still-boundary" "$rc"
rm -rf "$T20"
# C3 [MINOR] the key axis is anchored to the 'claude/projects/' consumer
# context: an unrelated path component that merely equals the encoded key is no
# longer rewritten, while the real memory-key ref still is.
T21="$(mktemp -d)"
printf 'claude/projects note: backup at /backup/-old-x/f\n' > "$T21/decoy"
printf 'k ~/.claude/projects/-old-x/memory\n' > "$T21/real"
KA="$(bash "$TOOL" --old /old-x --new /new-y --root "$T21" 2>&1)"
echo "$KA" | grep -q 'decoy' && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel6-key-not-anchored-path-skipped" "$rc"
echo "$KA" | grep -q 'native-memory-key=1' && rc=0 || rc=$?; check "panel6-key-anchored-real-ref-hit" "$rc"
bash "$TOOL" --old /old-x --new /new-y --root "$T21" --apply >/dev/null 2>&1
grep -qxF 'claude/projects note: backup at /backup/-old-x/f' "$T21/decoy" && rc=0 || rc=$?; check "panel6-key-decoy-byte-identical" "$rc"
rm -rf "$T21"
# C4 [MINOR] trailing slashes normalize instead of tripping the promote-up glob
# (`/a/` matched `/a/*` because '*' matches empty) or breaking the boundary match.
T22="$(mktemp -d)"
printf 'cd /a/x done\n' > "$T22/t"
bash "$TOOL" --old /a/ --new /zz --root "$T22" --apply >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -eq 0 ]] && rc=0 || rc=1; check "panel6-trailing-slash-old-accepted" "$rc"
grep -qx 'cd /zz/x done' "$T22/t" && rc=0 || rc=$?; check "panel6-trailing-slash-old-applied" "$rc"
bash "$TOOL" --old /old/sub/ --new /old --root "$T22" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel6-trailing-slash-promoteup-still-refused" "$rc"
bash "$TOOL" --old /old/sub --new /old/ --root "$T22" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc -ne 0 ]] && rc=0 || rc=1; check "panel6-trailing-slash-new-promoteup-still-refused" "$rc"
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
grep -qF '/dest/f' "$T23/f.txt" && rc=0 || rc=$?; check "panel7-unrelated-destination-rewrote" "$rc"
printf 'y /old/sub/f\n' > "$T23/g.txt"
bash "$TOOL" --old /old/sub --new /old/sub2 --root "$T23" --apply >/dev/null 2>&1
check "panel7-sibling-rename-still-allowed" $?
grep -qF '/old/sub2/f' "$T23/g.txt" && rc=0 || rc=$?; check "panel7-sibling-rename-rewrote" "$rc"
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
grep -qF 'claude/projects/-a/memory' "$T24/f.txt" && rc=0 || rc=$?; check "panel7-dot-rename-key-rewritten" "$rc"
grep -qF '/a/f' "$T24/f.txt" && rc=0 || rc=$?; check "panel7-dot-rename-path-rewritten" "$rc"
BEFORE24="$(cat "$T24/f.txt")"
bash "$TOOL" --old '/a.b' --new '/a' --root "$T24" --apply >/dev/null 2>&1
[[ "$BEFORE24" == "$(cat "$T24/f.txt")" ]] && rc=0 || rc=1; check "panel7-dot-rename-idempotent" "$rc"
rm -rf "$T24"

echo
echo "=== §20 7th panel: re-apply is a NO-OP for every shape the panel broke ==="
# Families B and C. Ten of the thirteen findings were one contract violation
# wearing different clothes — a 2nd --apply with identical arguments rewrote
# again, eating a path component per pass. Asserted as a TABLE rather than as ten
# hand-written cases, because the failure was never in one exotic input: it was
# that "the tool does not touch what it already wrote" had three separate holes
# (cross-axis spans, non-overlapping span scan, manufactured left context).
#
# Each row asserts BOTH halves of the contract: the file is byte-identical after
# the 2nd apply, AND the 2nd dry-run reports 0 references. Byte-identity alone
# would pass a tool that reports work it does not do (report/apply divergence,
# a defect this suite has caught before).
idem_case() {  # idem_case <label> <old> <new> <content>
  local label="$1" o="$2" n="$3" content="$4"
  local D; D="$(mktemp -d)"
  printf '%b' "$content" > "$D/f.txt"
  bash "$TOOL" --old "$o" --new "$n" --root "$D" --apply >/dev/null 2>&1
  local first; first="$(cat "$D/f.txt")"
  bash "$TOOL" --old "$o" --new "$n" --root "$D" --apply >/dev/null 2>&1
  [[ "$first" == "$(cat "$D/f.txt")" ]] && rc=0 || rc=1; check "panel7-idempotent[$label]" "$rc"
  local rep; rep="$(bash "$TOOL" --old "$o" --new "$n" --root "$D" 2>&1)"
  printf '%s' "$rep" | grep -qE 'summary: 0 reference'
  check "panel7-second-report-is-zero[$label]" $?
  rm -rf "$D"
}
# family B — cross-axis spans, overrun, self-similar NEW
idem_case "cross-axis-key-flips-path" /old/x '/backup (2026)' \
  'k: ~/.claude/projects/-old-x/old/x\n'
idem_case "cross-axis-with-extra-ref" /old/x '/backup (2026)' \
  'k: ~/.claude/projects/-old-x/old/x\nmore /old/x/y\n'
idem_case "old-overruns-new-span" /old/sub '/B(1)/old' '/old/sub/sub/sub/f\n'
idem_case "self-similar-new" /o '/b (x)/b (x)' '/b (x)/o/o/y\n'
# family C — NEW manufactures the key axis's `claude/projects/` left context
idem_case "new-manufactures-key-ctx" /old '/n/claude/projects' '/old/-old\n'
idem_case "manufactured-ctx-two-lines" /x '/claude/projects' \
  'memkey ~/.claude/projects/-x/memory\npath /x/-x/f\n'
idem_case "manufactured-ctx-short" /a '/q/claude/projects' '/a/-a\n'
# controls: ordinary moves must still be idempotent (a fix that suppresses
# everything would pass every row above and be useless)
idem_case "plain-rename-both-axes" /old /new \
  'x /old/f\ny ~/.claude/projects/-old/memory\n'
idem_case "colon-bearing-destination" /srv:cache /srv2 'gitdir: /srv:cache/.git\n'
# ...and the FIRST apply must actually have done the work, or "idempotent" is
# just "does nothing". Pinned separately so over-suppression cannot hide here.
T25="$(mktemp -d)"
printf 'x /old/f\ny ~/.claude/projects/-old/memory\n' > "$T25/f.txt"
bash "$TOOL" --old /old --new /new --root "$T25" --apply >/dev/null 2>&1
grep -qF '/new/f' "$T25/f.txt" && rc=0 || rc=$?; check "panel7-control-path-actually-rewrote" "$rc"
grep -qF 'projects/-new/memory' "$T25/f.txt" && rc=0 || rc=$?; check "panel7-control-key-actually-rewrote" "$rc"
rm -rf "$T25"

echo
echo "=== (21) 8th adversarial panel: refusal-arm precision + span left-anchor drop ==="
# The 8th panel's 16 CONFIRMED findings reduce to three root causes, pinned here:
#   (a) the boundary regexes' `$` alternative made the promote-up arms fire on a
#       ZERO-LENGTH remainder — refusing identity moves outright, and (via the
#       lossy enc() fold) refusing ANY rename that changes only '/', '.', '_';
#   (b) the mirror of promote-up was unguarded: a proper suffix of OLD equal to
#       a boundary-terminated prefix of NEW makes pre-existing text + written
#       NEW byte-identical to a fresh ref — each re-apply ate one LEADING
#       component (reproduced on all 18 non-'/' boundary chars, and on the
#       pure-'/' CONTAINED spelling);
#   (c) _new_spans required _LEFT at a span start, but a splice puts NEW's last
#       char on an ADJACENT written span's left — when that is not a boundary
#       char the span went unrecognized and the tool rewrote its own output.
refuse_case() {  # refuse_case <label> <old> <new> <expected-stderr-substring>
  local label="$1" o="$2" n="$3" want="$4"
  local D rc err; D="$(mktemp -d)"
  err="$(bash "$TOOL" --old "$o" --new "$n" --root "$D" 2>&1 >/dev/null)"; rc=$?
  [[ $rc -eq 1 ]] && rc=0 || rc=1; check "panel8-refused[$label]" "$rc"
  printf '%s' "$err" | grep -qF "$want" && rc=0 || rc=$?; check "panel8-refusal-names-hazard[$label]" "$rc"
  rm -rf "$D"
}
accept_case() {  # accept_case <label> <old> <new>  — exit 0, no refusal on stderr
  local label="$1" o="$2" n="$3"
  local D rc err; D="$(mktemp -d)"
  err="$(bash "$TOOL" --old "$o" --new "$n" --root "$D" 2>&1 >/dev/null)"; rc=$?
  [[ $rc -eq 0 ]] && rc=0 || rc=1; check "panel8-accepted[$label]" "$rc"
  ! printf '%s' "$err" | grep -q 'refusing' && rc=0 || rc=$?; check "panel8-no-refusal-msg[$label]" "$rc"
  rm -rf "$D"
}
# (a) identity and enc()-collision moves are NOT promote-ups (contract 6b)
accept_case "identity" /a /a
accept_case "identity-trailing-slash" /a/ /a
accept_case "enc-collision-underscore" /x/10_Reference /x/10-Reference
accept_case "enc-collision-dot" /a_b /a.b
# ...and the enc()-collision sweep actually works: path axis rewrites, key axis
# reports an honest 0 (old_key == new_key: nothing to change), and it is
# idempotent. Without the actually-rewrote control, over-refusal removed and
# over-suppression added would cancel out invisibly.
T26="$(mktemp -d)"
printf 'doc /x/10_Reference/notes.md\nkey ~/.claude/projects/-x-10-Reference/memory/MEMORY.md\n' > "$T26/f.md"
REP="$(bash "$TOOL" --old /x/10_Reference --new /x/10-Reference --root "$T26" 2>&1)"
printf '%s' "$REP" | grep -q 'anchor=1' && rc=0 || rc=$?; check "panel8-enc-collision-path-detected" "$rc"
printf '%s' "$REP" | grep -q 'native-memory-key=0' && rc=0 || rc=$?; check "panel8-enc-collision-key-honest-zero" "$rc"
bash "$TOOL" --old /x/10_Reference --new /x/10-Reference --root "$T26" --apply >/dev/null 2>&1
grep -qF '/x/10-Reference/notes.md' "$T26/f.md" && rc=0 || rc=$?; check "panel8-enc-collision-actually-rewrote" "$rc"
grep -qF 'projects/-x-10-Reference/memory' "$T26/f.md" && rc=0 || rc=$?; check "panel8-enc-collision-key-untouched" "$rc"
rm -rf "$T26"
# (a') the key arm is independently REACHABLE (the old comment claimed it was
# not): enc() preserves ':' , so old_key extends new_key while the path arm
# sees no prefix — a key-only promote-up, refused with the key-axis message.
refuse_case "key-only-promote-up" '/a.b:c' /a/b \
  "refusing promote-up on the encoded native-memory key"
refuse_case "key-only-promote-up-space" '/vol/a.b (2026)' /vol/a/b \
  "refusing promote-up on the encoded native-memory key"
# (b) suffix-overlap (demote) refusals — contained, pure-slash, and partial
refuse_case "demote-colon" '/srv:/app' /app "refusing suffix-overlap"
refuse_case "demote-pure-slash" /a/b /b "refusing suffix-overlap"
refuse_case "demote-space" '/x (2)/app' /app "refusing suffix-overlap"
refuse_case "partial-overlap" /a/b /b/c "refusing suffix-overlap"
# (b') ...but the k range must EXCLUDE k == len(OLD): the extends case is the
# span guard's job, not a refusal — and unrelated names never trip the arm.
accept_case "extends-not-a-demote" /proj /proj/inner
accept_case "shared-chars-no-boundary-affix" /data /dat
accept_case "embedded-after-delimiter" /a '/a:/a'
# (c) adjacent matches: OLD ending in a boundary char can match back-to-back;
# the splice flips the second span's left neighbour to NEW's last char, which a
# left-bounded span scan no longer recognizes. Both idempotency halves plus the
# first-apply control (the fix must not suppress the legitimate first pass).
T27="$(mktemp -d)"
printf '/srv:/srv:/etc/app.conf\n' > "$T27/f.txt"
bash "$TOOL" --old '/srv:' --new '/vol:/srv:/v2' --root "$T27" --apply >/dev/null 2>&1
[[ "$(cat "$T27/f.txt")" == '/vol:/srv:/v2/vol:/srv:/v2/etc/app.conf' ]] && rc=0 || rc=1
check "panel8-adjacent-first-apply-correct" "$rc"
rm -rf "$T27"
idem_case "adjacent-matches-flip-span-left" '/srv:' '/vol:/srv:/v2' \
  '/srv:/srv:/etc/app.conf\n'

echo
echo "=== (22) 9th adversarial panel: contained-NEW arm, key-axis mirror scope, .git reverse pointers ==="
# Three root causes from the 9th panel:
#   (a) CRITICAL — the 8th-round k-loop knew only NEW-as-SUFFIX-of-OLD; NEW
#       STRICTLY INSIDE OLD (OLD = S + NEW + P, boundary after NEW) walked past
#       both refusal arms and ate one leading component per --apply.
#   (b) MAJOR overreach — the mirror family fired on the KEY axis, where a
#       straddling re-match is unconstructible (key_pat is pinned by the
#       fixed-width claude/projects/ lookbehind), refusing provably safe moves.
#   (c) MAJOR — the worktree link is double-ended, but the blanket .git prune
#       skipped the repo-side reverse pointer .git/worktrees/<name>/gitdir.
# (a) contained-NEW refusals — internal offset, every junction flavour
refuse_case "contained-colon" '/srv:/app/bin' /app "refusing suffix-overlap"
refuse_case "contained-deeper" '/srv:/app/data' /app "refusing suffix-overlap"
refuse_case "contained-pure-slash" /a/b/c /b "refusing suffix-overlap"
refuse_case "contained-space-junction" '/x (2)/app/tail' /app "refusing suffix-overlap"
# ...and the refused input's tree stays byte-untouched even under --apply
T28="$(mktemp -d)"
printf 'PYTHONPATH=/srv:/srv:/app/bin/bin/lib\n' > "$T28/env.sh"
bash "$TOOL" --old '/srv:/app/bin' --new /app --root "$T28" --apply >/dev/null 2>&1; brc=$?
[[ $brc -eq 1 && "$(cat "$T28/env.sh")" == 'PYTHONPATH=/srv:/srv:/app/bin/bin/lib' ]] && rc=0 || rc=1
check "panel9-refused-apply-leaves-tree-untouched" "$rc"
rm -rf "$T28"
# non-boundary junction after the embedded NEW is NOT the hazard shape
accept_case "contained-nonboundary-after" /data/appx /app
# (b) key-axis mirror overreach gone: keys -x-a-b / -a-b suffix-overlap but the
# path axis is clean — must sweep, and idempotently (the unconstructibility
# argument is load-bearing here, so both halves are asserted)
accept_case "key-suffix-overlap-is-safe" /x/a_b /a/b
idem_case "key-mirror-sweeps-idempotently" /x/a_b /a/b \
  'k ~/.claude/projects/-x-a-b/memory\np /x/a_b/f\n'
T29="$(mktemp -d)"
printf 'k ~/.claude/projects/-x-a-b/memory\n' > "$T29/f.md"
bash "$TOOL" --old /x/a_b --new /a/b --root "$T29" --apply >/dev/null 2>&1
grep -qF 'projects/-a-b/memory' "$T29/f.md" && rc=0 || rc=$?; check "panel9-key-mirror-actually-rewrote" "$rc"
rm -rf "$T29"
# ...while the key-axis PROMOTE-UP arm still fires (scope was narrowed, not lost)
refuse_case "key-promote-up-still-refused" '/a.b:c' /a/b \
  "refusing promote-up on the encoded native-memory key"
# (c) repo-side worktree reverse pointer swept; .git siblings and store stay skipped
T30="$(mktemp -d)"
mkdir -p "$T30/repo/.git/worktrees/wt1" "$T30/repo/.git/objects/ab" "$T30/wt1"
printf '/old/x/wt1/.git\n' > "$T30/repo/.git/worktrees/wt1/gitdir"
printf 'ref: /old/x/decoy\n' > "$T30/repo/.git/worktrees/wt1/HEAD"
printf 'x /old/x/in-store\n' > "$T30/repo/.git/objects/ab/cd"
printf '/old/x/config-decoy\n' > "$T30/repo/.git/config"
printf 'gitdir: /old/x/repo/.git/worktrees/wt1\n' > "$T30/wt1/.git"
REP="$(bash "$TOOL" --old /old/x --new /new/y --root "$T30" 2>&1)"
printf '%s' "$REP" | grep -q 'worktrees/wt1/gitdir:1' && rc=0 || rc=$?; check "panel9-reverse-pointer-reported" "$rc"
printf '%s' "$REP" | grep -q 'summary: 2 reference(s)' && rc=0 || rc=$?; check "panel9-reverse-pointer-count" "$rc"
bash "$TOOL" --old /old/x --new /new/y --root "$T30" --apply >/dev/null 2>&1
grep -qF '/new/y/wt1/.git' "$T30/repo/.git/worktrees/wt1/gitdir"
check "panel9-reverse-pointer-rewritten" $?
grep -qF 'gitdir: /new/y/repo' "$T30/wt1/.git" && rc=0 || rc=$?; check "panel9-checkout-side-rewritten" "$rc"
grep -qF '/old/x/decoy' "$T30/repo/.git/worktrees/wt1/HEAD" && rc=0 || rc=$?; check "panel9-worktree-HEAD-skipped" "$rc"
grep -qF '/old/x/in-store' "$T30/repo/.git/objects/ab/cd" && rc=0 || rc=$?; check "panel9-object-store-skipped" "$rc"
grep -qF '/old/x/config-decoy' "$T30/repo/.git/config" && rc=0 || rc=$?; check "panel9-git-config-skipped" "$rc"
rm -rf "$T30"
# documented ctx-overlap cost pinned (9th panel MINOR): NEW='/projects' is
# literal text inside 'claude/projects/', so every key context window overlaps
# a NEW span and the key class reports an honest 0 — a safe miss, REQUIRED
# because partial manufacture ('claude' + rewritten path + '/') is real. The
# path axis still sweeps.
T31="$(mktemp -d)"
printf 'k ~/.claude/projects/-old-x/memory\np /old/x/f\n' > "$T31/f.md"
REP="$(bash "$TOOL" --old /old/x --new /projects --root "$T31" 2>&1)"
printf '%s' "$REP" | grep -q 'native-memory-key=0' && rc=0 || rc=$?; check "panel9-ctx-overlap-key-honest-zero" "$rc"
printf '%s' "$REP" | grep -q 'anchor=1' && rc=0 || rc=$?; check "panel9-ctx-overlap-path-still-swept" "$rc"
bash "$TOOL" --old /old/x --new /projects --root "$T31" --apply >/dev/null 2>&1
grep -qF 'projects/-old-x/memory' "$T31/f.md" && rc=0 || rc=$?; check "panel9-ctx-overlap-key-never-corrupted" "$rc"
rm -rf "$T31"

echo
echo "=== (23) 10th adversarial panel: cross-axis straddle refusal + ctx-overlap generalization ==="
# Two root causes:
#   (a) CRITICAL — PATH-on-KEY straddle, the one constructible cross-axis
#       direction: when OLD contains 'claude/projects/' followed by a prefix
#       of the ENCODED new key, pass 1's key splice manufactures a byte-exact
#       fresh path-OLD and pass 2's path arm destroys the migrated key
#       (key-on-key and key-on-path are unconstructible; path-on-path is the
#       §21/§22 mirror family).
#   (b) MAJOR — the §22 "exactly NEW='/projects'" claim was falsified: ANY NEW
#       whose literal text can overlay 'claude/projects/' (suffix-overlap like
#       '/home/u/.claude', substring like '/projects', containment like
#       family C) zeroes the key class — same required safe-miss, now
#       documented as the overlap family and pinned in both spellings.
# (a) the four panel repro shapes + the minimal variant
refuse_case "cross-axis-full-key" '/home/u/.claude/projects/-a-b' /a/b \
  "refusing cross-axis overlap"
refuse_case "cross-axis-minimal" '/xclaude/projects/-a-b' /a/b \
  "refusing cross-axis overlap"
refuse_case "cross-axis-key-prefix" '/var/claude/projects/-n' '/n (2)' \
  "refusing cross-axis overlap"
refuse_case "cross-axis-colon-key" '/srv/claude/projects/-p' '/p:v2' \
  "refusing cross-axis overlap"
# ...and the refused input's tree survives --apply byte-identical
T32="$(mktemp -d)"
printf 'MEMDIR=/home/u/.claude/projects/-home-u--claude-projects--a-b/memory\n' > "$T32/f"
bash "$TOOL" --old /home/u/.claude/projects/-a-b --new /a/b --root "$T32" --apply >/dev/null 2>&1; brc=$?
[[ $brc -eq 1 && "$(cat "$T32/f")" == 'MEMDIR=/home/u/.claude/projects/-home-u--claude-projects--a-b/memory' ]] && rc=0 || rc=1
check "panel10-cross-axis-apply-leaves-tree-untouched" "$rc"
rm -rf "$T32"
# non-hazard neighbours stay accepted: CTX without its trailing slash at OLD's
# end (re-match ends before the span, no overlap), and a mid-OLD tail that
# diverges from new_key
accept_case "ctx-no-trailing-slash" /data/claude/projects /n
accept_case "ctx-tail-diverges" '/q/claude/projects/-zz' /a/b
# 11th panel MINOR: the cross-axis arm is gated on old_key != new_key — the
# hazard's first move is the key splice WRITING new_key, and identical keys
# never write. Identity (incl. trailing-slash and boundary-char spellings) and
# enc()-collision renames of context-bearing paths must all be accepted.
accept_case "cross-axis-identity" '/:/claude/projects/-' '/:/claude/projects/-'
accept_case "cross-axis-identity-trailing-slash" '/:/claude/projects/-/' '/:/claude/projects/-'
accept_case "cross-axis-identity-spaced" '/data (old)/claude/projects/-data' '/data (old)/claude/projects/-data'
accept_case "cross-axis-enc-collision" '/x/claude/projects/-a_b' '/x/claude/projects/-a-b'
# (b) ctx-overlap family: suffix-overlap spelling (NEW under ~/.claude) —
# honest key-0, path still sweeps, key bytes never corrupted
T33="$(mktemp -d)"
printf 'MEM=/home/u/.claude/projects/-old-harness/memory\np /old/harness/f\n' > "$T33/f.md"
REP="$(bash "$TOOL" --old /old/harness --new /home/u/.claude --root "$T33" 2>&1)"
printf '%s' "$REP" | grep -q 'native-memory-key=0' && rc=0 || rc=$?; check "panel10-ctx-suffix-overlap-key-honest-zero" "$rc"
printf '%s' "$REP" | grep -q 'anchor=1' && rc=0 || rc=$?; check "panel10-ctx-suffix-overlap-path-still-swept" "$rc"
bash "$TOOL" --old /old/harness --new /home/u/.claude --root "$T33" --apply >/dev/null 2>&1
grep -qF 'projects/-old-harness/memory' "$T33/f.md"
check "panel10-ctx-suffix-overlap-key-never-corrupted" $?
grep -qF '/home/u/.claude/f' "$T33/f.md"
check "panel10-ctx-suffix-overlap-path-rewrote" $?
rm -rf "$T33"

echo
echo "=== (24) 12th adversarial panel: the key span's left anchor is destroyable ==="
# One root cause behind 4 CRITICALs + 1 MAJOR from five independent lenses. The
# 9th round kept _KEY_L on new_key_span_pat, arguing a written key span "always
# sits immediately after claude/projects/". That is true where the splice FIRES
# and false where the span SITS ON THE NEXT PASS: splice() rewrites both axes in
# one pass, so when OLD's text covers the literal context (OLD ending in
# '…/claude' or '…/claude/projects'), the PATH splice overwrites the anchor
# bytes — which live OUTSIDE the protected span, so nothing preserves them.
# Pass 2 then finds no key span, the `<= e` abut rule stops firing, and --apply
# eats its own output one component per pass. The span pattern is now
# right-anchored only, matching the path axis.
idem_case "key-anchor-destroyed-migrated-key" '/h/u/.claude' '/mnt/c (2)' \
  '/h/u/.claude/projects/-h-u--claude/h/u/.claude/f\n'
idem_case "key-anchor-destroyed-minimal" /c/claude/projects '/n)' \
  '/c/claude/projects/-c-claude-projects/c/claude/projects\n'
idem_case "key-anchor-destroyed-ctx-tail" /z/claude '/w:' \
  '/z/claude/projects/-w:/z/claude/x\n'
# first applies must still do the real work (a fix that suppressed everything
# would satisfy every idempotency row above)
T34="$(mktemp -d)"
printf '/h/u/.claude/projects/-h-u--claude/h/u/.claude/f\n' > "$T34/f.txt"
REP="$(bash "$TOOL" --old '/h/u/.claude' --new '/mnt/c (2)' --root "$T34" 2>&1)"
printf '%s' "$REP" | grep -q 'anchor=1' && rc=0 || rc=$?; check "panel12-first-pass-path-counted" "$rc"
printf '%s' "$REP" | grep -q 'native-memory-key=1' && rc=0 || rc=$?; check "panel12-first-pass-key-counted" "$rc"
bash "$TOOL" --old '/h/u/.claude' --new '/mnt/c (2)' --root "$T34" --apply >/dev/null 2>&1
[[ "$(cat "$T34/f.txt")" == '/mnt/c (2)/projects/-mnt-c (2)/h/u/.claude/f' ]] && rc=0 || rc=1
check "panel12-first-pass-rewrote-both-axes" "$rc"
rm -rf "$T34"
# the surviving ref is a PERMANENT safe miss (visible to a post-apply grep),
# not a self-healing unreviewed change on the next run — that distinction is
# the whole point of the MAJOR in this family.
T35="$(mktemp -d)"
printf '/z/claude/projects/-w:/z/claude/x\n' > "$T35/f.txt"
bash "$TOOL" --old /z/claude --new '/w:' --root "$T35" --apply >/dev/null 2>&1
grep -qF '/z/claude/x' "$T35/f.txt" && rc=0 || rc=$?; check "panel12-safe-miss-survives-apply" "$rc"
bash "$TOOL" --old /z/claude --new '/w:' --root "$T35" 2>&1 | grep -q 'summary: 0 reference'
check "panel12-safe-miss-stays-missed-not-rewritten" $?
rm -rf "$T35"

echo
echo "=== (25) 13th+14th panels: the suppression-stability invariant, OBSERVED ==="
# The span guards answer "is this already-migrated residue?" from literal-NEW /
# new_key spans in the CURRENT text. That answer is sound only if the span's
# bytes still say the same thing after the pass — and a splice can overwrite
# them, on EITHER axis. When that happens the next --apply re-scans, finds no
# span, and rewrites what this pass skipped: idempotency breaks and, worse, the
# dry-run undercounts what repeated runs perform, so the review gate approves
# less than what happens.
#
# The predicate is the property itself (unstable_suppression): splice the line, re-scan
# the result with the same matcher, and refuse the line when that finds a live match —
# i.e. when a second --apply would change it. The refusal names file:line, the count and
# the surviving references. Enumerating hazards from (old, new) alone, and a positional
# proxy over spans, were both refuted; this is computed, not approximated, so the cases
# below are content-level: the same --old/--new is refused on a tree that carries the
# shape and sweeps normally on one that does not. Both halves are asserted.
unstable_case() {  # unstable_case <label> <old> <new> <content>
  local label="$1" o="$2" n="$3" content="$4"
  local D err rc; D="$(mktemp -d)"
  printf '%b' "$content" > "$D/f.txt"
  local before; before="$(cat "$D/f.txt")"
  err="$(bash "$TOOL" --old "$o" --new "$n" --root "$D" --apply 2>&1 >/dev/null)"; rc=$?
  [[ $rc -eq 1 ]] && rc=0 || rc=1; check "panel14-refused[$label]" "$rc"
  printf '%s' "$err" | grep -q 'refusing this sweep'
  check "panel14-names-stability-hazard[$label]" $?
  [[ "$before" == "$(cat "$D/f.txt")" ]] && rc=0 || rc=1; check "panel14-tree-untouched[$label]" "$rc"
  rm -rf "$D"
}
# path splice destroys the span (13th panel: _in_residue abut, and _ctx_manufactured)
unstable_case "path-splice-destroys-span" '/q-z' '/z:' '/q-z:/q-z:/q-z: x\n'
unstable_case "path-splice-ctx-manufacture" '/p-u' '/u:claude' '/p-u:claude/projects/-p-u/f\n'
unstable_case "path-splice-junction" '/,-.-' '/,' '/,-.-,/,-.-\n'
# KEY splice destroys the span (14th panel MAJOR — the direction the 13th
# round's path-axis-only widening could never have caught)
unstable_case "key-splice-destroys-span" '/x.a' '/a:' 'claude/projects/-x-a:/x.a\n'
# shellcheck disable=SC2088  # literal tilde is fixture text
unstable_case "key-splice-realistic" '/mnt/srv.app' '/srv/app (old)' \
  '~/.claude/projects/-mnt-srv-app (old)/mnt/srv.app/notes.md\n'
# ...and the SAME inputs sweep normally when the tree does not carry the shape:
# no victim, no refusal. This is the over-refusal the 14th panel found in the
# 13th round's input-level widening.
stable_case() {  # stable_case <label> <old> <new> <content> <expect-substring>
  local label="$1" o="$2" n="$3" content="$4" want="$5"
  local D rc; D="$(mktemp -d)"
  printf '%b' "$content" > "$D/f.txt"
  bash "$TOOL" --old "$o" --new "$n" --root "$D" --apply >/dev/null 2>&1; rc=$?
  [[ $rc -eq 0 ]] && rc=0 || rc=1; check "panel14-accepted[$label]" "$rc"
  grep -qF "$want" "$D/f.txt" && rc=0 || rc=$?; check "panel14-actually-rewrote[$label]" "$rc"
  bash "$TOOL" --old "$o" --new "$n" --root "$D" 2>&1 | grep -q 'summary: 0 reference'
  check "panel14-idempotent[$label]" $?
  rm -rf "$D"
}
stable_case "same-input-benign-tree" '/q-z' '/z:' 'ref /q-z/f\n' '/z:/f'
stable_case "key-input-benign-tree" '/x.a' '/a:' 'ref /x.a/f\n' '/a:/f'
# the 14th panel's MINOR: OLD merely CONTAINING the dash-encoding of NEW is not
# a hazard — there is no victim, so it must sweep, not refuse.
stable_case "old-contains-new-key-no-victim" '/srv/-old-x/data' '/old/x' \
  'see /srv/-old-x/data/notes\n' '/old/x/notes'
# 15th panel: the 14th round's POSITIONAL proxy ("does a rewrite overlap a
# suppressing span?") is not the question — the splice writes NEW, and with
# both span patterns right-anchor-only the written literal is itself a span on
# the next pass, often at exactly the position that keeps the same reference
# suppressed. 12 of 17 firings were false positives, each aborting the whole
# tree and hiding an honest report. The predicate is now the property itself:
# splice the line, re-run the matcher, require a fixed point. These three
# reproduce the proxy's false positives and must sweep.
stable_case "proxy-fp-span-still-suppresses" '/-a:' '/a:' '/-a:/-a:\n' '/a:/-a:'
stable_case "proxy-fp-written-literal-re-spans" '/srv-a:' '/a:' '/srv-a:/srv-a:/f\n' '/a:/srv-a:/f'
stable_case "proxy-fp-abut-preserved" '/srv/-app:' '/app:' 'PATH=/srv/-app:/srv/-app:\n' 'PATH=/app:/srv/-app:'
# controls: ordinary moves, and the shapes whose NEW ends in a boundary char
accept_case "ordinary-move-unaffected" /old/prefix /new/loc
accept_case "boundary-tail-new-still-ok" /old '/backup (2026)'
accept_case "colon-bearing-old-still-ok" '/srv:cache' /srv2
accept_case "self-similar-new-still-ok" /o '/b (x)/b (x)'
accept_case "key-collision-still-ok" /x/a_b /a/b

# ---- review round 1 (codex lane): root-in-.git, ASCII binary formats, stale buffer
echo
echo "--- review round 1"
# 1. --root pointing at/inside a .git dir (trailing slash made basename '' and
# bypassed the .git pruning) must be refused with no writes.
TG="$(mktemp -d)"
mkdir -p "$TG/repo/.git/worktrees/wt" "$TG/repo/.git/sub"
printf '/old/prefix/wt\n' > "$TG/repo/.git/worktrees/wt/gitdir"
printf 'ref /old/prefix/x\n' > "$TG/repo/.git/config"
for r in "$TG/repo/.git/" "$TG/repo/.git" "$TG/repo/.git//" "$TG/repo/.git/worktrees"; do
  bash "$TOOL" --old "$OLD" --new "$NEW" --root "$r" --apply >/dev/null 2>&1 && rc=0 || rc=$?
  [[ "$rc" -ne 0 && "$(cat "$TG/repo/.git/config")" == 'ref /old/prefix/x' \
     && "$(cat "$TG/repo/.git/worktrees/wt/gitdir")" == '/old/prefix/wt' ]] && rc=0 || rc=1
  check "root-in-git-refused-untouched[${r#"$TG"/}]" "$rc"
done
rm -rf "$TG"

# 2. ASCII-only binary formats must be skipped (length change breaks xref etc.)
TB="$(mktemp -d)"
printf '%%PDF-1.4\n(ref /old/prefix/file)\n%%%%EOF\n' > "$TB/doc.pdf"
printf '%%PDF-1.4\n(ref /old/prefix/file)\n' > "$TB/noext"
printf 'plain ascii /old/prefix/file\n' > "$TB/data.sqlite"
printf 'PK\003\004 /old/prefix/file\n' > "$TB/arc.dat"
printf 'see /old/prefix/file\n' > "$TB/ok.md"
OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TB" --apply 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(cat "$TB/doc.pdf")" == *'/old/prefix/file'* \
   && "$(cat "$TB/noext")" == *'/old/prefix/file'* \
   && "$(cat "$TB/data.sqlite")" == *'/old/prefix/file'* \
   && "$(cat "$TB/arc.dat")" == *'/old/prefix/file'* ]] && rc=0 || rc=1
check "ascii-binary-formats-untouched" "$rc"
[[ "$(cat "$TB/ok.md")" == 'see /new/loc/file' ]] && rc=0 || rc=1
check "ascii-binary-text-neighbour-still-rewritten" "$rc"
[[ "$OUT" == *'binary=4'* ]] && rc=0 || rc=1
check "ascii-binary-skips-counted-in-summary" "$rc"
rm -rf "$TB"

# 3. stale buffer: a file changed between scan and write must not be overwritten.
# No seam in the tool: a watcher waits for the first in-flight temp sibling (the write
# phase has begun), then edits every file. The sweep races the watcher, so retry; any
# file reported "changed since scan" must still hold the concurrent edit.
STALE_OK=1
for _try in 1 2 3; do
  TS="$(mktemp -d)"
  for n in $(seq 1 6000); do printf 'see /old/prefix/%s\n' "$n" > "$TS/f$n.md"; done
  bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TS" --apply >"$TS.out" 2>"$TS.err" &
  SPID=$!
  until compgen -G "$TS/.reorg-sync-*.tmp" >/dev/null || ! kill -0 "$SPID" 2>/dev/null; do :; done
  for n in $(seq 1 6000); do printf 'edited concurrently\n' > "$TS/f$n.md" 2>/dev/null; done
  wait "$SPID" && SRC=0 || SRC=$?
  if grep -q 'changed since scan' "$TS.err"; then
    BAD=0
    while IFS= read -r line; do
      f="${line%%:*}"; f="${f#apply-FAILED }"
      [[ "$(cat "$TS/$f")" == 'edited concurrently' ]] || BAD=1
    done < <(grep 'changed since scan' "$TS.err")
    compgen -G "$TS/.reorg-sync-*" >/dev/null && BAD=1
    [[ "$SRC" -eq 1 && "$BAD" -eq 0 ]] && STALE_OK=0
    rm -rf "$TS" "$TS.out" "$TS.err"
    break
  fi
  rm -rf "$TS" "$TS.out" "$TS.err"
done
check "stale-buffer-not-overwritten-exit-1-reported-no-temp-left" "$STALE_OK"

# 3b. the former env shell seam is gone: nothing in the environment may run code
TP="$(mktemp -d)"; printf 'see /old/prefix/a\n' > "$TP/a.md"
REORG_SYNC_TEST_PRE_REPLACE="touch $TP.pwned" \
  bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TP" --apply >/dev/null 2>&1
[[ ! -e "$TP.pwned" ]] && rc=0 || rc=1
check "no-env-shell-seam-in-apply-path" "$rc"
rm -rf "$TP" "$TP.pwned"

# ---- review round 2: silent skips are counted, bare repos pruned, big/non-UTF-8 files
echo
echo "--- review round 2"
TU="$(mktemp -d)"
printf 'caf\351 /old/prefix/x\n' > "$TU/latin.txt"
printf 'see /old/prefix/ok\n' > "$TU/ok.md"
OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TU" --apply 2>"$TU.err")" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$OUT" == *'non-utf8=1'* && "$(cat "$TU/ok.md")" == 'see /new/loc/ok' ]] && rc=0 || rc=1
check "non-utf8-file-counted-not-silent" "$rc"
grep -q 'partial scan' "$TU.err" && rc=0 || rc=1
check "non-utf8-warns-on-stderr" "$rc"
[[ "$(printf 'caf\351 /old/prefix/x\n' | cmp - "$TU/latin.txt" && echo same)" == same ]] && rc=0 || rc=1
check "non-utf8-file-untouched" "$rc"
rm -rf "$TU" "$TU.err"

if [[ "$EUID" -eq 0 ]]; then
  echo "  skip [unreadable-*: chmod-based cases do not bind root]"
else
  TR="$(mktemp -d)"
  mkdir -p "$TR/locked"
  printf 'see /old/prefix/a\n' > "$TR/locked/a.md"
  printf 'see /old/prefix/b\n' > "$TR/secret.md"
  printf 'see /old/prefix/c\n' > "$TR/ok.md"
  chmod 000 "$TR/locked" "$TR/secret.md"
  OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TR" 2>"$TR.err")" && rc=0 || rc=$?
  chmod 755 "$TR/locked"; chmod 644 "$TR/secret.md"
  [[ "$rc" -eq 0 && "$OUT" == *'unreadable=1'* && "$OUT" == *'unlistable-dir=1'* ]] && rc=0 || rc=1
  check "unreadable-and-unlistable-counted" "$rc"
  grep -q 'partial scan' "$TR.err" && rc=0 || rc=1
  check "unreadable-warns-on-stderr" "$rc"
  rm -rf "$TR" "$TR.err"
fi

TL="$(mktemp -d)"
{ printf '/old/prefix/x\n'; head -c 17000000 /dev/zero | tr '\0' 'a'; printf '\n'; } > "$TL/huge.txt"
printf 'see /old/prefix/ok\n' > "$TL/ok.md"
OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TL" --apply 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$OUT" == *'too-large=1'* && "$(head -c 14 "$TL/huge.txt")" == '/old/prefix/x'* \
   && "$(cat "$TL/ok.md")" == 'see /new/loc/ok' ]] && rc=0 || rc=1
check "oversize-file-skipped-and-counted" "$rc"
rm -rf "$TL"

TBR="$(mktemp -d)"
mkdir -p "$TBR/proj.git/objects" "$TBR/proj.git/worktrees/w" "$TBR/notrepo.git"
printf 'ref: refs/heads/main\n' > "$TBR/proj.git/HEAD"
printf 'url /old/prefix/x\n' > "$TBR/proj.git/config"
printf '/old/prefix/w\n' > "$TBR/proj.git/worktrees/w/gitdir"
printf 'see /old/prefix/y\n' > "$TBR/notrepo.git/doc.md"
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TBR" --apply >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(cat "$TBR/proj.git/config")" == 'url /old/prefix/x' \
   && "$(cat "$TBR/proj.git/worktrees/w/gitdir")" == '/new/loc/w' \
   && "$(cat "$TBR/notrepo.git/doc.md")" == 'see /new/loc/y' ]] && rc=0 || rc=1
check "bare-repo-pruned-like-dot-git" "$rc"
rm -rf "$TBR"

TN="$(mktemp -d)"
if BAD="$(printf 'bad\377name.md')" && printf 'see /old/prefix/z\n' > "$TN/$BAD" 2>/dev/null; then
  OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TN" --apply 2>&1)" && rc=0 || rc=$?
  [[ "$rc" -eq 0 && "$OUT" == *'applied: rewrote 1 file'* ]] && rc=0 || rc=1
  check "non-utf8-filename-does-not-crash-report" "$rc"
else
  echo "  skip [non-utf8-filename: filesystem rejects the name]"
fi
rm -rf "$TN"

# ---- review round 3 (security lane)
echo
echo "--- review round 3"
# 1. a hostile tree must not shadow stdlib modules of the embedded interpreter (CWE-427)
TX="$(mktemp -d)"
printf 'open(%s,"w").close()\n' "'$TX.marker'" > "$TX/re.py"
printf 'open(%s,"w").close()\n' "'$TX.marker'" > "$TX/tempfile.py"
printf 'see /old/prefix/a\n' > "$TX/a.md"
OUT="$(cd "$TX" && bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TX" --apply 2>&1)" && rc=0 || rc=$?
[[ ! -e "$TX.marker" && "$rc" -eq 0 && "$(cat "$TX/a.md")" == 'see /new/loc/a' ]] && rc=0 || rc=1
check "cwd-module-shadowing-blocked" "$rc"
rm -rf "$TX" "$TX.marker"

# 4. report injection: control bytes in filenames/lines are escaped, rows stay honest
TI="$(mktemp -d)"
printf 'see /old/prefix/a \033[2K\342\200\256x\n' > "$TI/esc.md"
if printf 'see /old/prefix/b\n' > "$TI/$(printf 'ev\nil.md')" 2>/dev/null; then NL=1; else NL=0; fi
OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TI" 2>&1)"
[[ "$OUT" != *$'\033'* && "$OUT" != *$'\342\200\256'* ]] && rc=0 || rc=1
check "report-escapes-control-and-bidi-bytes" "$rc"
ROWS="$(printf '%s\n' "$OUT" | grep -c '^  anchor ' || true)"
[[ "$ROWS" -eq $((1 + NL)) ]] && rc=0 || rc=1
check "report-row-count-honest-with-newline-filename" "$rc"
rm -rf "$TI"

# 5. root resolution: symlink into .git refused; link/.. means the resolved parent
TR5="$(mktemp -d)"
mkdir -p "$TR5/repo/.git" "$TR5/real/sub"
printf 'ref /old/prefix/x\n' > "$TR5/repo/.git/config"
ln -s "$TR5/repo/.git" "$TR5/lnk"
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TR5/lnk" --apply >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 && "$(cat "$TR5/repo/.git/config")" == 'ref /old/prefix/x' ]] && rc=0 || rc=1
check "symlinked-root-into-git-refused" "$rc"
printf 'see /old/prefix/side\n' > "$TR5/real/side.md"
printf 'see /old/prefix/decoy\n' > "$TR5/decoy.md"
ln -s "$TR5/real/sub" "$TR5/link"
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TR5/link/.." --apply >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(cat "$TR5/real/side.md")" == 'see /new/loc/side' \
   && "$(cat "$TR5/decoy.md")" == 'see /old/prefix/decoy' ]] && rc=0 || rc=1
check "root-dotdot-through-symlink-uses-resolved-parent" "$rc"
rm -rf "$TR5"

# ---- review round 4 (security lane, final)
echo
echo "--- review round 4"
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# (a) no path-based chmod may remain: the temp file is chmod'd by fd, before close
grep -q 'os\.chmod(' "$TOOL" && rc=1 || rc=0
check "no-path-based-chmod-in-tool" "$rc"

# (b) a group/other-writable parent without the sticky bit: report, do not rewrite
TW="$(mktemp -d)"; mkdir "$TW/open"
printf 'see /old/prefix/a\n' > "$TW/open/a.md"
chmod 0777 "$TW/open"
OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TW" --apply 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$(cat "$TW/open/a.md")" == 'see /old/prefix/a' && "$OUT" == *'not rewritten'* ]] && rc=0 || rc=1
check "writable-parent-without-sticky-not-rewritten" "$rc"
chmod 0755 "$TW/open"; rm -rf "$TW"

# (c) a read-only (0444) file is reported, never replaced
if [[ "$EUID" -eq 0 ]]; then
  echo "  skip [readonly-file: root bypasses access()]"
else
  TO="$(mktemp -d)"
  printf 'see /old/prefix/a\n' > "$TO/ro.md"; chmod 0444 "$TO/ro.md"
  printf 'see /old/prefix/b\n' > "$TO/ok.md"
  OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TO" --apply 2>&1)" && rc=0 || rc=$?
  [[ "$rc" -eq 1 && "$(cat "$TO/ro.md")" == 'see /old/prefix/a' && "$(mode_of "$TO/ro.md")" == 444 \
     && "$OUT" == *'not rewritten'* && "$(cat "$TO/ok.md")" == 'see /new/loc/b' ]] && rc=0 || rc=1
  check "readonly-file-reported-not-rewritten" "$rc"
  rm -rf "$TO"
fi

# (d) setuid/setgid/sticky are dropped on the rewritten copy
TM="$(mktemp -d)"
printf 'see /old/prefix/a\n' > "$TM/s.sh"; chmod 4755 "$TM/s.sh"
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TM" --apply >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$(cat "$TM/s.sh")" == 'see /new/loc/a' && "$(mode_of "$TM/s.sh")" == 755 ]] && rc=0 || rc=1
check "setuid-bit-dropped-mode-0755" "$rc"
rm -rf "$TM"

# (e) invisible format characters (Cf) are escaped in names and matched lines
TF="$(mktemp -d)"
INV=$'\xe2\x80\x8e\xe2\x80\x8f\xd8\x9c\xef\xbb\xbf\xc2\xad\xe2\x80\x8b'
printf 'see /old/prefix/a %s\n' "$INV" > "$TF/f${INV}.md"
OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TF" 2>&1)"
printf '%s\n' "$OUT" > "$TF.out"
if LC_ALL=C grep -q -e "$(printf '\342\200\216')" -e "$(printf '\342\200\217')" -e "$(printf '\330\234')" \
     -e "$(printf '\357\273\277')" -e "$(printf '\302\255')" -e "$(printf '\342\200\213')" "$TF.out"; then
  rc=1
else
  LC_ALL=C grep -qF '\u200e\u200f\u061c\ufeff\xad\u200b' "$TF.out" && rc=0 || rc=1
fi
check "format-characters-escaped-in-report" "$rc"
rm -rf "$TF" "$TF.out"

# (g) refusal messages echo --old/--new escaped
ERR="$(bash "$TOOL" --old $'/a/b\033[2Kx' --new /a --root "$TMPDIR" 2>&1 >/dev/null)" && rc=1 || rc=0
[[ "$rc" -eq 0 && "$ERR" == *'refusing'* && "$ERR" != *$'\033'* ]] && rc=0 || rc=1
check "refusal-message-escapes-old-new" "$rc"

# (f) bounded time on a pathological single line (span checks were O(matches x spans))
TT="$(mktemp -d)"
yes '/new/loc/x /old/prefix/x' | head -c 8000000 | tr '\n' ' ' > "$TT/big.txt"
printf '\n' >> "$TT/big.txt"
T0=$SECONDS
bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TT" >"$TT.out" 2>&1 &
set -m; BPID=$!; set +m
for _ in $(seq 1 120); do kill -0 "$BPID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$BPID" 2>/dev/null; then kill "$BPID" 2>/dev/null; rc=1; else rc=0; fi
echo "  (8 MB single-line dry-run: $((SECONDS - T0)) s)"
[[ "$((SECONDS - T0))" -lt 10 ]] || rc=1
check "pathological-single-line-bounded-time" "$rc"
rm -rf "$TT" "$TT.out"

# ---- review round 5
echo
echo "--- review round 5"
# 2. the rewritten copy keeps the original file's group
TGID="$(mktemp -d)"
DIRG="$(stat -f %g "$TGID" 2>/dev/null || stat -c %g "$TGID")"
OTHERG=""
for g in $(id -G); do [[ "$g" != "$DIRG" ]] && { OTHERG="$g"; break; }; done
if [[ -z "$OTHERG" ]]; then
  echo "  skip [group-preserved: only one group available]"
else
  printf 'see /old/prefix/a\n' > "$TGID/g.md"
  if chgrp "$OTHERG" "$TGID/g.md" 2>/dev/null; then
    bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TGID" --apply >/dev/null 2>&1 && rc=0 || rc=$?
    GAFTER="$(stat -f %g "$TGID/g.md" 2>/dev/null || stat -c %g "$TGID/g.md")"
    [[ "$rc" -eq 0 && "$GAFTER" == "$OTHERG" && "$(cat "$TGID/g.md")" == 'see /new/loc/a' ]] && rc=0 || rc=1
    check "rewrite-keeps-original-group" "$rc"
  else
    echo "  skip [group-preserved: chgrp refused]"
  fi
fi
rm -rf "$TGID"

# 3. U+2028/U+2029 in a name must not split a report row
TLS="$(mktemp -d)"
printf 'see /old/prefix/a\n' > "$TLS/$(printf 'a\342\200\250b\342\200\251c.md')"
OUT="$(bash "$TOOL" --old "$OLD" --new "$NEW" --root "$TLS" 2>&1)"
printf '%s\n' "$OUT" > "$TLS.out"
ROWS="$(python3 -c 'import sys;print(sum(1 for l in open(sys.argv[1],encoding="utf-8").read().splitlines() if l.startswith("  anchor ")))' "$TLS.out")"
[[ "$ROWS" -eq 1 ]] && ! LC_ALL=C grep -q "$(printf '\342\200\250')" "$TLS.out" && rc=0 || rc=1
check "line-separator-chars-escaped-row-count-unchanged" "$rc"
rm -rf "$TLS" "$TLS.out"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
