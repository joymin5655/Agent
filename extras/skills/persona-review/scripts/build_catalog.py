#!/usr/bin/env python3
"""build_catalog.py — regenerate the stratified Korean persona catalog.

Reproducible builder for ``skills/persona-review/personas/catalog.json``: a
stratified subsample of the public ``nvidia/Nemotron-Personas-Korea`` dataset
(CC BY 4.0), used by ``/persona-review`` as a citizen/user review panel.

Why a subsample: the source is 1.0M synthetic personas (~2 GB / 9 parquet
shards). A review only ever seats a handful of panelists, so we ship a small,
demographically diverse catalog instead of the whole set. The rows are
*synthetic* personas grounded in real KOSIS/court/insurance distributions — no
real individuals — and carry no name/contact/identifier fields, so nothing
here is PII.

Stratification design (converged from two independent builders, 2026-07-22):
    - We never download the full dataset: DuckDB's ``httpfs`` reads only the
      columns/row-groups a query touches, via HTTP range requests over the
      Hub's parquet shards.
    - Primary axis is (age_group x province) — a 7x17 = up to 119-cell grid,
      hard-balanced (one persona per cell): every province gets an even,
      non-population-proportional seat, which is what a "spread panel"
      (SKILL.md step 3) actually needs. An earlier population-proportional
      builder left small provinces (e.g. 세종) with as few as 2 of 120 seats —
      good census fidelity, bad panel diversity.
    - occupation (2,000+ distinct raw values, ~37% "무직"/unemployed) is
      bucketed into 13 coarse occupation groups via keyword matching so it can
      act as a secondary, soft-balanced axis instead of flooding the sample
      with "무직".
    - A candidate pool of top-N ranked rows per (age_group, province) cell is
      pulled, then a deterministic greedy selector picks 1 per cell, preferring
      whichever candidate keeps occupation_group / education_level furthest
      under a soft per-category cap. This is NOT a full 4-way factorial cross
      (that would fragment a ~119-row sample into near-empty cells) — it's a
      2-axis hard stratification (age x province, perfectly even) plus a
      2-axis soft-balanced secondary pass (occupation_group, education_level).
    - Selection is fully deterministic given SEED: same seed + same dataset
      revision => same output (idempotent re-runs).

review_lens: each persona gets 1-2 ``review_lens`` tags — "UX" / "카피" /
"접근성" / "신뢰" / "가격민감" — a deterministic, priority-ordered function of
age + occupation_group + education (see ``tag_review_lens``) that tells
``/persona-review`` which kind of scrutiny this panelist is good for.

Usage (requires the ``duckdb`` package — not stdlib):
    uv run --with duckdb skills/persona-review/scripts/build_catalog.py
    uv run --with duckdb skills/persona-review/scripts/build_catalog.py --dry-run
    uv run --with duckdb skills/persona-review/scripts/build_catalog.py --seed my-seed-2027

If the Hub is unreachable, this exits non-zero WITHOUT touching the committed
catalog — a stale-but-real catalog is always better than a fabricated one.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

import duckdb

DATASET_ID = "nvidia/Nemotron-Personas-Korea"
DATASET_URL_TEMPLATE = (
    "https://huggingface.co/datasets/nvidia/Nemotron-Personas-Korea/"
    "resolve/main/data/train-0000{}-of-00009.parquet"
)
NUM_SHARDS = 9
DEFAULT_SEED = "persona-review-seed-2026"
DEFAULT_TARGET_N = 119  # 7 age_groups x 17 provinces, hard-balanced grid
POOL_PER_STRATUM = 5

REPO_ROOT = Path(__file__).resolve().parents[3]
OUT_PATH = REPO_ROOT / "skills" / "persona-review" / "personas" / "catalog.json"

# Demographic fields kept verbatim from the source row (all synthetic, no PII).
DEMO_FIELDS = [
    "sex", "age", "marital_status", "military_status", "family_type",
    "housing_type", "education_level", "bachelors_field", "occupation",
    "district", "province",
]

# --- stratification SQL fragments -------------------------------------------

OCCUPATION_GROUP_CASE = """
    CASE
      WHEN occupation = '무직' THEN '무직'
      WHEN occupation LIKE '%개발%' OR occupation LIKE '%프로그래%' OR occupation LIKE '%소프트웨어%' OR occupation LIKE '%IT%' THEN 'IT_개발'
      WHEN occupation LIKE '%디자인%' OR occupation LIKE '%예술%' OR occupation LIKE '%미술%' OR occupation LIKE '%음악%' THEN '디자인_예술'
      WHEN occupation LIKE '%마케팅%' OR occupation LIKE '%영업%' OR occupation LIKE '%판매%' OR occupation LIKE '%홍보%' THEN '마케팅_영업'
      WHEN occupation LIKE '%금융%' OR occupation LIKE '%보험%' OR occupation LIKE '%회계%' OR occupation LIKE '%은행%' THEN '금융_회계'
      WHEN occupation LIKE '%의료%' OR occupation LIKE '%간호%' OR occupation LIKE '%의사%' OR occupation LIKE '%약사%' THEN '의료_보건'
      WHEN occupation LIKE '%교사%' OR occupation LIKE '%교육%' OR occupation LIKE '%강사%' OR occupation LIKE '%교수%' THEN '교육'
      WHEN occupation LIKE '%법률%' OR occupation LIKE '%변호사%' OR occupation LIKE '%법무%' THEN '법률'
      WHEN occupation LIKE '%사무%' OR occupation LIKE '%비서%' OR occupation LIKE '%행정%' THEN '사무_행정'
      WHEN occupation LIKE '%서비스%' OR occupation LIKE '%조리%' OR occupation LIKE '%음식%' OR occupation LIKE '%청소%' OR occupation LIKE '%경비%' THEN '서비스_현장'
      WHEN occupation LIKE '%운전%' OR occupation LIKE '%운송%' OR occupation LIKE '%물류%' OR occupation LIKE '%적재%' THEN '운송_물류'
      WHEN occupation LIKE '%생산%' OR occupation LIKE '%제조%' OR occupation LIKE '%기능%' OR occupation LIKE '%기술%' THEN '기술_생산'
      WHEN occupation LIKE '%농%' OR occupation LIKE '%어업%' OR occupation LIKE '%임업%' THEN '농림수산'
      WHEN occupation LIKE '%경영%' OR occupation LIKE '%기획%' OR occupation LIKE '%관리%' THEN '경영_기획'
      ELSE '기타'
    END
