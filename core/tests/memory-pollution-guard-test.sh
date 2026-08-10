#!/usr/bin/env bash
# memory-pollution-guard-test.sh — battery for memory-pollution-guard.sh
#
# Covers: a clean repo passes; a memory-dump marker in a tracked file fails and
# names the file; a marker in an untracked-unignored file fails (it could reach
# a commit); a marker inside a gitignored file passes (runtime state never
# ships). All fixtures are `mktemp -d` synthetic git repos — never this repo.
#
# The marker literal is assembled by concatenation, same split-string idiom as
# the guard itself, so this battery never triggers the guard when committed.
#
# Usage: bash core/tests/memory-pollution-guard-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/memory-pollution-guard.sh"

PASS=0; FAIL=0
ok() { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
no() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

MARKER='<claude-mem'"-context>"

# fresh_repo <dir> — init a minimal git repo with one clean tracked file
fresh_repo() {
  git -C "$1" init -q
  git -C "$1" config user.email "test@example.invalid"
  git -C "$1" config user.name "guard-test"
  echo "# clean project" > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -qm "init"
}

# --- (a) clean repo -> PASS ---
A="$(mktemp -d)"
fresh_repo "$A"
if OUT="$(bash "$GUARD" "$A")"; then
  ok "a: clean repo passes"
else
  no "a: clean repo passes" "expected exit 0, got: $OUT"
fi
rm -rf "$A"

# --- (b) marker in a tracked file -> FAIL naming the file ---
B="$(mktemp -d)"
fresh_repo "$B"
printf '%s\ninjected session log\n' "$MARKER" >> "$B/AGENTS.md"
git -C "$B" add AGENTS.md
git -C "$B" commit -qm "polluted"
if OUT="$(bash "$GUARD" "$B")"; then
  no "b: tracked pollution fails" "expected exit 1, got pass"
else
  if grep -q "AGENTS.md" <<<"$OUT"; then
    ok "b: tracked pollution fails naming the file"
  else
    no "b: tracked pollution fails naming the file" "file not named in: $OUT"
  fi
fi
rm -rf "$B"

# --- (c) marker in an untracked-unignored file -> FAIL ---
C="$(mktemp -d)"
fresh_repo "$C"
printf '%s\n' "$MARKER" > "$C/notes.md"
if bash "$GUARD" "$C" >/dev/null; then
  no "c: untracked pollution fails" "expected exit 1, got pass"
else
  ok "c: untracked pollution fails"
fi
rm -rf "$C"

# --- (d) marker inside a gitignored file -> PASS (runtime state never ships) ---
D="$(mktemp -d)"
fresh_repo "$D"
echo "runtime.log" > "$D/.gitignore"
git -C "$D" add .gitignore
git -C "$D" commit -qm "ignore runtime"
printf '%s\n' "$MARKER" > "$D/runtime.log"
if bash "$GUARD" "$D" >/dev/null; then
  ok "d: gitignored pollution ignored"
else
  no "d: gitignored pollution ignored" "expected exit 0, got fail"
fi
rm -rf "$D"

# --- (e) heading-style marker ('# Memory'' Context' line) in tracked file -> FAIL ---
E="$(mktemp -d)"
fresh_repo "$E"
printf '%s\n' '# Memory'" Context" >> "$E/README.md"
git -C "$E" add README.md
git -C "$E" commit -qm "heading pollution"
if bash "$GUARD" "$E" >/dev/null; then
  no "e: heading marker fails" "expected exit 1, got pass"
else
  ok "e: heading marker fails"
fi
rm -rf "$E"

echo ""
echo "=== memory-pollution-guard-test: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
