#!/usr/bin/env bash
# ruff-gate-test.sh — prove core/tests/ruff-gate.sh is NON-VACUOUS: a clean tree passes, and each
# injected defect is caught (unused import, ANN growth in a baselined file, ANN in a new file),
# while an ANN drop only warns.
#
# Each case builds a FRESH tiny git repo under mktemp so a mutation never leaks.
#
# Usage: bash core/tests/ruff-gate-test.sh
# Exit 0 pass, 1 failure, 2 skipped (ruff absent).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/core/tests/ruff-gate.sh"

if ! command -v ruff >/dev/null 2>&1; then
  echo "SKIP ruff not installed"
  exit 2
fi

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# new_fixture — a git repo with the real ruff.toml, one python file with exactly 1 ANN gap
# (a def without annotations is several gaps; `def f(x: int): ...` is one: missing return), and a
# baseline that allows exactly that. Echoes the repo path.
new_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  cp "$REPO_ROOT/ruff.toml" "$fx/ruff.toml"
  mkdir -p "$fx/core/tests" "$fx/legacy"
  printf 'def f(x: int):\n    return x\n' > "$fx/mod.py"
  printf 'def g(x):\n    return x\n' > "$fx/legacy/old.py"   # excluded: legacy/ is never checked
  git -C "$fx" init -q
  git -C "$fx" add -A
  printf '{"ruff":"x","counts":{"mod.py":1}}\n' > "$fx/core/tests/ann-baseline.json"
  printf '%s' "$fx"
}

OUT=""; RC=0
run() { OUT="$(bash "$GATE" --root "$1" 2>&1)"; RC=$?; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
rc_is() { if [[ $RC -eq $1 ]]; then echo 0; else echo 1; fi; }

echo "=== (0) clean fixture passes (legacy/ ignored) ==="
FX="$(new_fixture)"
run "$FX"
check "clean-fixture-exit-0" "$(rc_is 0)"
has "PASS ruff-gate"; check "clean-fixture-says-pass" $?

echo
echo "=== (1) DEFECT 1: an unused import fails ruff check ==="
FX="$(new_fixture)"
printf 'import os\n' >> "$FX/mod.py"
git -C "$FX" add -A
run "$FX"
check "unused-import-exit-1" "$(rc_is 1)"
has "F401"; check "unused-import-names-F401" $?

echo
echo "=== (2) DEFECT 2: one more ANN gap in a baselined file fails ==="
FX="$(new_fixture)"
printf 'def h(y: int):\n    return y\n' >> "$FX/mod.py"
git -C "$FX" add -A
run "$FX"
check "ann-growth-exit-1" "$(rc_is 1)"
has "mod.py: 2 ANN > baseline 1"; check "ann-growth-names-file" $?

echo
echo "=== (3) DEFECT 3: ANN in a file absent from the baseline fails ==="
FX="$(new_fixture)"
printf 'def n(z: int):\n    return z\n' > "$FX/new_mod.py"
git -C "$FX" add -A
run "$FX"
check "new-file-ann-exit-1" "$(rc_is 1)"
has "new_mod.py: 1 ANN > baseline 0"; check "new-file-ann-names-file" $?

echo
echo "=== (4) an ANN drop only warns (baseline is lowered in a reviewed edit) ==="
FX="$(new_fixture)"
printf 'def f(x: int) -> int:\n    return x\n' > "$FX/mod.py"
git -C "$FX" add -A
run "$FX"
check "ann-drop-still-exit-0" "$(rc_is 0)"
has "mod.py: 0 < baseline 1"; check "ann-drop-reports-lower-baseline" $?

echo
echo "=== (4b) a noqa comment cannot hide a new ANN gap ==="
FX="$(new_fixture)"
printf 'def h(y: int):  # noqa: ANN201\n    return y\n' >> "$FX/mod.py"
git -C "$FX" add -A
run "$FX"
check "noqa-ann-growth-exit-1" "$(rc_is 1)"
has "mod.py: 2 ANN > baseline 1"; check "noqa-ann-growth-counted" $?

echo
echo "=== (4c) outside a git work tree fails instead of passing on 0 files ==="
NOGIT="$(mktemp -d "$TMP_ROOT/nogitXXXXXX")"
run "$NOGIT"
check "no-git-exit-1" "$(rc_is 1)"
has "FAIL ruff-gate"; check "no-git-says-fail" $?

echo
echo "=== (4d) --print-baseline refuses an unpinned ruff; a relative --baseline resolves ==="
FX="$(new_fixture)"
FAKEBIN="$(mktemp -d "$TMP_ROOT/fakeXXXXXX")"
printf '#!/bin/sh\necho "ruff 0.0.1"\n' > "$FAKEBIN/ruff"
chmod +x "$FAKEBIN/ruff"
OUT="$(PATH="$FAKEBIN:$PATH" bash "$GATE" --root "$FX" --print-baseline 2>&1)"; RC=$?
check "print-baseline-unpinned-exit-1" "$(rc_is 1)"
has "--print-baseline needs ruff"; check "print-baseline-unpinned-says-why" $?
printf '%s\n' "$OUT" | grep -q '"counts"'; [[ $? -ne 0 ]]; check "print-baseline-unpinned-prints-no-json" $?
OUT="$(cd "$FX" && bash "$GATE" --root "$FX" --baseline core/tests/ann-baseline.json 2>&1)"; RC=$?
check "relative-baseline-exit-0" "$(rc_is 0)"

echo
echo "=== (5) the shipped baseline matches the real tree ==="
run "$REPO_ROOT"
check "shipped-tree-passes" "$(rc_is 0)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
