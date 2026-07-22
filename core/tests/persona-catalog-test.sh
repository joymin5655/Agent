#!/usr/bin/env bash
# persona-catalog-test.sh — the /persona-review deliverable's determinism battery.
#
# Guards four contracts of the persona-review skill against silent drift:
#   1. CATALOG SCHEMA   — skills/persona-review/personas/catalog.json parses; every
#      persona carries the fields the skill/agent read (id, sex, age, province,
#      occupation, education_level, summary, age_bucket); ids are unique; no critical
#      field is empty. A malformed catalog would make the panel dispatch garbage.
#   2. ATTRIBUTION      — the CC BY 4.0 obligation is machine-checkable: _meta names
#      the source dataset + URL, the licence + licence URL, an attribution string,
#      and a modifications note. Shipping the data without these breaks the licence.
#   3. STRATIFICATION   — the sample is actually diverse, not a monoculture: many
#      provinces, both sexes, several age buckets, and a sane sample size. A build
#      that collapsed to one region/age would pass schema but be useless as a panel.
#   4. SKILL/AGENT LINT — the skill + orchestrator agent exist and are wired: the
#      SKILL description carries a NOT-negative (T-3), both reference the catalog by
#      its real path, and the agent's registry model matches its frontmatter.
#
# Portability: pure python3 stdlib via bash heredocs (no jq), macOS + ubuntu alike.
# Paths resolve from REPO_ROOT (BASH_SOURCE), so it runs from any cwd — verify-all.sh
# runs every core/tests/*.sh from a temp cwd and auto-discovers this one.
#
# Usage: bash core/tests/persona-catalog-test.sh
# Exit 0: all contracts hold. Exit 1: one or more failed (each printed).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CATALOG="$REPO_ROOT/skills/persona-review/personas/catalog.json"
SKILL="$REPO_ROOT/skills/persona-review/SKILL.md"
AGENT="$REPO_ROOT/agents/persona-review-orchestrator.md"
REGISTRY="$REPO_ROOT/agents/master-registry.json"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   — %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL — %s\n' "$1"; }

# run_py <label> <python-body> — the body has CATALOG/SKILL/AGENT/REGISTRY paths in
# os.environ and must print exactly "PASS" on success (anything else is the failure msg).
run_py() {
  local label="$1" body="$2" out
  out="$(CATALOG="$CATALOG" SKILL="$SKILL" AGENT="$AGENT" REGISTRY="$REGISTRY" \
    python3 - <<PY 2>&1
import json, os, re, sys
cat_p, skill_p = os.environ["CATALOG"], os.environ["SKILL"]
agent_p, reg_p = os.environ["AGENT"], os.environ["REGISTRY"]
$body
PY
)"
  if [[ "$out" == "PASS" ]]; then ok "$label"; else bad "$label ($out)"; fi
}

# ---------------------------------------------------------------------------
# 0. files exist
# ---------------------------------------------------------------------------
for f in "$CATALOG" "$SKILL" "$AGENT" "$REGISTRY"; do
  [[ -f "$f" ]] && ok "exists: ${f#"$REPO_ROOT"/}" || bad "missing: ${f#"$REPO_ROOT"/}"
done

# ---------------------------------------------------------------------------
# 1. catalog schema — parses, required fields present, unique ids, no empty criticals
# ---------------------------------------------------------------------------
run_py "catalog: parses as JSON object with personas[]" '
try:
    c = json.load(open(cat_p, encoding="utf-8"))
except Exception as e:
    print(f"unparseable: {e}"); sys.exit()
ps = c.get("personas")
print("PASS" if isinstance(ps, list) and ps else f"personas not a non-empty list: {type(ps)}")
'

run_py "catalog: every persona carries required fields" '
c = json.load(open(cat_p, encoding="utf-8"))
req = ["id","sex","age","province","occupation","education_level","summary","age_bucket"]
bad = []
for i, p in enumerate(c["personas"]):
    miss = [k for k in req if k not in p]
    if miss: bad.append((i, miss))
print("PASS" if not bad else f"{len(bad)} personas missing fields, first: {bad[0]}")
'

run_py "catalog: ids unique and non-empty" '
c = json.load(open(cat_p, encoding="utf-8"))
ids = [p.get("id") for p in c["personas"]]
empty = [i for i,v in enumerate(ids) if not v]
dupes = len(ids) - len(set(ids))
print("PASS" if not empty and dupes == 0 else f"empty={empty[:3]} dupes={dupes}")
'

run_py "catalog: critical fields non-empty (summary/province/occupation/sex)" '
c = json.load(open(cat_p, encoding="utf-8"))
bad = [i for i,p in enumerate(c["personas"])
       if not str(p.get("summary","")).strip() or not p.get("province")
       or not p.get("occupation") or not p.get("sex")]
print("PASS" if not bad else f"{len(bad)} personas with empty critical field, first idx {bad[0]}")
'

run_py "catalog: age is int and age_bucket consistent" '
c = json.load(open(cat_p, encoding="utf-8"))
def bucket(a):
    return "20s" if a < 30 else ("70+" if a >= 70 else f"{(a//10)*10}s")
