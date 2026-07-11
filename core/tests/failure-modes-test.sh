#!/usr/bin/env bash
# failure-modes-test.sh — validate evals/failure-modes.yaml (L-1), the grader's
# named-failure-mode rubric that replaces the old single-scalar harness_score.
#
# This battery pins the FILE's shape so the grader (core/tests/grade.sh, B4) can
# trust it: it must parse as YAML, carry a schema_version, hold >=8 modes, and every
# mode must have a unique kebab-case id plus all six required fields, each non-empty.
# The >=8 floor and the non-empty-field checks are the anti-vacuous guards: a rubric
# with fewer modes, a duplicated id, or a blank field is a rubric that silently fails
# to grade something, so those must go RED — verified below by feeding malformed
# fixtures through the same parser and asserting they are rejected.
#
# Every check is driven through the SAME python parser the grader will use, so a
# passing check here means the grader can actually consume the file (not just that
# the bytes look right to grep).
#
# Usage: bash core/tests/failure-modes-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="$REPO_ROOT/evals/failure-modes.yaml"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

# require PyYAML (the repo already depends on it via hook_config.py / ci.yml).
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "  FAIL [pyyaml-available] — PyYAML not importable; the grader needs it too"
  echo "=== Results: 0 passed, 1 failed ==="
  exit 1
fi

# ── the validator: prints one TOKEN per line for a given yaml file. Reused by the
#    real file AND by malformed fixtures (so the RED cases exercise the same code). ──
REQUIRED_FIELDS='id name description caught_in detection_signal grader_check'
validate_py() {
  # $1 = path to a yaml file. Emits assertable tokens on stdout, never throws.
  python3 - "$1" "$REQUIRED_FIELDS" <<'PY'
import sys, re, yaml
path, required = sys.argv[1], sys.argv[2].split()
try:
    with open(path) as fh:
        doc = yaml.safe_load(fh)
except Exception as e:
    print("PARSE_ERROR %s" % type(e).__name__)
    sys.exit(0)
if not isinstance(doc, dict):
    print("NOT_A_MAPPING")
    sys.exit(0)
print("SCHEMA_VERSION %s" % ("yes" if str(doc.get("schema_version", "")).strip() else "no"))
modes = doc.get("failure_modes")
if not isinstance(modes, list):
    print("MODES_NOT_A_LIST")
    sys.exit(0)
print("MODE_COUNT %d" % len(modes))
ids = []
kebab = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
all_fields_ok = True
all_kebab_ok = True
for m in modes:
    if not isinstance(m, dict):
        all_fields_ok = False
        continue
    mid = m.get("id")
    if isinstance(mid, str):
        ids.append(mid)
        if not kebab.match(mid):
            all_kebab_ok = False
    else:
        all_kebab_ok = False
    for f in required:
        v = m.get(f)
        if not (isinstance(v, str) and v.strip()):
            all_fields_ok = False
print("UNIQUE_IDS %s" % ("yes" if len(ids) == len(set(ids)) and ids else "no"))
print("ALL_FIELDS_NONEMPTY %s" % ("yes" if all_fields_ok else "no"))
print("ALL_IDS_KEBAB %s" % ("yes" if all_kebab_ok else "no"))
print("IDS %s" % ",".join(ids))
PY
}

echo "=== (1) the real file: evals/failure-modes.yaml ==="
[[ -f "$SPEC" ]]; check "spec-file-exists" $?
OUT="$(validate_py "$SPEC")"

echo "$OUT" | grep -q '^PARSE_ERROR'; [[ $? -ne 0 ]]; check "parses-as-yaml" $?
echo "$OUT" | grep -qx 'SCHEMA_VERSION yes'; check "has-schema-version" $?
echo "$OUT" | grep -qx 'UNIQUE_IDS yes'; check "ids-are-unique" $?
echo "$OUT" | grep -qx 'ALL_FIELDS_NONEMPTY yes'; check "all-required-fields-nonempty" $?
echo "$OUT" | grep -qx 'ALL_IDS_KEBAB yes'; check "all-ids-kebab-case" $?

# >=8 modes (the anti-vacuous floor). Extract the count and compare numerically.
COUNT="$(echo "$OUT" | sed -n 's/^MODE_COUNT //p')"
[[ -n "$COUNT" && "$COUNT" =~ ^[0-9]+$ && "$COUNT" -ge 8 ]]; check "at-least-8-modes ($COUNT)" $?

