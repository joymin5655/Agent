#!/usr/bin/env bash
# skill-ab-dataset-test.sh — validate the H-3 skill A/B dataset SEED
# (evals/datasets/skill-ab.jsonl) against its baseline (evals/baseline-skill-ab.json).
#
# H-3's A/B RUNNER (with-skill vs baseline scoring) is a later increment (B8). This
# battery pins the SEED's shape now, so the future runner can consume it and so the
# dataset can't silently rot: every line must parse, carry the fields its `kind`
# requires, name a REAL shipped skill (skills/<name>/SKILL.md must exist — the seed
# is grounded, not aspirational), and satisfy the H-3 bar the baseline encodes
# (>=3 assertions per skill, >=1 trigger-positive and >=1 trigger-negative per skill,
# fail-closed case count). The RED fixtures prove each guard can go red under mutation.
#
# Usage: bash core/tests/skill-ab-dataset-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA="$REPO_ROOT/evals/datasets/skill-ab.jsonl"
BASELINE="$REPO_ROOT/evals/baseline-skill-ab.json"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

# ── the validator: emits assertable TOKENs for a (dataset, baseline, skills-dir)
#    triple. Reused by the real files AND by malformed fixtures. Never throws. ──
validate_py() {
  # $1=dataset jsonl  $2=baseline json  $3=skills dir (for shipped-skill grounding)
  python3 - "$1" "$2" "$3" <<'PY'
import sys, json, os, collections
data_path, baseline_path, skills_dir = sys.argv[1], sys.argv[2], sys.argv[3]

# baseline first (fail-closed on unreadable/malformed)
try:
    with open(baseline_path) as fh:
        bl = json.load(fh)
    min_cases = bl["min_cases"]; min_assert = bl["min_assertions_per_skill"]
    skills = bl["skills"]
    if not (isinstance(min_cases, int) and isinstance(min_assert, int) and isinstance(skills, list) and skills):
        raise ValueError("baseline field types")
except Exception as e:
    print("BASELINE_ERROR %s" % type(e).__name__)
    sys.exit(0)
print("BASELINE_OK yes")

REQUIRED = ("slug", "skill", "kind", "rationale")
rows = []
parse_ok = True
fields_ok = True
try:
    with open(data_path) as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln:
                continue
            try:
                o = json.loads(ln)
            except Exception:
                parse_ok = False
                continue
            rows.append(o)
except Exception:
    print("DATA_UNREADABLE")
    sys.exit(0)
print("PARSE_OK %s" % ("yes" if parse_ok else "no"))
print("CASE_COUNT %d" % len(rows))

slugs = []
by_skill = collections.Counter()
assert_by_skill = collections.Counter()
trig_pos = collections.Counter()
trig_neg = collections.Counter()
unknown_skill = False
bad_expect = False
for o in rows:
    if not isinstance(o, dict):
        fields_ok = False
        continue
    for f in REQUIRED:
        v = o.get(f)
        if not (isinstance(v, str) and v.strip()):
            fields_ok = False
    slug = o.get("slug")
    if isinstance(slug, str):
        slugs.append(slug)
    skill = o.get("skill")
    kind = o.get("kind")
    if skill not in skills:
        unknown_skill = True
    else:
        by_skill[skill] += 1
    if kind == "assertion":
        if not (isinstance(o.get("assertion"), str) and o["assertion"].strip()
                and isinstance(o.get("baseline_lacks"), str) and o["baseline_lacks"].strip()):
            fields_ok = False
        elif skill in skills:
            assert_by_skill[skill] += 1
    elif kind == "trigger":
        exp = o.get("expect")
        req = o.get("request")
        if not (isinstance(req, str) and req.strip()) or exp not in ("trigger", "no-trigger"):
            fields_ok = False
            if exp not in ("trigger", "no-trigger"):
                bad_expect = True
        elif skill in skills:
            if exp == "trigger":
                trig_pos[skill] += 1
            else:
                trig_neg[skill] += 1
    else:
        fields_ok = False

print("FIELDS_OK %s" % ("yes" if fields_ok else "no"))
print("UNIQUE_SLUGS %s" % ("yes" if slugs and len(slugs) == len(set(slugs)) else "no"))
print("UNKNOWN_SKILL %s" % ("yes" if unknown_skill else "no"))
print("BAD_EXPECT %s" % ("yes" if bad_expect else "no"))
print("COUNT_MEETS_FLOOR %s" % ("yes" if len(rows) >= min_cases else "no"))

# every baseline skill covered, >=min_assert assertions, >=1 pos and >=1 neg trigger
all_covered = all(by_skill.get(s, 0) > 0 for s in skills)
assert_floor = all(assert_by_skill.get(s, 0) >= min_assert for s in skills)
pos_ok = all(trig_pos.get(s, 0) >= 1 for s in skills)
neg_ok = all(trig_neg.get(s, 0) >= 1 for s in skills)
print("ALL_SKILLS_COVERED %s" % ("yes" if all_covered else "no"))
print("ASSERT_FLOOR_MET %s" % ("yes" if assert_floor else "no"))
print("TRIGGER_POS_EACH %s" % ("yes" if pos_ok else "no"))
print("TRIGGER_NEG_EACH %s" % ("yes" if neg_ok else "no"))

# shipped-skill grounding: each baseline skill must have a real SKILL.md
shipped_ok = all(os.path.isfile(os.path.join(skills_dir, s, "SKILL.md")) for s in skills)
print("SKILLS_SHIPPED %s" % ("yes" if shipped_ok else "no"))
PY
}

