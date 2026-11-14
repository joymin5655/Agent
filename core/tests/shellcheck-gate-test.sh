#!/usr/bin/env bash
# Gate test for AG-9b — proves core/tests/shellcheck-gate.sh is NON-VACUOUS: a clean tree
# passes, and each injected defect is caught (unused variable; SC2319 outside core/tests/), while
# the scope rules hold (SC2319 tolerated inside core/tests/, legacy/ ignored, an extensionless
# shell file is checked).
#
# Each case builds a FRESH tiny git repo under mktemp so a mutation never leaks.
#
# Usage: bash core/tests/shellcheck-gate-test.sh
# Exit 0 pass, 1 failure, 2 skipped (shellcheck absent).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/core/tests/shellcheck-gate.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP shellcheck not installed"
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

# new_fixture — a git repo with a clean script, a legacy/ script that would fail, and a
# core/tests/ script using the tolerated `[[ ]]; check name 0 $?` idiom. Echoes the repo path.
new_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  mkdir -p "$fx/core/tests" "$fx/legacy" "$fx/bin"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho ok\n' > "$fx/run.sh"
  printf '#!/usr/bin/env bash\nunused=1\n' > "$fx/legacy/old.sh"
  printf '#!/usr/bin/env bash\ncheck() { :; }\n[[ -n "$1" ]]; check name 0 $?\n' > "$fx/core/tests/a-test.sh"
  printf '#!/usr/bin/env bash\necho hook\n' > "$fx/bin/hook"
  git -C "$fx" init -q
  git -C "$fx" add -A
  printf '%s' "$fx"
}

OUT=""; RC=0
run() { OUT="$(bash "$GATE" --root "$1" 2>&1)"; RC=$?; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
rc_is() { if [[ $RC -eq $1 ]]; then echo 0; else echo 1; fi; }

echo "=== (0) clean fixture passes (legacy/ ignored, SC2319 tolerated in core/tests/) ==="
FX="$(new_fixture)"
run "$FX"
check "clean-fixture-exit-0" "$(rc_is 0)"
has "PASS shellcheck-gate"; check "clean-fixture-says-pass" $?

echo
echo "=== (1) DEFECT 4: an unused variable fails ==="
FX="$(new_fixture)"
printf 'leftover=1\n' >> "$FX/run.sh"
git -C "$FX" add -A
run "$FX"
check "unused-variable-exit-1" "$(rc_is 1)"
has "SC2034"; check "unused-variable-names-SC2034" $?

echo
echo "=== (2) DEFECT 5: SC2319 outside core/tests/ fails ==="
FX="$(new_fixture)"
# a real battery that trips SC2319: SC2319 depends on surrounding context, so a one-line fixture
# does not reproduce it. The same file is clean inside core/tests/ (case 2b).
cp "$REPO_ROOT/core/tests/antigravity-preflight-test.sh" "$FX/moved-battery.sh"
git -C "$FX" add -A
run "$FX"
check "sc2319-outside-tests-exit-1" "$(rc_is 1)"
has "SC2319"; check "sc2319-outside-tests-names-SC2319" $?

echo
echo "=== (2b) the same battery inside core/tests/ passes ==="
FX="$(new_fixture)"
cp "$REPO_ROOT/core/tests/antigravity-preflight-test.sh" "$FX/core/tests/moved-battery-test.sh"
git -C "$FX" add -A
run "$FX"
check "sc2319-inside-tests-exit-0" "$(rc_is 0)"

echo
echo "=== (3) an extensionless shell file is checked ==="
FX="$(new_fixture)"
printf 'leftover=1\n' >> "$FX/bin/hook"
git -C "$FX" add -A
run "$FX"
check "extensionless-shell-exit-1" "$(rc_is 1)"
has "bin/hook"; check "extensionless-shell-named" $?

echo
echo "=== (4) a non-shell extensionless file is not fed to shellcheck ==="
FX="$(new_fixture)"
printf '#!/usr/bin/env python3\nunused = 1\n' > "$FX/bin/tool"
git -C "$FX" add -A
run "$FX"
check "non-shell-file-ignored-exit-0" "$(rc_is 0)"

echo
echo "=== (5) shebang edge cases: tab after the interpreter is checked; fish and zsh are not ==="
FX="$(new_fixture)"
printf '#!/bin/bash\t\nleftover=1\n' > "$FX/bin/tabbed"
git -C "$FX" add -A
run "$FX"
check "tab-after-interpreter-exit-1" "$(rc_is 1)"
has "bin/tabbed"; check "tab-after-interpreter-named" $?
FX="$(new_fixture)"
printf '#!/usr/bin/env fish\nset unused 1\n' > "$FX/bin/fishy"
printf '#!/bin/zsh\nunused=1\n' > "$FX/bin/zshy"
git -C "$FX" add -A
run "$FX"
check "fish-and-zsh-ignored-exit-0" "$(rc_is 0)"

echo
echo "=== (6) outside a git work tree fails instead of passing on 0 files ==="
NOGIT="$(mktemp -d "$TMP_ROOT/nogitXXXXXX")"
run "$NOGIT"
check "no-git-exit-1" "$(rc_is 1)"
has "FAIL shellcheck-gate"; check "no-git-says-fail" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