# the modes we curated from real catches must all be present (guards against a
# future edit silently dropping a hard-won mode — a stale-ssot on the rubric itself).
IDS_LINE="$(echo "$OUT" | sed -n 's/^IDS //p')"
for want in silent-drop vacuous-green vacuous-parity glob-scope-miss bypass-flag \
            unanchored-skip infra-as-verdict lexical-containment injection-breakout \
            loose-coercion stale-ssot review-false-clean; do
  echo ",$IDS_LINE," | grep -qF ",$want,"; check "mode-present:$want" $?
done

# ── (2) RED fixtures: the guards must reject malformed rubrics (mutation-proof) ──
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo
echo "=== (2) malformed fixtures must be REJECTED (the guards can go red) ==="

# 2a: only 2 modes -> the >=8 floor must catch it
cat > "$TMP/few.yaml" <<'EOF'
schema_version: "1.0.0"
failure_modes:
  - id: a-mode
    name: A
    description: d
    caught_in: c
    detection_signal: s
    grader_check: g
  - id: b-mode
    name: B
    description: d
    caught_in: c
    detection_signal: s
    grader_check: g
EOF
FEW="$(validate_py "$TMP/few.yaml")"
FEWCOUNT="$(echo "$FEW" | sed -n 's/^MODE_COUNT //p')"
# guard non-empty + numeric before the arithmetic: on bash 3.2 an empty string
# coerces to 0 in `-lt`, so a bare `[[ "" -lt 8 ]]` would report 'ok' even if the
# fixture stopped emitting MODE_COUNT entirely — the very vacuous-green this file
# names. Require a real number below the floor (mirrors the line-99 real-file gate).
[[ -n "$FEWCOUNT" && "$FEWCOUNT" =~ ^[0-9]+$ && "$FEWCOUNT" -lt 8 ]]; check "red-too-few-modes-detected" $?

# 2b: a mode missing a required field (grader_check) -> ALL_FIELDS_NONEMPTY no
cat > "$TMP/missing.yaml" <<'EOF'
schema_version: "1.0.0"
failure_modes:
  - id: a-mode
    name: A
    description: d
    caught_in: c
    detection_signal: s
EOF
echo "$(validate_py "$TMP/missing.yaml")" | grep -qx 'ALL_FIELDS_NONEMPTY no'; check "red-missing-field-detected" $?

# 2c: an empty (whitespace-only) field -> ALL_FIELDS_NONEMPTY no (not just presence)
cat > "$TMP/blank.yaml" <<'EOF'
schema_version: "1.0.0"
failure_modes:
  - id: a-mode
    name: A
    description: "   "
    caught_in: c
    detection_signal: s
    grader_check: g
EOF
echo "$(validate_py "$TMP/blank.yaml")" | grep -qx 'ALL_FIELDS_NONEMPTY no'; check "red-blank-field-detected" $?

# 2d: duplicate ids -> UNIQUE_IDS no
cat > "$TMP/dup.yaml" <<'EOF'
schema_version: "1.0.0"
failure_modes:
  - id: dup-mode
    name: A
    description: d
    caught_in: c
    detection_signal: s
    grader_check: g
  - id: dup-mode
    name: B
    description: d
    caught_in: c
    detection_signal: s
    grader_check: g
EOF
echo "$(validate_py "$TMP/dup.yaml")" | grep -qx 'UNIQUE_IDS no'; check "red-duplicate-id-detected" $?

# 2e: a non-kebab id -> ALL_IDS_KEBAB no
cat > "$TMP/bad_id.yaml" <<'EOF'
schema_version: "1.0.0"
failure_modes:
  - id: Bad_ID
    name: A
    description: d
    caught_in: c
    detection_signal: s
    grader_check: g
EOF
echo "$(validate_py "$TMP/bad_id.yaml")" | grep -qx 'ALL_IDS_KEBAB no'; check "red-non-kebab-id-detected" $?

# 2f: malformed YAML -> PARSE_ERROR (the parser fails closed, no false 'valid')
printf 'schema_version: "1.0"\nfailure_modes:\n  - id: a\n   name: bad-indent\n' > "$TMP/broken.yaml"
echo "$(validate_py "$TMP/broken.yaml")" | grep -q '^PARSE_ERROR'; check "red-unparseable-yaml-detected" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
