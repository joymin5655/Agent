#!/usr/bin/env bash
# ruff-gate.sh — AG-10: tracked Python (outside legacy/) must be ruff clean, and type-hint gaps
# (ruff ANN) may not grow.
#
#   1. `ruff check` with the repo ruff.toml (E4/E7/E9/F) over every tracked .py outside legacy/.
#   2. ANN ratchet: per-file ANN counts must not exceed core/tests/ann-baseline.json, and a file
#      absent from the baseline must have zero. A file that dropped below its baseline is reported
#      only — lowering the baseline is a reviewed edit, never automatic.
#
# ruff missing -> `SKIP ruff not installed` as the only output line, exit 2 (verify-all.sh SKIP
# contract). A ruff other than the pinned version is announced and still judged, but that result
# is not evidence and must not be used to regenerate the baseline.
#
# Usage: bash core/tests/ruff-gate.sh [--root DIR] [--baseline FILE] [--print-baseline]
#   --print-baseline  print the current per-file ANN counts as baseline JSON and exit 0.
# Exit 0 pass, 1 violation, 2 skipped.
set -euo pipefail

PINNED="0.16.5"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASELINE=""
PRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --print-baseline) PRINT=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
[[ -n "$BASELINE" ]] || BASELINE="$ROOT/core/tests/ann-baseline.json"

if ! command -v ruff >/dev/null 2>&1; then
  echo "SKIP ruff not installed"
  exit 2
fi
VER="$(ruff --version | awk '{print $2}')"
if [[ "$VER" != "$PINNED" ]]; then
  echo "NOTE ruff $VER is not the pinned $PINNED: this result is not gate evidence" >&2
fi

cd "$ROOT"
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files -- '*.py' | { grep -v '^legacy/' || true; })
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no tracked python files"
  exit 0
fi

ANN_JSON="$(mktemp)"
trap 'rm -f "$ANN_JSON"' EXIT
ruff check --select ANN --exit-zero --output-format json "${FILES[@]}" > "$ANN_JSON"

if [[ $PRINT -eq 1 ]]; then
  python3 -I - "$ANN_JSON" "$ROOT" "$VER" <<'PY'
import collections, json, os, sys
data = json.load(open(sys.argv[1]))
counts = collections.Counter(os.path.relpath(d["filename"], os.path.realpath(sys.argv[2])) for d in data)
print(json.dumps({"ruff": sys.argv[3], "counts": dict(sorted(counts.items()))}, indent=2))
PY
  exit 0
fi

RC=0
if ! ruff check "${FILES[@]}"; then
  echo "FAIL ruff check: violations above"
  RC=1
fi

python3 -I - "$ANN_JSON" "$ROOT" "$BASELINE" <<'PY' || RC=1
import collections, json, os, sys
ann, root, base_path = sys.argv[1:4]
counts = collections.Counter(os.path.relpath(d["filename"], os.path.realpath(root)) for d in json.load(open(ann)))
base = json.load(open(base_path))["counts"]
bad, lower = [], []
for f, n in sorted(counts.items()):
    allowed = base.get(f, 0)
    if n > allowed:
        bad.append(f"  {f}: {n} ANN > baseline {allowed}")
    elif n < allowed:
        lower.append(f"  {f}: {n} < baseline {allowed}")
for f in sorted(set(base) - set(counts)):
    lower.append(f"  {f}: 0 < baseline {base[f]}")
if lower:
    print("NOTE ANN dropped; lower core/tests/ann-baseline.json in a reviewed edit:")
    print("\n".join(lower))
if bad:
    print("FAIL type-hint gaps grew (ruff ANN):")
    print("\n".join(bad))
    sys.exit(1)
print(f"ok ANN no-growth: {sum(counts.values())} gaps in {len(counts)} files")
PY

if [[ $RC -eq 0 ]]; then echo "PASS ruff-gate (ruff $VER, ${#FILES[@]} files)"; fi
exit "$RC"
