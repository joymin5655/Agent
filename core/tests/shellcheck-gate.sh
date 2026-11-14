#!/usr/bin/env bash
# AG-9b gate — tracked shell scripts (outside legacy/) must be free of shellcheck
# warnings and errors.
#
# Scope: every tracked `*.sh` plus every tracked file whose first line is a shell shebang
# (extensionless hooks such as core/git-hooks/pre-push). legacy/ is never checked. Level is
# `-S warning`; info and style findings are not gated (docs/gate-registry.md AG-9b).
# `--norc` stops shellcheck from reading any .shellcheckrc, so a developer's personal config cannot
# change the result. Files under core/tests/ get `-e SC2319`: the batteries pass a condition result
# on purpose with `[[ ... ]]; check name 0 $?`, and SC2319 flags every such line. Nothing else is
# excluded, and SC2319 stays enforced outside core/tests/.
#
# No shellcheck binary -> `SKIP shellcheck not installed` as the only output line, exit 2
# (verify-all.sh SKIP contract). A shellcheck other than the pinned version is announced and still
# judged, but that result is not evidence.
#
# Usage: bash core/tests/shellcheck-gate.sh [--root DIR]
# Exit 0 pass, 1 findings, 2 skipped.
set -euo pipefail

PINNED="0.11.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "SKIP shellcheck not installed"
  exit 2
fi
VER="$(shellcheck --version | awk '/^version:/ {print $2}')"
if [[ "$VER" != "$PINNED" ]]; then
  echo "NOTE shellcheck $VER is not the pinned $PINNED: this result is not gate evidence" >&2
fi

cd "$ROOT"
TESTS=()
OTHERS=()
while IFS= read -r f; do
  case "$f" in
    legacy/*) continue ;;
    *.sh) ;;
    *) { [[ -f "$f" && ! -L "$f" ]] && head -n 1 "$f" 2>/dev/null | grep -qaE '^#!.*(ba|z|k|da)?sh( |$)'; } || continue ;;
  esac
  case "$f" in
    core/tests/*) TESTS+=("$f") ;;
    *) OTHERS+=("$f") ;;
  esac
done < <(git ls-files)

RC=0
if [[ ${#TESTS[@]} -gt 0 ]]; then
  shellcheck --norc -S warning -e SC2319 "${TESTS[@]}" || RC=1
fi
if [[ ${#OTHERS[@]} -gt 0 ]]; then
  shellcheck --norc -S warning "${OTHERS[@]}" || RC=1
fi

N=$(( ${#TESTS[@]} + ${#OTHERS[@]} ))
if [[ $RC -eq 0 ]]; then
  echo "PASS shellcheck-gate (shellcheck $VER, $N files)"
else
  echo "FAIL shellcheck-gate: findings above ($N files checked)"
fi
exit "$RC"
