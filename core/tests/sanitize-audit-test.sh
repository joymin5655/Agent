#!/usr/bin/env bash
# Test for core/tests/sanitize-audit.sh --range (the add-then-remove gap).
#
# Hermetic: builds a throwaway git repo in a tempdir; never touches the real
# working tree or the network. The forbidden fixture token is assembled at RUNTIME
# from parts so this committed file never contains the literal token (which would
# otherwise trip the very sanitize gate it tests when the working tree is scanned).
set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sanitize-audit.sh"
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# Runtime-assembled fixture token (a member of the script's TOKENS list) — the
# joined literal never appears in this file (assembled from the two halves below).
P1="Air"; P2="Lens"; TOK="${P1}${P2}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git -C "$TMP" init -q
echo "hello world" >"$TMP/readme.md"
git -C "$TMP" add -A && git -C "$TMP" commit -q -m "c0 clean"
C0="$(git -C "$TMP" rev-parse HEAD)"

printf 'prepared from %s/project\n' "$TOK" >"$TMP/notes.md"   # introduce taint
git -C "$TMP" add -A && git -C "$TMP" commit -q -m "c1 add token"

echo "cleaned" >"$TMP/notes.md"                                # remove it — HEAD now clean
git -C "$TMP" add -A && git -C "$TMP" commit -q -m "c2 remove token"
HEAD2="$(git -C "$TMP" rev-parse HEAD)"

# Precondition: HEAD really is clean of the token (add-then-remove).
if [ -z "$(git -C "$TMP" grep -i "$TOK" -- . 2>/dev/null || true)" ]; then
  pass "fixture: token absent from HEAD (add-then-remove)"
else
  fail "fixture: token unexpectedly present in HEAD"
fi

# 1) --range MUST catch the token added in c1 even though HEAD is clean.
out="$(cd "$TMP" && bash "$SCRIPT" --range "$C0..$HEAD2" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "$TOK"; then
  pass "--range catches add-then-remove taint (exit 1)"
else
  fail "--range did NOT catch add-then-remove (rc=$rc): $out"
fi

# 2) A clean range passes.
out="$(cd "$TMP" && bash "$SCRIPT" --range "$C0..$C0" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  pass "--range clean range passes (exit 0)"
else
  fail "--range clean range should pass (rc=$rc): $out"
fi

# 3) An unresolvable range fails LOUD (no false green).
missing=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
out="$(cd "$TMP" && bash "$SCRIPT" --range "$missing..$HEAD2" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  pass "--range with missing endpoint fails loud (exit $rc)"
else
  fail "--range with missing endpoint should fail, got exit 0: $out"
fi

# 4) Missing range argument -> usage error (exit 2).
out="$(cd "$TMP" && bash "$SCRIPT" --range 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  pass "--range without argument errors (exit 2)"
else
  fail "--range without arg should exit 2 (rc=$rc): $out"
fi

# 5) Regression: a token on an added line whose CONTENT starts with `++` must not
#    be mistaken for a `+++ ` diff file-header and dropped by the header filter.
printf '++note %s\n' "$TOK" >"$TMP/plus.md"        # diff line becomes "+++note ..."
git -C "$TMP" add -A && git -C "$TMP" commit -q -m "c3 ++-prefixed token line"
HEAD3="$(git -C "$TMP" rev-parse HEAD)"
out="$(cd "$TMP" && bash "$SCRIPT" --range "$HEAD2..$HEAD3" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "$TOK"; then
  pass "--range catches a token on a ++-prefixed added line (header-filter precision)"
else
  fail "--range missed token on a ++-prefixed line (rc=$rc): $out"
fi

if [ "$fails" -eq 0 ]; then
  echo "sanitize-audit-test: all checks passed"
  exit 0
fi
echo "sanitize-audit-test: $fails check(s) failed"
exit 1