"""

AGE_GROUP_CASE = """
    CASE
      WHEN age < 20 THEN '10대'
      WHEN age < 30 THEN '20대'
      WHEN age < 40 THEN '30대'
      WHEN age < 50 THEN '40대'
      WHEN age < 60 THEN '50대'
      WHEN age < 70 THEN '60대'
      ELSE '70+'
    END
"""

CAT_SIZES = {
    "age_group": 7,
    "province": 17,
    "occupation_group": 13,
    "education_level": 7,
}


def age_bucket(age: int) -> str:
    """English age-bucket label used in the shipped catalog (distinct from the
    Korean age_group used only for internal stratification SQL)."""
    if age < 30:
        return "20s"
    if age >= 70:
        return "70+"
    return f"{(age // 10) * 10}s"


def dataset_urls() -> list[str]:
    return [DATASET_URL_TEMPLATE.format(i) for i in range(NUM_SHARDS)]


def connect():
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    return con


def fetch_candidate_pool(con, seed: str):
    """Top-N ranked rows per (age_group, province) stratum.

    Ranking prefers non-'무직' occupation_group first, then a deterministic
    hash of (uuid, seed) for a stable pseudo-random tiebreak. Only the
    columns needed for stratification are read (column pruning via httpfs
    range requests keeps this to a light network fetch, not a 2GB download).
    """
    sql_urls = ", ".join(f"'{u}'" for u in dataset_urls())
    sql = f"""
        WITH base AS (
          SELECT uuid, age, province, occupation, education_level,
            {OCCUPATION_GROUP_CASE} AS occupation_group,
            {AGE_GROUP_CASE} AS age_group
          FROM read_parquet([{sql_urls}])
        ),
        ranked AS (
          SELECT *,
            ROW_NUMBER() OVER (
              PARTITION BY age_group, province
              ORDER BY (occupation_group = '무직') ASC, hash(uuid || '{seed}') ASC
            ) AS rn
          FROM base
        )
        SELECT uuid, age, age_group, province, occupation, occupation_group, education_level
        FROM ranked
        WHERE rn <= {POOL_PER_STRATUM}
        ORDER BY age_group, province, rn
    """
    rows = con.execute(sql).fetchall()
    cols = [d[0] for d in con.description]
    idx = {c: i for i, c in enumerate(cols)}
    return rows, idx


def greedy_select(rows, idx, target_n: int):
    """Pick 1 candidate per (age_group, province) stratum, greedily balancing
    occupation_group / education_level against a soft per-category cap.

    Guarantees perfectly even age_group / province marginals (one pick per
    cell). occupation_group / education_level are balanced on a best-effort
    basis from the available candidates in each cell's pool.
    """
    strata = defaultdict(list)
    for r in rows:
        key = (r[idx["age_group"]], r[idx["province"]])
        strata[key].append(r)

    n_strata = len(strata)
    caps = {
        axis: math.ceil(target_n / size * 1.6) for axis, size in CAT_SIZES.items()
    }

    counts = {axis: Counter() for axis in CAT_SIZES}
    selected = []

    for key in sorted(strata.keys()):
        candidates = strata[key]  # already ranked: non-무직 first, then hash
        best, best_score = None, None
        for c in candidates:
            score = 0
            for axis in ("occupation_group", "education_level"):
                val = c[idx[axis]]
                if counts[axis][val] >= caps[axis]:
                    score += 1
            if best is None or score < best_score:
                best, best_score = c, score
        selected.append(best)
        for axis in CAT_SIZES:
            counts[axis][best[idx[axis]]] += 1

    return selected, counts, n_strata


def fetch_full_rows(con, uuids, retries: int = 3):
    """SELECT * for the selected uuids across all shards.

    HF Hub range-requests over a full-column scan occasionally hit a
    transient Snappy decompression error (dropped/truncated HTTP range
    read) — retried with a fresh connection rather than failing the run.
    """
    sql_urls = ", ".join(f"'{u}'" for u in dataset_urls())
    uuid_list = ", ".join(f"'{u}'" for u in uuids)
    sql = f"""
        SELECT *
        FROM read_parquet([{sql_urls}])
        WHERE uuid IN ({uuid_list})
    """
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            rows = con.execute(sql).fetchall()
            cols = [d[0] for d in con.description]
            return [dict(zip(cols, r)) for r in rows]
        except duckdb.Error as e:
            last_err = e
            print(f"      attempt {attempt}/{retries} failed: {e}", file=sys.stderr)
            con = connect()  # fresh connection before retrying
    raise last_err


# --- review_lens heuristic tagging ------------------------------------------

def occupation_group_of(occupation: str) -> str:
    """Re-derive the same occupation_group bucket in Python (for tagging full
    rows fetched by SELECT *, which don't carry the SQL-computed column)."""
    o = occupation or ""
    if o == "무직":
        return "무직"
    keyword_map = [
        (("개발", "프로그래", "소프트웨어", "IT"), "IT_개발"),
        (("디자인", "예술", "미술", "음악"), "디자인_예술"),
        (("마케팅", "영업", "판매", "홍보"), "마케팅_영업"),
        (("금융", "보험", "회계", "은행"), "금융_회계"),
        (("의료", "간호", "의사", "약사"), "의료_보건"),
        (("교사", "교육", "강사", "교수"), "교육"),
        (("법률", "변호사", "법무"), "법률"),
        (("사무", "비서", "행정"), "사무_행정"),
        (("서비스", "조리", "음식", "청소", "경비"), "서비스_현장"),
        (("운전", "운송", "물류", "적재"), "운송_물류"),
        (("생산", "제조", "기능", "기술"), "기술_생산"),
        (("농", "어업", "임업"), "농림수산"),
        (("경영", "기획", "관리"), "경영_기획"),
    ]
    for keywords, group in keyword_map:
        if any(k in o for k in keywords):
            return group
    return "기타"


def tag_review_lens(row: dict) -> list[str]:
    """Heuristic review-lens tagging from demographics. Returns 1-2 lens
    tags from {UX, 카피, 접근성, 신뢰, 가격민감}.

    Rules are additive (a persona can trigger multiple); result is capped at
    2, ordered by priority, with a UX fallback if nothing else matched.
    """
    age = row.get("age") or 0
    occ_group = occupation_group_of(row.get("occupation"))
    edu = row.get("education_level") or ""

    tags = []

    # Priority 1: accessibility — older adults (lower digital literacy / vision)
    if age >= 60:
        tags.append("접근성")

    # Priority 2: trust — risk-averse / regulated professions
    if occ_group in ("금융_회계", "법률", "의료_보건", "경영_기획"):
        tags.append("신뢰")

    # Priority 3: UX — hands-on builders of interfaces
    if occ_group in ("IT_개발", "디자인_예술"):
        tags.append("UX")

    # Priority 4: copy — content-literacy-sensitive occupations / high education
    if occ_group in ("마케팅_영업", "교육") or edu in ("대학원", "4년제 대학교"):
        tags.append("카피")

    # Priority 5: price sensitivity — students / young adults / unemployed
    if age <= 25 or occ_group == "무직":
        tags.append("가격민감")

    seen = set()
    deduped = []
    for t in tags:
        if t not in seen:
            seen.add(t)
            deduped.append(t)

    if not deduped:
        deduped = ["UX"]

    return deduped[:2]


def parse_list(raw) -> list[str]:
    """The *_list columns are stringified Python lists; parse leniently."""
    if isinstance(raw, list):
        return [str(x) for x in raw]
    if not isinstance(raw, str) or not raw.strip():
        return []
    try:
        import ast
        val = ast.literal_eval(raw)
        if isinstance(val, (list, tuple)):
            return [str(x) for x in val]
    except (ValueError, SyntaxError):
        pass
    return []


def to_persona(r: dict) -> dict:
    p = {"id": r.get("uuid")}
    for f in DEMO_FIELDS:
        p[f] = r.get(f)
    p["age"] = int(r.get("age") or 0)
    p["age_bucket"] = age_bucket(p["age"])
    p["summary"] = (r.get("persona") or "").strip()
    p["background"] = (r.get("cultural_background") or "").strip()
    p["hobbies"] = parse_list(r.get("hobbies_and_interests_list"))
    p["skills"] = parse_list(r.get("skills_and_expertise_list"))
    p["review_lens"] = tag_review_lens(r)
    return p


def build(target_n: int, seed: str) -> dict:
    con = connect()

    print(f"[1/4] Connecting to DuckDB httpfs and scanning {DATASET_ID} "
          f"({NUM_SHARDS} shards, column-pruned)...", file=sys.stderr)

    print("[2/4] Fetching stratification candidate pool "
          f"(top {POOL_PER_STRATUM} per age_group x province cell)...", file=sys.stderr)
    rows, idx = fetch_candidate_pool(con, seed)
    print(f"      candidate pool size: {len(rows)}", file=sys.stderr)
    if not rows:
        raise SystemExit("candidate pool empty — dataset unreachable or schema changed")

    print("[3/4] Greedy quota-balanced selection...", file=sys.stderr)
    selected, counts, n_strata = greedy_select(rows, idx, target_n)
    print(f"      strata covered: {n_strata}, selected: {len(selected)}", file=sys.stderr)
    for axis in CAT_SIZES:
        c = counts[axis]
        top = c.most_common(1)[0] if c else ("-", 0)
        print(f"      {axis}: {len(c)} categories, max={top[0]} "
              f"({top[1]}, {top[1] / len(selected) * 100:.1f}%)", file=sys.stderr)

    uuids = [r[idx["uuid"]] for r in selected]
    print(f"[4/4] Fetching full rows for {len(uuids)} selected personas...", file=sys.stderr)
    full_rows = fetch_full_rows(con, uuids)
    by_uuid = {r["uuid"]: r for r in full_rows}

    personas = [to_persona(by_uuid[u]) for u in uuids]
    personas.sort(key=lambda p: (p["province"] or "", -(p["age"] or 0)))

    return {
        "_meta": {
            "name": "Nemotron Korean Persona Catalog (stratified sample)",
            "purpose": "Citizen/user review panel for /persona-review (UX / copy / content).",
            "source_dataset": DATASET_ID,
            "source_url": f"https://huggingface.co/datasets/{DATASET_ID}",
            "source_creator": "NVIDIA",
            "license": "CC BY 4.0",
            "license_url": "https://creativecommons.org/licenses/by/4.0/",
            "attribution": (
                "Contains information from nvidia/Nemotron-Personas-Korea, "
                "made available by NVIDIA under the CC BY 4.0 license."
            ),
            "modifications": (
                "Stratified subsample of the full 1M-row / 9-shard dataset, selected "
                "via DuckDB httpfs range queries: age_group x province hard-balanced "
                "across a 7x17 grid (one persona per cell — even, non-population-"
                "proportional, so every province is represented for panel diversity), "
                "occupation_group x education_level soft-balanced. Demographic + "
                "one-line persona-summary + background + hobby/skill list fields kept; "
                "verbose per-domain narrative columns dropped. No fields added except "
                "the derived `review_lens` tag (1-2 per persona, computed from "
                "demographics + occupation only — see tag_review_lens() in the "
                "generator script)."
            ),
            "synthetic_note": (
                "Every persona here is SYNTHETIC (NVIDIA Nemotron synthetic data), grounded in "
                "KOSIS/court/insurance/rural-economy distributions. No persona is a real person; "
                "any Korean name inside a summary is generated, not a real individual's."
            ),
            "pii_note": (
                "No name/contact/identifier fields. 'id' is the dataset's own synthetic "
                "uuid, retained for provenance only."
            ),
            "generated_by": "skills/persona-review/scripts/build_catalog.py",
            "stratification_axes": ["age_group", "province", "occupation_group", "education_level"],
            "sample_size": len(personas),
            "random_seed": seed,
            "strata_covered": n_strata,
        },
        "personas": personas,
    }


def summarize(catalog: dict) -> str:
    ps = catalog["personas"]
    prov = defaultdict(int)
    ages = defaultdict(int)
    sex = defaultdict(int)
    lens = defaultdict(int)
    for p in ps:
        prov[p["province"]] += 1
        ages[p["age_bucket"]] += 1
        sex[p["sex"]] += 1
        for lens_tag in p.get("review_lens", []):
            lens[lens_tag] += 1
    lines = [f"personas: {len(ps)}",
             f"provinces ({len(prov)}): " + ", ".join(f"{k}:{v}" for k, v in sorted(prov.items())),
             "age buckets: " + ", ".join(f"{k}:{v}" for k, v in sorted(ages.items())),
             "sex: " + ", ".join(f"{k}:{v}" for k, v in sorted(sex.items())),
             "review_lens: " + ", ".join(f"{k}:{v}" for k, v in sorted(lens.items()))]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--target-n", type=int, default=DEFAULT_TARGET_N,
                     help="target strata count (effective size = strata actually covered)")
    ap.add_argument("--seed", type=str, default=DEFAULT_SEED,
                     help="deterministic tiebreak seed (string, hashed with uuid)")
    ap.add_argument("--dry-run", action="store_true", help="print stats, write nothing")
    args = ap.parse_args()

    catalog = build(args.target_n, args.seed)
    print(summarize(catalog), file=sys.stderr)

    if args.dry_run:
        print("(dry-run — catalog.json not written)", file=sys.stderr)
        return 0

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT_PATH.relative_to(REPO_ROOT)} ({len(catalog['personas'])} personas)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