bad = []
for i,p in enumerate(c["personas"]):
    a = p.get("age")
    if not isinstance(a, int) or a <= 0 or bucket(a) != p.get("age_bucket"):
        bad.append((i, a, p.get("age_bucket")))
print("PASS" if not bad else f"age/bucket mismatch, first: {bad[0]}")
'

# ---------------------------------------------------------------------------
# 2. attribution — CC BY 4.0 obligations are present and correct
# ---------------------------------------------------------------------------
run_py "attribution: _meta carries source, licence, attribution, modifications" '
c = json.load(open(cat_p, encoding="utf-8"))
m = c.get("_meta", {})
need = {
    "source_dataset": "nvidia/Nemotron-Personas-Korea",
    "license": "CC BY 4.0",
}
problems = []
for k,v in need.items():
    if m.get(k) != v: problems.append(f"{k}={m.get(k)!r} (want {v!r})")
for k in ("source_url","license_url","attribution","modifications"):
    if not str(m.get(k,"")).strip(): problems.append(f"{k} empty")
if "creativecommons.org/licenses/by/4.0" not in str(m.get("license_url","")):
    problems.append("license_url is not the CC BY 4.0 URL")
if "Nemotron-Personas-Korea" not in str(m.get("attribution","")):
    problems.append("attribution does not name the source dataset")
print("PASS" if not problems else "; ".join(problems))
'

# ---------------------------------------------------------------------------
# 3. stratification sanity — the sample is diverse, not a monoculture
# ---------------------------------------------------------------------------
run_py "stratification: >=10 provinces, both sexes, >=4 age buckets, size 80-200" '
c = json.load(open(cat_p, encoding="utf-8"))
ps = c["personas"]
prov = {p["province"] for p in ps}
sexes = {p["sex"] for p in ps}
buckets = {p["age_bucket"] for p in ps}
problems = []
if len(prov) < 10: problems.append(f"only {len(prov)} provinces")
if len(sexes) < 2: problems.append(f"only sexes {sexes}")
if len(buckets) < 4: problems.append(f"only {len(buckets)} age buckets")
if not (80 <= len(ps) <= 200): problems.append(f"size {len(ps)} outside 80-200")
# no single province dominates (>60% would be a collapsed stratification)
from collections import Counter
top = Counter(p["province"] for p in ps).most_common(1)[0]
if top[1] > 0.6 * len(ps): problems.append(f"province {top[0]} is {top[1]}/{len(ps)}")
print("PASS" if not problems else "; ".join(problems))
'

run_py "stratification: _meta sample_size matches actual count" '
c = json.load(open(cat_p, encoding="utf-8"))
declared = c.get("_meta", {}).get("sample_size")
actual = len(c["personas"])
print("PASS" if declared == actual else f"declared {declared} != actual {actual}")
'

# ---------------------------------------------------------------------------
# 4. skill / agent lint — wired, NOT-negative present, model parity
# ---------------------------------------------------------------------------
run_py "skill: frontmatter has name + description with a NOT-negative (T-3)" '
txt = open(skill_p, encoding="utf-8").read()
parts = txt.split("---", 2)
if len(parts) < 3: print("no frontmatter"); sys.exit()
fm = parts[1]
nm = re.search(r"(?m)^name:\s*persona-review\s*$", fm)
dm = re.search(r"(?m)^description:\s*(.+)$", fm)
problems = []
if not nm: problems.append("name != persona-review")
if not dm: problems.append("no description")
elif "NOT " not in dm.group(1): problems.append("description has no NOT-negative")
print("PASS" if not problems else "; ".join(problems))
'

run_py "skill + agent reference the catalog by its real path" '
sp = open(skill_p, encoding="utf-8").read()
ap = open(agent_p, encoding="utf-8").read()
needle = "skills/persona-review/personas/catalog.json"
missing = [n for n,t in (("SKILL.md",sp),("agent",ap)) if needle not in t]
print("PASS" if not missing else f"catalog path not referenced in: {missing}")
'

run_py "agent: registry model == frontmatter model (routing parity)" '
reg = json.load(open(reg_p, encoding="utf-8"))
entry = next((a for a in reg.get("agents", []) if a.get("id") == "persona-review-orchestrator"), None)
if not entry:
    print("persona-review-orchestrator not in master-registry.json"); sys.exit()
fm = open(agent_p, encoding="utf-8").read().split("---", 2)[1]
mm = re.search(r"(?m)^model:\s*(\S+)", fm)
mdmodel = mm.group(1) if mm else None
rmodel = entry.get("model")
print("PASS" if rmodel == mdmodel else f"registry={rmodel} md={mdmodel}")
'

run_py "agent: name is NOT reviewer/verifier-suffixed (keeps its Agent tool)" '
# registry-drift check 5 forces read-only tools on reviewer/verifier-named agents;
# the orchestrator must dispatch a panel, so its name must not trip that guard.
fm = open(agent_p, encoding="utf-8").read().split("---", 2)[1]
nm = re.search(r"(?m)^name:\s*(\S+)", fm)
name = nm.group(1) if nm else ""
print("PASS" if not re.search(r"(reviewer|verifier)", name, re.I) else f"name {name} trips read-only guard")
'

# ---------------------------------------------------------------------------
printf '\npersona-catalog: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS — persona catalog schema, attribution, stratification, and skill/agent wiring hold"
