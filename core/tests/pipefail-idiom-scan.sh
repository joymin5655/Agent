#!/usr/bin/env bash
# pipefail-idiom-scan.sh — W-7(2): regression gate against zero-match
# count-pipe aborts in shipped runtime scripts.
#
# Under `set -o pipefail`, a zero-match `grep pat | wc -l` exits 1 and aborts
# the enclosing `set -e` script — a real false-abort class (a counting command
# is not a failure). Under plain `set -e`, an unguarded `n=$(grep -c pat f)`
# assignment aborts the same way. The safe idioms (AGENTS.md § Style):
#   { grep -E pat file || true; } | wc -l
#   n=$(grep -c pat file || true)
#
# This gate scans shipped RUNTIME scripts (core/hooks, core/infra, setup.sh,
# adapters/**.sh, evals/**.sh) that opt into strict mode, and fails on either
# unguarded shape. core/tests/ is out of scope: batteries run `set -u` and
# quote these very shapes as fixture strings.
#
# Non-vacuous proof: before scanning the repo, the detector is pointed at two
# synthetic fixtures — one bad (must be flagged), one guarded (must pass) — so
# a regex typo cannot rot this gate into always-green.
#
# Usage: bash core/tests/pipefail-idiom-scan.sh
# Exit 0: clean. Exit 1: unguarded count pipe found (prints offenders).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# scan_file <file> — prints "file:line: text" per violation, empty when clean.
scan_file() {
  local f="$1"
  local strict=0 pf=0
  head -30 "$f" | grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e' && strict=1
  head -30 "$f" | grep -qE 'pipefail' && pf=1
  # -euo pipefail style declares both in one line; treat `set -e` without
  # pipefail as strict-only (assignment shape still aborts there).
  [[ $strict -eq 0 && $pf -eq 0 ]] && return 0
  local n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    # comments never execute
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ $pf -eq 1 ]]; then
      # grep piped into wc without a `|| true` guard before the pipe
      if printf '%s' "$line" | grep -qE 'grep[^|;]*\|[[:space:]]*wc\b' \
         && ! printf '%s' "$line" | grep -qE '\|\|[[:space:]]*true[[:space:]]*;?[[:space:]]*\}?[[:space:]]*\|[[:space:]]*wc\b'; then
        printf '%s:%d: %s\n' "$f" "$n" "$line"
        continue
      fi
    fi
    if [[ $strict -eq 1 ]]; then
      # unguarded count assignment: x=$(grep -c ...) with no || fallback
      if printf '%s' "$line" | grep -qE '=\$\([[:space:]]*grep[[:space:]][^)]*-c[^)]*\)' \
         && ! printf '%s' "$line" | grep -qE '\|\|'; then
        printf '%s:%d: %s\n' "$f" "$n" "$line"
      fi
    fi
  done < "$f"
}

# --- non-vacuous proof: the detector must flag the bad fixture and pass the
# --- guarded one. Fixture text is assembled here, never stored as repo code.
FIXDIR="$(mktemp -d)"
trap 'rm -rf "$FIXDIR"' EXIT
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'n=$(grep -E pat file | wc -l)'
  echo 'm=$(grep -c pat file)'
} > "$FIXDIR/bad.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'n=$({ grep -E pat file || true; } | wc -l)'
  echo 'm=$(grep -c pat file || true)'
  echo '# comment: grep pat | wc -l is discussed here only'
} > "$FIXDIR/good.sh"

BAD_HITS="$(scan_file "$FIXDIR/bad.sh")"
if [[ $(printf '%s\n' "$BAD_HITS" | grep -c ':' ) -ne 2 ]]; then
  echo "FAIL — detector self-check: bad fixture should yield 2 hits, got:"
  printf '%s\n' "$BAD_HITS" | sed 's/^/  /'
  exit 1
fi
GOOD_HITS="$(scan_file "$FIXDIR/good.sh")"
if [[ -n "$GOOD_HITS" ]]; then
  echo "FAIL — detector self-check: guarded fixture false-positive:"
  printf '%s\n' "$GOOD_HITS" | sed 's/^/  /'
  exit 1
fi

# --- repo scan: shipped runtime scripts under strict mode ---
VIOLATIONS=""
SCANNED=0
while IFS= read -r f; do
  SCANNED=$((SCANNED + 1))
  hits="$(scan_file "$f")"
  [[ -n "$hits" ]] && VIOLATIONS="${VIOLATIONS}${hits}"$'\n'
done < <(find "$ROOT/core/hooks" "$ROOT/core/infra" "$ROOT/adapters" "$ROOT/evals" \
              -name '*.sh' -type f 2>/dev/null; ls "$ROOT/setup.sh" 2>/dev/null)

if [[ $SCANNED -eq 0 ]]; then
  echo "FAIL — scanned zero runtime scripts (path drift?); refusing vacuous green"
  exit 1
fi

if [[ -n "${VIOLATIONS//[$'\n ']/}" ]]; then
  echo "FAIL — unguarded zero-match count pipe(s) in strict-mode scripts:"
  printf '%s' "$VIOLATIONS" | sed '/^$/d; s/^/  /'
  echo ""
  echo "Guard them: { grep ... || true; } | wc -l   or   n=\$(grep -c ... || true)"
  exit 1
fi

echo "PASS — $SCANNED runtime script(s) scanned; no unguarded count pipes (detector self-check: 2/2)"
exit 0