echo "=== (1) the real seed: evals/datasets/skill-ab.jsonl ==="
[[ -f "$DATA" ]]; check "dataset-exists" $?
[[ -f "$BASELINE" ]]; check "baseline-exists" $?
OUT="$(validate_py "$DATA" "$BASELINE" "$REPO_ROOT/skills")"

echo "$OUT" | grep -qx 'BASELINE_OK yes'; check "baseline-parses" $?
echo "$OUT" | grep -qx 'PARSE_OK yes'; check "every-line-parses-json" $?
echo "$OUT" | grep -qx 'FIELDS_OK yes'; check "kind-required-fields-present" $?
echo "$OUT" | grep -qx 'UNIQUE_SLUGS yes'; check "slugs-unique" $?
echo "$OUT" | grep -qx 'UNKNOWN_SKILL no'; check "no-unknown-skill" $?
echo "$OUT" | grep -qx 'BAD_EXPECT no'; check "trigger-expect-values-valid" $?
echo "$OUT" | grep -qx 'COUNT_MEETS_FLOOR yes'; check "case-count-meets-baseline-floor" $?
echo "$OUT" | grep -qx 'ALL_SKILLS_COVERED yes'; check "all-baseline-skills-covered" $?
echo "$OUT" | grep -qx 'ASSERT_FLOOR_MET yes'; check "assertions-per-skill-floor (>=3)" $?
echo "$OUT" | grep -qx 'TRIGGER_POS_EACH yes'; check "each-skill-has-trigger-positive" $?
echo "$OUT" | grep -qx 'TRIGGER_NEG_EACH yes'; check "each-skill-has-trigger-negative" $?
echo "$OUT" | grep -qx 'SKILLS_SHIPPED yes'; check "skills-grounded-in-real-SKILL.md" $?

# ── (2) RED fixtures: the guards must reject a malformed seed (mutation-proof) ──
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/skills/only-skill"
: > "$TMP/skills/only-skill/SKILL.md"
BL="$TMP/baseline.json"
cat > "$BL" <<'EOF'
{"min_cases": 2, "min_assertions_per_skill": 1, "skills": ["only-skill"]}
EOF

echo
echo "=== (2) malformed seeds must be REJECTED (the guards can go red) ==="

# 2a: a non-JSON line -> PARSE_OK no
printf '%s\n' '{"slug":"a","skill":"only-skill","kind":"assertion","assertion":"x","baseline_lacks":"y","rationale":"r"}' 'this is not json' > "$TMP/badjson.jsonl"
echo "$(validate_py "$TMP/badjson.jsonl" "$BL" "$TMP/skills")" | grep -qx 'PARSE_OK no'; check "red-nonjson-line-detected" $?

# 2b: an assertion missing baseline_lacks -> FIELDS_OK no
printf '%s\n' '{"slug":"a","skill":"only-skill","kind":"assertion","assertion":"x","rationale":"r"}' > "$TMP/missing.jsonl"
echo "$(validate_py "$TMP/missing.jsonl" "$BL" "$TMP/skills")" | grep -qx 'FIELDS_OK no'; check "red-assertion-missing-field-detected" $?

# 2c: a trigger with an invalid expect value -> BAD_EXPECT yes
printf '%s\n' '{"slug":"a","skill":"only-skill","kind":"trigger","request":"r","expect":"maybe","rationale":"r"}' > "$TMP/badexpect.jsonl"
echo "$(validate_py "$TMP/badexpect.jsonl" "$BL" "$TMP/skills")" | grep -qx 'BAD_EXPECT yes'; check "red-invalid-expect-detected" $?

# 2d: a skill not in the baseline -> UNKNOWN_SKILL yes
printf '%s\n' '{"slug":"a","skill":"ghost-skill","kind":"assertion","assertion":"x","baseline_lacks":"y","rationale":"r"}' > "$TMP/ghost.jsonl"
echo "$(validate_py "$TMP/ghost.jsonl" "$BL" "$TMP/skills")" | grep -qx 'UNKNOWN_SKILL yes'; check "red-unknown-skill-detected" $?

# 2e: fewer assertions than the floor -> ASSERT_FLOOR_MET no
printf '%s\n' '{"slug":"a","skill":"only-skill","kind":"trigger","request":"r","expect":"trigger","rationale":"r"}' '{"slug":"b","skill":"only-skill","kind":"trigger","request":"r","expect":"no-trigger","rationale":"r"}' > "$TMP/noassert.jsonl"
echo "$(validate_py "$TMP/noassert.jsonl" "$BL" "$TMP/skills")" | grep -qx 'ASSERT_FLOOR_MET no'; check "red-below-assertion-floor-detected" $?

# 2f: a baseline naming a skill with no SKILL.md -> SKILLS_SHIPPED no
cat > "$TMP/baseline-phantom.json" <<'EOF'
{"min_cases": 1, "min_assertions_per_skill": 1, "skills": ["only-skill", "not-shipped"]}
EOF
printf '%s\n' '{"slug":"a","skill":"only-skill","kind":"assertion","assertion":"x","baseline_lacks":"y","rationale":"r"}' > "$TMP/one.jsonl"
echo "$(validate_py "$TMP/one.jsonl" "$TMP/baseline-phantom.json" "$TMP/skills")" | grep -qx 'SKILLS_SHIPPED no'; check "red-unshipped-skill-detected" $?

# 2g: an unreadable baseline -> BASELINE_ERROR (fail-closed, no false BASELINE_OK)
printf '%s' '{ not json' > "$TMP/broken-baseline.json"
echo "$(validate_py "$TMP/one.jsonl" "$TMP/broken-baseline.json" "$TMP/skills")" | grep -q '^BASELINE_ERROR'; check "red-broken-baseline-detected" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
