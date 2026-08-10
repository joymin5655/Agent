#!/usr/bin/env python3
"""Selective one-time SEED of the agent brain from existing curated sources.

Bootstraps notes/ so the brain isn't empty on day one, importing ONLY
high-signal, already-curated material — never a bulk dump (the retrieval-poisoning
anti-pattern the research flagged). Two sources, both DOMAIN-NEUTRAL: every path
comes from an argument or env var, never hardcoded — this ships in the harness
and must not know any personal vault/memory path.

  --vault <dir>    a curated wiki vault: notes whose frontmatter `status` is in the
                   allowed set (default evergreen,growing) and whose `confidence`
                   (if present) clears --min-confidence. Typed edges are preserved.
                   Imported with provenance kind=user (human-curated origin).
  --memory <dir>   a native path-keyed memory dir: notes whose frontmatter
                   metadata.type is in the allowed set (default feedback,project).
                   Mapped to a brain note type (feedback->insight, project->episode).
                   Imported with provenance kind=user.

This is a bootstrap IMPORT (source -> brain), distinct from the runtime one-way
promotion (brain -> vault). It only ever WRITES to the brain via store.write_note;
it never writes back to a source. claude-mem bulk is intentionally excluded (noise).

Dry-run BY DEFAULT: prints exactly what WOULD be seeded, and what would be skipped
and why (no silent truncation). Pass --apply to actually write. After --apply, run
`python3 core/brain/lint.py` — an error-free store is the success gate.

Usage:
  python3 seed.py --vault <dir> [--memory <dir> ...] [--apply]
                  [--vault-status evergreen,growing] [--min-confidence 0.0]
                  [--memory-types feedback,project]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import store  # noqa: E402

# native metadata.type -> brain note type. Unlisted selected types default to insight.
_MEM_TYPE_MAP = {"feedback": "insight", "project": "episode",
                 "insight": "insight", "procedure": "procedure", "episode": "episode"}


def _edges_from_fm(fm: str) -> dict:
    """Typed-edge dict {etype: [targets]} from a source note's `edges:` block —
    reuses the store's own scanner so the brain and the source read edges
    identically."""
    edges: dict = {}
    for k, v in store._scan_indented_block(fm, "edges"):
        if k in store.EDGE_TYPES:
            targets = [t.strip() for t in store._WIKILINK_RE.findall(v) if t.strip()]
            if targets:
                edges.setdefault(k, []).extend(targets)
    return edges


def _skip_reason(node_id: str, note_type: str):
    """Why store.write_note would reject this record (unsafe id/type), or None."""
    try:
        store._safe_component(node_id, "node_id")
        store._safe_component(note_type or "concept", "note_type")
        return None
    except ValueError as e:
        return str(e)


def _record(node_id, note_type, title, body, edges, status, confidence, source, kind):
    """One seed record. `kind` is the trust sentinel of the ORIGIN: 'user' for a
    human-curated source (a wiki vault), 'generated' for an AI-authored source (a
    native memory the assistant wrote). It must reflect real authorship — labeling
    AI-authored notes 'user' would wrongly make them immune to future curation."""
    rec = {"node_id": node_id, "note_type": note_type, "title": title or node_id,
           "body": body, "edges": edges, "status": status, "confidence": confidence,
           "source": source, "kind": kind, "skip": _skip_reason(node_id, note_type)}
    return rec


def vault_candidates(vault_dir: Path, statuses: set, min_conf: float) -> list[dict]:
    """Selected curated-vault notes as seed records. A note qualifies when it has
    frontmatter, an id, a status in `statuses`, and (if it declares one) a
    confidence >= min_conf."""
    out: list[dict] = []
    if not vault_dir.exists():
        return out
    for p in sorted(vault_dir.rglob("*.md")):
        if "_templates" in p.parts:
            continue
        text = store._safe_read(p)
        fm, body = store.split_frontmatter(text)
        if fm is None:
            continue
        node_id = store._scalar(fm, "id")
        if not node_id:
            continue
        status = store._scalar(fm, "status")
        if status not in statuses:
            continue
        conf_raw = store._scalar(fm, "confidence")
        try:
            conf = float(conf_raw) if conf_raw is not None else None
        except ValueError:
            conf = None
        if conf is not None and conf < min_conf:
            continue
        note_type = store._scalar(fm, "type") or "concept"
        # A curated wiki vault is human-authored -> kind=user (trusted origin).
        out.append(_record(node_id, note_type, store._scalar(fm, "title"),
                           (body or "").strip(), _edges_from_fm(fm), status, conf,
                           f"vault:{node_id}", "user"))
    return out


def memory_candidates(mem_dir: Path, types: set) -> list[dict]:
    """Selected native-memory notes as seed records. Selection is by frontmatter
    metadata.type (not filename), skipping the MEMORY.md index and archive/."""
    out: list[dict] = []
    if not mem_dir.exists():
        return out
    for p in sorted(mem_dir.rglob("*.md")):
        if p.name == "MEMORY.md" or "archive" in p.parts:
            continue
        text = store._safe_read(p)
        fm, body = store.split_frontmatter(text)
        if fm is None:
            continue
        meta = {k: v for k, v in store._scan_indented_block(fm, "metadata")}
        mtype = (meta.get("type") or "").strip()
        if mtype not in types:
            continue
        name = store._scalar(fm, "name") or p.stem
        node_id = "mem-" + store.slugify(name)
        note_type = _MEM_TYPE_MAP.get(mtype, "insight")
        title = store._scalar(fm, "description") or name
        # A native memory is AI-authored -> kind=generated (curatable, not immutable).
        out.append(_record(node_id, note_type, title, (body or "").strip(),
                           {}, "seed", None, f"memory:{p.name}", "generated"))
    return out


def apply(records: list[dict]) -> tuple[int, list[dict]]:
    """Write every non-skipped record to the brain. Returns (written, skipped).

    Guards against an in-run id collision: two source notes mapping to the same
    brain id would otherwise have the second silently overwrite the first
    (write_note is id-keyed). The first wins and each later collider is reported
    as skipped — a dropped note is surfaced, never silent."""
    written = 0
    skipped: list[dict] = []
    seen: set = set()
    for r in records:
        if r["skip"]:
            skipped.append(r)
            continue
        if r["node_id"] in seen:
            skipped.append({**r, "skip": f"id collision — '{r['node_id']}' already written this run ({r['source']})"})
            continue
        try:
            store.write_note(
                node_id=r["node_id"], note_type=r["note_type"], title=r["title"],
                body=r["body"], edges=r["edges"], status=r["status"],
                confidence=r["confidence"],
                provenance={"ai": "seed", "session": "seed", "generated_by": "brain-seed",
                            "source": r["source"], "kind": r["kind"]})
            seen.add(r["node_id"])
            written += 1
        except (ValueError, OSError) as e:
            skipped.append({**r, "skip": f"write failed: {e}"})
    return written, skipped


def _report(label: str, recs: list[dict]) -> None:
    sel = [r for r in recs if not r["skip"]]
    skp = [r for r in recs if r["skip"]]
    print(f"{label}: {len(sel)} selected, {len(skp)} skipped")
    for r in sel:
        bits = [r["note_type"], f"status={r['status']}"]
        if r["confidence"] is not None:
            bits.append(f"conf={r['confidence']}")
        ne = sum(len(v) for v in r["edges"].values())
        if ne:
            bits.append(f"{ne} edge(s)")
        print(f"  + {r['node_id']}  ({', '.join(bits)})")
    for r in skp:
        print(f"  - {r['node_id']}  SKIPPED: {r['skip']}")


def _cli(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="seed.py", add_help=True)
    ap.add_argument("--vault", type=str, default=None)
    ap.add_argument("--memory", action="append", default=[])
    ap.add_argument("--vault-status", default="evergreen,growing")
    ap.add_argument("--min-confidence", type=float, default=0.0)
    ap.add_argument("--memory-types", default="feedback,project")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args(argv)

    if not args.vault and not args.memory:
        print("nothing to do: pass --vault <dir> and/or --memory <dir>", file=sys.stderr)
        return 2

    statuses = {s.strip() for s in args.vault_status.split(",") if s.strip()}
    mtypes = {s.strip() for s in args.memory_types.split(",") if s.strip()}

    records: list[dict] = []
    if args.vault:
        v = vault_candidates(Path(args.vault).expanduser(), statuses, args.min_confidence)
        _report(f"VAULT ({args.vault}) [status in {sorted(statuses)}, conf>={args.min_confidence}]", v)
        records += v
    for m in args.memory:
        recs = memory_candidates(Path(m).expanduser(), mtypes)
        _report(f"MEMORY ({m}) [type in {sorted(mtypes)}]", recs)
        records += recs

    writable = [r for r in records if not r["skip"]]
    print(f"\nTOTAL: {len(writable)} note(s) writable, "
          f"{len(records) - len(writable)} skipped.")

    if not args.apply:
        print(f"DRY-RUN — nothing written. Brain: {store.brain_dir()}")
        print("Re-run with --apply to write, then: python3 core/brain/lint.py")
        return 0

    written, skipped = apply(records)
    print(f"APPLIED — wrote {written} note(s) to {store.notes_dir()}, {len(skipped)} skipped.")
    for r in skipped:
        print(f"  - {r['node_id']}  SKIPPED: {r['skip']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
