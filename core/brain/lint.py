#!/usr/bin/env python3
"""Deterministic lint gate for the agent brain's notes/ store.

The machine backstop the `brain-ingest` distill skill must pass (0 errors) before
a distilled note is considered promotable — the brain's mirror of the reference
vault's wiki_lint discipline, so the working layer holds the same structural
contract as the human SSOT. Domain-neutral: reads ONLY through store.py, and
knows nothing of any vault path or project.

Two severities:

  ERRORS (exit 1) — the note is structurally malformed; the distill must fix it.
    E1  no frontmatter
    E2  id absent/mismatch   — frontmatter has no `id:` key, or `id:` differs from
                               the filename stem
    E3  type absent/mismatch — frontmatter has no `type:` key, or `type:` differs
                               from the parent directory
    E4  provenance incomplete — a required key (ai/session/generated_by/source/
                                 kind) is missing or empty
    E5  provenance kind invalid — `kind` is not exactly `generated` or `user`
                                   (the trust sentinel must be one of the two)
    E6  trust-sentinel forged — an AI distillation (`generated_by: brain-ingest`)
                                carries a `kind:` other than `generated`; the
                                sentinel cannot be laundered to `user` on the
                                AI-authored path

  WARNINGS (exit 0, or exit 1 under --strict) — reported, non-fatal by default.
    W1  isolated note    — no typed edges in EITHER direction (the note neither
                           links out nor is linked to; atomicity favors >=1
                           connection — the >=2 distill target is a skill-level
                           policy). A hub that only RECEIVES edges (e.g. a topic
                           note many notes tag) is connected, not isolated.
                           Seed-status notes (status: seed — imported, not yet
                           connected) are exempt: a seed is declared-unconnected
                           by design, and a promotable note must first leave
                           seed status (brain-ingest distills at status:growing)
    E/W2 dangling edge   — an edge target id has no note in the store

`--strict` promotes warnings to errors: that is the >=1-edge / no-dangling gate
the distill skill runs a candidate note through before promotion.

Usage:
  python3 lint.py [--strict] [--json]
Exit 0: clean (no errors; warnings allowed unless --strict). Exit 1: violations.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import store  # noqa: E402

_VALID_KIND = {"generated", "user"}


def lint() -> tuple[list[dict], list[dict], int]:
    """Scan notes/ → (errors, warnings, note_count). Each finding: {note, code,
    message}. note_count is the number of notes actually scanned, so the caller
    reports a count consistent with what was linted (no second directory walk).

    Never raises: an unparseable note surfaces as an E1/E4 finding, not a crash,
    so the gate is safe to run over a shared, machine-written store."""
    errors: list[dict] = []
    warnings: list[dict] = []
    scanned: list[tuple[Path, object, dict, list]] = []   # (path, fm, node, edges)
    ids: set[str] = set()

    for p in store.iter_notes():
        text = store._safe_read(p)
        fm, _ = store.split_frontmatter(text)
        node, edges = store._parse(p, text)   # one read shared by every check below
        scanned.append((p, fm, node, edges))
        ids.add(node["id"])

    # Every edge target across the store — a note that appears here is linked
    # TO, so it is connected even with zero outgoing edges (W1 hub case).
    targets: set[str] = set()
    for _, _, _, edges in scanned:
        for e in edges:
            targets.add(e["target"])

    for p, fm, node, edges in scanned:
        rel = node.get("file") or p.name

        if fm is None:
            errors.append({"note": rel, "code": "E1", "message": "no frontmatter"})
            # A note without frontmatter has no reliable id/type/provenance to
            # check further; report the one root cause and move on.
            continue

        # E2/E3 read the RAW frontmatter (store._scalar → None if the key is
        # absent), not node["id"]/node["type"] — those fall back to the path
        # component, which would make an omitted key look valid.
        raw_id = store._scalar(fm, "id")
        if raw_id is None:
            errors.append({"note": rel, "code": "E2", "message": "frontmatter has no id: key"})
        elif raw_id != p.stem:
            errors.append({"note": rel, "code": "E2",
                           "message": f"id '{raw_id}' != filename stem '{p.stem}'"})
        raw_type = store._scalar(fm, "type")
        if raw_type is None:
            errors.append({"note": rel, "code": "E3", "message": "frontmatter has no type: key"})
        elif raw_type != p.parent.name:
            errors.append({"note": rel, "code": "E3",
                           "message": f"type '{raw_type}' != parent dir '{p.parent.name}'"})

        prov = node.get("provenance") or {}
        missing = [k for k in store._PROV_KEYS if not (prov.get(k) or "").strip()]
        if missing:
            errors.append({"note": rel, "code": "E4",
                           "message": f"provenance missing/empty: {', '.join(missing)}"})
        kind = (prov.get("kind") or "").strip()
        if kind and kind not in _VALID_KIND:
            errors.append({"note": rel, "code": "E5",
                           "message": f"provenance kind '{kind}' not in {sorted(_VALID_KIND)}"})
        # E6: an AI distillation must carry kind=generated — the trust sentinel
        # cannot be laundered to 'user' on the AI-authored (brain-ingest) path.
        # The seed path imports human-curated notes as kind=user under a DIFFERENT
        # generated_by, so this rule only ever constrains genuine distillations.
        if (prov.get("generated_by") or "").strip() == "brain-ingest" and kind and kind != "generated":
            errors.append({"note": rel, "code": "E6",
                           "message": f"brain-ingest note must be kind=generated, not '{kind}' (forged trust sentinel)"})

        # W1 = isolated in BOTH directions. Skips status=seed (seeds are
        # declared-unconnected imports; the promotion path — brain-ingest —
        # writes status=growing, so the strict gate keeps its teeth exactly
        # where promotion happens) and skips edge TARGETS (a hub that only
        # receives edges is connected, not isolated).
        if (node.get("edge_count", 0) == 0
                and (node.get("status") or "") != "seed"
                and node["id"] not in targets):
            warnings.append({"note": rel, "code": "W1",
                             "message": "isolated: no typed edges in or out (atomicity favors >=1)"})
        for e in edges:
            if e["target"] not in ids:
                warnings.append({"note": rel, "code": "W2",
                                 "message": f"dangling {e['type']} edge -> '{e['target']}' (no such note)"})

    return errors, warnings, len(scanned)


def _cli(argv: list[str]) -> int:
    strict = "--strict" in argv
    as_json = "--json" in argv
    errors, warnings, n_notes = lint()
    fatal = errors + (warnings if strict else [])

    if as_json:
        print(json.dumps({"errors": errors, "warnings": warnings,
                          "strict": strict, "clean": not fatal}, indent=2))
    else:
        for f in errors:
            print(f"  ERROR [{f['code']}] {f['note']}: {f['message']}")
        for f in warnings:
            tag = "ERROR" if strict else "warn "
            print(f"  {tag} [{f['code']}] {f['note']}: {f['message']}")
        if fatal:
            print(f"FAIL — {len(errors)} error(s), {len(warnings)} warning(s) over {n_notes} note(s)"
                  + (" (--strict)" if strict else ""))
        else:
            print(f"PASS — {n_notes} note(s) clean"
                  + (f", {len(warnings)} warning(s)" if warnings else ""))
    return 1 if fatal else 0


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv[1:]))
