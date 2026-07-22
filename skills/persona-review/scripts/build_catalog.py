#!/usr/bin/env python3
"""build_catalog.py — regenerate the stratified Korean persona catalog.

Reproducible builder for ``skills/persona-review/personas/catalog.json``: a
stratified subsample of the public ``nvidia/Nemotron-Personas-Korea`` dataset
(CC BY 4.0), used by ``/persona-review`` as a citizen/user review panel.

Why a subsample: the source is 1.0M synthetic personas (~2 GB parquet). A
review only ever seats a handful of panelists, so we ship a small, demographically
diverse catalog instead of the whole set. The rows are *synthetic* personas
grounded in real KOSIS/court/insurance distributions — no real individuals — and
carry no name/contact/identifier fields, so nothing here is PII.

Determinism: a fixed seed picks fixed random row offsets against the immutable
dataset snapshot on the HF datasets-server, so re-running yields the same catalog
(network-only; no local dataset download, no heavy deps beyond ``requests``).

Usage:
    python3 skills/persona-review/scripts/build_catalog.py            # write catalog.json
    python3 skills/persona-review/scripts/build_catalog.py --dry-run  # print stats, write nothing
    python3 skills/persona-review/scripts/build_catalog.py --size 120 --seed 42

If the datasets-server is unreachable, this exits non-zero WITHOUT touching the
committed catalog — a stale-but-real catalog is always better than a fabricated one.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import time
from collections import defaultdict
from pathlib import Path

import requests

DATASET = "nvidia/Nemotron-Personas-Korea"
CONFIG = "default"
SPLIT = "train"
ROWS_URL = "https://datasets-server.huggingface.co/rows"
TOTAL_ROWS = 1_000_000  # per the dataset viewer (1.0M train rows)
PAGE = 100              # datasets-server max rows per request

# Demographic fields kept verbatim from the source row (all synthetic, no PII).
DEMO_FIELDS = [
    "sex", "age", "marital_status", "military_status", "family_type",
    "housing_type", "education_level", "bachelors_field", "occupation",
    "district", "province",
]

REPO_ROOT = Path(__file__).resolve().parents[3]
OUT_PATH = REPO_ROOT / "skills" / "persona-review" / "personas" / "catalog.json"


def age_bucket(age: int) -> str:
    if age < 30:
        return "20s"
    if age >= 70:
        return "70+"
    return f"{(age // 10) * 10}s"


def fetch_pool(n_batches: int, rng: random.Random) -> list[dict]:
    """Fetch a pool of rows from fixed random offsets (deterministic via rng)."""
    offsets = sorted({rng.randint(0, TOTAL_ROWS - PAGE) for _ in range(n_batches)})
    pool: dict[str, dict] = {}
    for off in offsets:
        row_json = _get_rows(off)
        for item in row_json:
            r = item["row"]
            uid = r.get("uuid")
            if uid and uid not in pool:
                pool[uid] = r
        time.sleep(0.8)  # be polite to the datasets-server (avoid 429)
    return list(pool.values())


def _get_rows(offset: int, retries: int = 5) -> list[dict]:
    params = {
        "dataset": DATASET, "config": CONFIG, "split": SPLIT,
        "offset": offset, "length": PAGE,
    }
    last = None
    for attempt in range(retries):
        try:
            resp = requests.get(ROWS_URL, params=params, timeout=60)
            if resp.status_code == 200:
                return resp.json().get("rows", [])
            # 429 / 503: back off harder and longer before retrying
            wait = (8.0 if resp.status_code in (429, 503) else 2.0) * (attempt + 1)
            last = f"HTTP {resp.status_code}: {resp.text[:120]}"
        except requests.RequestException as exc:  # network error
            wait = 2.0 * (attempt + 1)
            last = str(exc)
        time.sleep(wait)
    raise SystemExit(f"datasets-server unreachable at offset {offset}: {last}")


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
    p["age_bucket"] = age_bucket(int(r.get("age") or 0))
    p["summary"] = (r.get("persona") or "").strip()
    p["background"] = (r.get("cultural_background") or "").strip()
    p["hobbies"] = parse_list(r.get("hobbies_and_interests_list"))
    p["skills"] = parse_list(r.get("skills_and_expertise_list"))
    return p


def allocate(province_counts: dict[str, int], size: int) -> dict[str, int]:
    """Floor-1-per-province, then largest-remainder proportional to pool frequency."""
    provinces = sorted(province_counts)
    if len(provinces) >= size:  # more provinces than slots: 1 each until full
        return {pv: 1 for pv in provinces[:size]}
    alloc = {pv: 1 for pv in provinces}
    remaining = size - len(provinces)
    total = sum(province_counts.values())
    shares = {pv: remaining * province_counts[pv] / total for pv in provinces}
    for pv in provinces:
        alloc[pv] += int(shares[pv])
    leftover = size - sum(alloc.values())
    frac = sorted(provinces, key=lambda pv: shares[pv] - int(shares[pv]), reverse=True)
    for pv in frac[:leftover]:
        alloc[pv] += 1
    return alloc


def pick_diverse(rows: list[dict], k: int, rng: random.Random) -> list[dict]:
    """Greedily pick k rows maximizing (age_bucket, sex) coverage; deterministic."""
    pool = rows[:]
    rng.shuffle(pool)
    chosen: list[dict] = []
    seen: set = set()
    # first pass: one row per unseen (age_bucket, sex) combo
    for r in pool:
        if len(chosen) >= k:
            break
        key = (age_bucket(int(r.get("age") or 0)), r.get("sex"))
        if key not in seen:
            seen.add(key)
            chosen.append(r)
    # second pass: fill the remainder in shuffled order
    if len(chosen) < k:
        picked_ids = {r["uuid"] for r in chosen}
        for r in pool:
            if len(chosen) >= k:
                break
            if r["uuid"] not in picked_ids:
                chosen.append(r)
    return chosen[:k]


def build(size: int, seed: int, n_batches: int) -> dict:
    rng = random.Random(seed)
    pool = fetch_pool(n_batches, rng)
    if len(pool) < size:
        raise SystemExit(
            f"pool too small ({len(pool)} rows) for size {size}; raise --batches")

    by_prov: dict[str, list[dict]] = defaultdict(list)
    for r in pool:
        by_prov[r.get("province") or "unknown"].append(r)

    alloc = allocate({pv: len(rs) for pv, rs in by_prov.items()}, size)

    selected: list[dict] = []
    pick_rng = random.Random(seed + 1)
    for pv in sorted(alloc):
        k = min(alloc[pv], len(by_prov[pv]))
        selected.extend(pick_diverse(by_prov[pv], k, pick_rng))

    personas = [to_persona(r) for r in selected]
    personas.sort(key=lambda p: (p["province"] or "", -(int(p["age"] or 0))))

    return {
        "_meta": {
            "name": "Nemotron Korean Persona Catalog (stratified sample)",
            "purpose": "Citizen/user review panel for /persona-review (UX / copy / content).",
            "source_dataset": DATASET,
            "source_url": f"https://huggingface.co/datasets/{DATASET}",
            "source_creator": "NVIDIA",
            "license": "CC BY 4.0",
            "license_url": "https://creativecommons.org/licenses/by/4.0/",
            "attribution": (
                "Contains information from nvidia/Nemotron-Personas-Korea, "
                "made available by NVIDIA under the CC BY 4.0 license."
            ),
            "modifications": (
                "Stratified subsample (province x age-bucket x sex) of demographic + "
                "one-line persona-summary + background + hobby/skill list fields. "
                "Verbose per-domain narrative columns dropped; no fields added or edited."
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
            "sample_size": len(personas),
            "random_seed": seed,
            "fetch_batches": n_batches,
            "pool_size": len(pool),
        },
        "personas": personas,
    }


def summarize(catalog: dict) -> str:
    ps = catalog["personas"]
    prov = defaultdict(int)
    ages = defaultdict(int)
    sex = defaultdict(int)
    for p in ps:
        prov[p["province"]] += 1
        ages[p["age_bucket"]] += 1
        sex[p["sex"]] += 1
    lines = [f"personas: {len(ps)}",
             f"provinces ({len(prov)}): " + ", ".join(f"{k}:{v}" for k, v in sorted(prov.items())),
             "age buckets: " + ", ".join(f"{k}:{v}" for k, v in sorted(ages.items())),
             "sex: " + ", ".join(f"{k}:{v}" for k, v in sorted(sex.items()))]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--size", type=int, default=120)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--batches", type=int, default=60,
                    help="random offset pages to fetch (100 rows each)")
    ap.add_argument("--dry-run", action="store_true", help="print stats, write nothing")
    args = ap.parse_args()

    catalog = build(args.size, args.seed, args.batches)
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
