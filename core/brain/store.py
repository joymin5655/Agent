#!/usr/bin/env python3
"""Domain-neutral atomic-note store for the cross-AI agent brain (L3 user store).

Mirrors the typed-edge Zettelkasten schema of a curated wiki vault, but as a
MACHINE-writable working layer shared across Claude / Codex / Gemini sessions:

    <brain>/notes/<type>/<id>.md         curated typed atomic notes (the graph)
    <brain>/raw/<ai>/<stamp>-<slug>.md   quarantined session captures (NOT in graph)
    <brain>/.graph/{nodes,edges}.jsonl   materialized graph (rebuilt from notes/)

`<brain>` defaults to ~/.agent/brain and is overridable with $AGENT_BRAIN_DIR.

Every record carries a `provenance:` block — which AI wrote it, which session,
what produced it, its origin source, and a generated|user `kind` sentinel — so a
later re-ingest touches only AI-authored (`generated`) material and human-curated
(`user`) content is never silently overwritten. Agents write freely to raw/;
notes/ is populated only by the distill (ingest) and seed paths, never by a raw
capture.

Frontmatter uses the vault convention: a YAML block between the first two `---`
fences. Typed edges use Obsidian `[[wikilink]]` syntax — not valid YAML — so the
`edges:` and `provenance:` blocks are read with a line scanner, not a YAML parser.
No third-party dependency. See core/brain/schema.md for the full contract.
"""
from __future__ import annotations

import datetime as _dt
import os
import re
from pathlib import Path

# 10 canonical typed edges — mirrors the reference vault schema.
EDGE_TYPES = [
    "supports", "extends", "instantiates", "refines", "near-miss",
    "contradicts", "triggered-by", "requires", "topic-tag", "thesis-tag",
]

# Note types (subdir under notes/). Permissive: an unknown type is allowed and
# lands in its own subdir — the store never rejects a write.
NOTE_TYPES = [
    "concept", "insight", "procedure", "episode", "thesis",
    "topic", "entity", "source", "comparison", "synthesis",
]

_DEFAULT_DIR = "~/.agent/brain"

_FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", re.DOTALL)
_WIKILINK_RE = re.compile(r"\[\[([^\]|#]+)")   # capture target id, drop |alias / #heading
_SLUG_RE = re.compile(r"[^a-z0-9]+")
# A safe single path component: starts alphanumeric, then alphanumerics + . _ -.
# Forbids '/' and '\' (not in the class) and any leading dot, so it can never be
# a path separator, '..', or an absolute path — write_note builds a file path
# from node_id/note_type, so an unsanitized id would otherwise allow traversal.
_SAFE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

_PROV_KEYS = ("ai", "session", "generated_by", "source", "kind")
# Frontmatter values are SINGLE-LINE by contract. A line-break char in an emitted
# value would let a hostile title/source/edge inject extra frontmatter lines — the
# parser (`_scan_indented_block`) is a line scanner over `str.splitlines()`, so any
# break is a structural boundary that can forge the provenance trust sentinel
# (kind: generated -> user). The neutralized set MUST equal what `str.splitlines()`
# honors, else a smuggled break survives the emitter and re-appears at read time:
# that is \x00-\x1f (incl. \n \r \v \f \x1c-\x1e) + \x7f AND the extended Unicode
# line separators U+0085 (NEL), U+2028 (LINE SEP), U+2029 (PARAGRAPH SEP) — the
# latter three are NOT in \x00-\x1f and were the CWE-93 injection gap. Collapse all
# of them to a space.
_CONTROL_RE = re.compile("[\x00-\x1f\x7f\x85\u2028\u2029]")
_PROV_KEY_RE = re.compile(r"^[a-z][a-z0-9_]*$")
# Atomic notes are tiny; cap read size so a huge planted note can't DoS search/extract.
_MAX_NOTE_BYTES = 1_000_000
# Symmetric WRITE cap for a raw capture body: brain_capture (the MCP write tool)
# accepts an arbitrary body, so without this a single multi-hundred-MB capture
# could exhaust disk — the read cap above never covers it because search/extract
# don't read raw/. Oversize bodies are truncated (quarantine is low-stakes), not
# rejected, so a large capture still lands.
_MAX_RAW_BODY_BYTES = _MAX_NOTE_BYTES
# Bound the term count of a search query so notes×terms×body-scan work can't be
# blown up by one request carrying hundreds of thousands of tokens.
_MAX_QUERY_TERMS = 64


def _fm_scalar(value) -> str:
    """Neutralize a value for a single-line frontmatter scalar: collapse control
    chars to space and swap double quotes for single, so it cannot break out of
    its `key: "…"` slot or inject a new line."""
    return _CONTROL_RE.sub(" ", str(value)).replace('"', "'").strip()


def _fm_target(value) -> str:
    """Neutralize an edge target: like _fm_scalar, plus strip `[` `]` so it cannot
    forge or close a `[[wikilink]]`."""
    return (_CONTROL_RE.sub(" ", str(value))
            .replace("[", "").replace("]", "").replace('"', "'").strip())


def _safe_read(path: Path) -> str:
    """Read a note, but return '' for an oversized (or unreadable) file so a huge
    planted note can't be loaded whole into memory. Never raises."""
    try:
        if path.stat().st_size > _MAX_NOTE_BYTES:
            return ""
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _cap_body(body: str) -> str:
    """Truncate a raw-capture body to _MAX_RAW_BODY_BYTES (byte-accurate, on a
    UTF-8 boundary) with a marker, so one oversized capture can't exhaust disk."""
    text = body or ""
    encoded = text.encode("utf-8")
    if len(encoded) <= _MAX_RAW_BODY_BYTES:
        return text
    return encoded[:_MAX_RAW_BODY_BYTES].decode("utf-8", "ignore") + "\n\n[truncated]"


# --- paths ---------------------------------------------------------------

def brain_dir() -> Path:
    """The brain root: $AGENT_BRAIN_DIR if set, else ~/.agent/brain. No mkdir."""
    raw = os.environ.get("AGENT_BRAIN_DIR") or _DEFAULT_DIR
    return Path(raw).expanduser()


def notes_dir() -> Path:
    return brain_dir() / "notes"


def raw_dir() -> Path:
    return brain_dir() / "raw"


def graph_dir() -> Path:
    return brain_dir() / ".graph"


def ensure_dirs() -> None:
    for d in (notes_dir(), raw_dir(), graph_dir()):
        d.mkdir(parents=True, exist_ok=True)


def slugify(text: str, fallback: str = "note") -> str:
    s = _SLUG_RE.sub("-", (text or "").strip().lower()).strip("-")
    return s or fallback


def _safe_component(value: str, kind: str) -> str:
    """Validate a value used as a single path component (fail-closed). Rejects
    path separators, '..', leading dots, and empties — prevents write_note from
    escaping the brain dir via a hostile node_id/note_type."""
    v = (value or "").strip()
    if not v or ".." in v or not _SAFE_COMPONENT_RE.match(v):
        raise ValueError(f"unsafe {kind}: {value!r} "
                         "(must match [A-Za-z0-9._-], start alnum, no '..')")
    return v


# --- frontmatter parse (line scanner; [[wikilinks]] aren't valid YAML) ----

def split_frontmatter(text: str):
    """Return (frontmatter_str | None, body_str)."""
    m = _FM_RE.match(text)
    if not m:
        return None, text
    return m.group(1), text[m.end():]


def _scalar(fm: str, key: str):
    m = re.search(rf"^{re.escape(key)}:\s*(.+?)\s*$", fm, re.MULTILINE)
    if not m:
        return None
    v = m.group(1).strip().strip('"').strip("'")
    return v or None


def _scan_indented_block(fm: str, header: str):
    """Yield (key, raw_value) for each indented line inside a `header:` block.

    A line scanner, not a YAML parser, because typed edges under `edges:` carry
    `[[wikilink]]` values that aren't valid YAML. The block ends at the first
    non-indented (dedented) line. Shared by the edges and provenance parsers so
    the two implementations can't drift.
    """
    in_block = False
    for line in fm.splitlines():
        if re.match(rf"^{re.escape(header)}:\s*$", line):
            in_block = True
            continue
        if in_block:
            if re.match(r"^\S", line):           # dedent → block ended
                return
            m = re.match(r"^\s+([A-Za-z0-9_-]+):\s*(.*)$", line)
            if m:
                yield m.group(1), m.group(2)


def _parse_provenance(fm: str) -> dict:
    """Read the indented `provenance:` block into {key: value} (scalars)."""
    return {k: v.strip().strip('"').strip("'")
            for k, v in _scan_indented_block(fm, "provenance")}


def _parse(path: Path, text: str) -> tuple[dict, list[dict]]:
    """Parse already-read note `text` at `path` → (node dict, edge list). Callers
    holding the text (e.g. search) use this to avoid re-reading the file."""
    fm, _ = split_frontmatter(text)
    try:
        rel = str(path.relative_to(brain_dir()))
    except ValueError:
        rel = str(path)
    node = {
        "id": path.stem, "type": path.parent.name, "title": None,
        "status": None, "created": None, "updated": None, "file": rel,
        "has_frontmatter": fm is not None, "edge_count": 0,
        "confidence": None, "last_verified": None, "superseded_by": None,
        "provenance": {},
    }
    edges: list[dict] = []
    if fm is None:
        return node, edges

    node["id"] = _scalar(fm, "id") or path.stem
    node["type"] = _scalar(fm, "type") or path.parent.name
    node["title"] = _scalar(fm, "title")
    node["status"] = _scalar(fm, "status")
    node["created"] = _scalar(fm, "created")
    node["updated"] = _scalar(fm, "updated")
    node["last_verified"] = _scalar(fm, "last_verified")
    conf = _scalar(fm, "confidence")
    try:
        node["confidence"] = float(conf) if conf is not None else None
    except ValueError:
        node["confidence"] = None
    sb = _scalar(fm, "superseded_by")
    if sb:
        m = _WIKILINK_RE.search(sb)
        node["superseded_by"] = m.group(1).strip() if m else sb

    for k, v in _scan_indented_block(fm, "edges"):
        if k in EDGE_TYPES:
            for tgt in _WIKILINK_RE.findall(v):
                edges.append({"source": node["id"], "target": tgt.strip(), "type": k})
    node["edge_count"] = len(edges)
    node["provenance"] = _parse_provenance(fm)
    return node, edges


def parse_note(path: Path) -> tuple[dict, list[dict]]:
    """Parse one note file → (node dict, list of edge dicts).

    node: {id, type, title, status, created, updated, file, has_frontmatter,
           edge_count, confidence, last_verified, superseded_by, provenance(dict)}
    edge: {source, target, type}
    """
    return _parse(path, _safe_read(path))


def iter_notes(root: Path | None = None):
    """Yield every note .md path under `root` (default notes/), excluding
    _templates/ and .graph/."""
    root = root or notes_dir()
    if not root.exists():
        return
    base = root.resolve()
    for p in sorted(root.rglob("*.md")):
        parts = set(p.parts)
        if "_templates" in parts or ".graph" in parts:
            continue
        # Skip anything that resolves outside root (a planted symlink escaping the
        # brain dir) or is oversized — defence in depth for a shared, AI-written store.
        try:
            p.resolve().relative_to(base)
            if p.stat().st_size > _MAX_NOTE_BYTES:
                continue
        except (OSError, ValueError):
            continue
        yield p


def get_note(node_id: str):
    """Find one note by its frontmatter id → (node, edges, body) or None.

    Iterates notes/ with the same symlink-containment and size guards as
    iter_notes — the read surface the MCP `brain_get` tool sits on, so a hostile
    id can never escape the brain dir (lookup is by parsed id, not a path built
    from the argument)."""
    target = (node_id or "").strip()
    if not target:
        return None
    for p in iter_notes():
        text = _safe_read(p)
        node, edges = _parse(p, text)
        if node["id"] == target:
            _, body = split_frontmatter(text)
            return node, edges, (body or "").strip()
    return None


def notes_by_status(status: str) -> list[dict]:
    """Every note whose frontmatter status == `status` (e.g. 'evergreen'), as node
    dicts. The selection primitive the vault-promotion bridge uses to pick which
    curated brain notes graduate to the human vault — without this module ever
    knowing the vault path (that stays personal config)."""
    want = (status or "").strip()
    if not want:
        return []
    out: list[dict] = []
    for p in iter_notes():
        node, _ = parse_note(p)
        if (node.get("status") or "") == want:
            out.append(node)
    return out


def load_graph(root: Path | None = None) -> tuple[list[dict], list[dict]]:
    """Return (nodes, edges) parsed from every note under `root` (default notes/)."""
    nodes: list[dict] = []
    edges: list[dict] = []
    for p in iter_notes(root):
        n, e = parse_note(p)
        nodes.append(n)
        edges.extend(e)
    return nodes, edges


# --- frontmatter emit ----------------------------------------------------

def _fmt_edges(edges: dict | None) -> str:
    lines = ["edges:"]
    any_edge = False
    for etype in EDGE_TYPES:
        targets = (edges or {}).get(etype)
        if not targets:
            continue
        clean = [t for t in (_fm_target(x) for x in targets) if t]
        if not clean:
            continue
        any_edge = True
        links = ", ".join(f"[[{t}]]" for t in clean)
        lines.append(f"  {etype}: {links}")
    return "\n".join(lines) if any_edge else "edges: {}"


def _fmt_provenance(prov: dict | None) -> str:
    prov = prov or {}
    lines = ["provenance:"]
    for k in _PROV_KEYS:
        lines.append(f'  {k}: "{_fm_scalar(prov.get(k, ""))}"')
    for k, v in prov.items():
        # Only emit extra keys whose NAME is a safe identifier — a hostile key
        # name could otherwise carry a newline and inject frontmatter.
        if k not in _PROV_KEYS and _PROV_KEY_RE.match(str(k)):
            lines.append(f'  {k}: "{_fm_scalar(v)}"')
    return "\n".join(lines)


def _now_iso() -> str:
    return _dt.datetime.now().strftime("%Y-%m-%d")


def _now_stamp() -> str:
    # microsecond resolution so two captures with the same ai+slug in the same
    # second don't overwrite each other.
    return _dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")


# --- writers -------------------------------------------------------------

def write_raw(ai: str, session: str, slug: str, body: str, source: str,
              title: str | None = None, generated_by: str = "brain-capture") -> Path:
    """Capture a session observation to raw/<ai>/ (QUARANTINE). Provenance kind is
    always 'generated' — a raw capture is AI-authored and untrusted until it passes
    the distill gate. Never writes into notes/. Returns the written path."""
    ensure_dirs()
    ai_safe = slugify(ai, "unknown")
    d = raw_dir() / ai_safe
    d.mkdir(parents=True, exist_ok=True)
    stamp = _now_stamp()
    slug_safe = slugify(slug)
    path = d / f"{stamp}-{slug_safe}.md"
    body = _cap_body(body)
    prov = {"ai": ai, "session": session, "generated_by": generated_by,
            "source": source, "kind": "generated"}
    fm = [
        "---",
        f"id: raw-{ai_safe}-{stamp}-{slug_safe}",
        "type: raw",
        f'title: "{_fm_scalar(title or slug or "capture")}"',
        f"created: {_now_iso()}",
        "status: raw",
        "edges: {}",
        _fmt_provenance(prov),
        "---",
    ]
    path.write_text("\n".join(fm) + "\n\n" + (body or "").rstrip() + "\n",
                    encoding="utf-8")
    return path


def write_note(node_id: str, note_type: str, title: str, body: str,
               edges: dict | None = None, provenance: dict | None = None,
               status: str = "seed", confidence: float | None = None,
               created: str | None = None, last_verified: str | None = None,
               superseded_by: str | None = None) -> Path:
    """Write a curated typed atomic note to notes/<type>/<id>.md. Used by the
    distill (ingest) and seed paths — NOT by raw session capture. Overwrites an
    existing note with the same id (idempotent update). Returns the written path.

    last_verified / superseded_by are the vault's v2 lifecycle fields; they let
    the seed path preserve them when importing an existing curated note."""
    ensure_dirs()
    node_id = _safe_component(node_id, "node_id")
    note_type = _safe_component(note_type or "concept", "note_type")
    d = notes_dir() / note_type
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"{node_id}.md"
    fm = [
        "---",
        f"id: {node_id}",
        f"type: {note_type}",
        f'title: "{_fm_scalar(title)}"',
        f"created: {_fm_scalar(created or _now_iso())}",
        f"updated: {_now_iso()}",
        f"status: {_fm_scalar(status)}",
    ]
    if confidence is not None:
        try:
            fm.append(f"confidence: {float(confidence)}")
        except (TypeError, ValueError):
            pass
    if last_verified:
        fm.append(f"last_verified: {_fm_scalar(last_verified)}")
    if superseded_by:
        fm.append(f"superseded_by: [[{_fm_target(superseded_by)}]]")
    fm.append(_fmt_edges(edges))
    fm.append(_fmt_provenance(provenance))
    fm.append("---")
    path.write_text("\n".join(fm) + "\n\n" + (body or "").rstrip() + "\n",
                    encoding="utf-8")
    return path


# --- search --------------------------------------------------------------

def search(query: str, limit: int = 20) -> list[dict]:
    """Keyword substring search over notes/ (id/title weighted, then body count).

    Returns [{id, type, title, score, file}] ranked by score, capped at `limit`.
    Empty query or no match → []. Never raises. Searches notes/ only — raw/ is
    quarantine and is not part of the shared retrieval surface.
    """
    q = (query or "").strip().lower()
    if not q:
        return []
    terms = [t for t in re.split(r"\s+", q) if t][:_MAX_QUERY_TERMS]
    results: list[dict] = []
    for p in iter_notes():
        text = _safe_read(p)
        if not text:
            continue
        node, _ = _parse(p, text)
        _, body = split_frontmatter(text)
        hay_id = (node.get("id") or "").lower()
        hay_title = (node.get("title") or "").lower()
        # body only — NOT the frontmatter, so id/title/edges/provenance strings
        # don't double-count or leak false relevance into the body score.
        hay_body = (body or "").lower()
        score = 0
        for t in terms:
            if t in hay_id:
                score += 5
            if t in hay_title:
                score += 3
            score += hay_body.count(t)
        if score > 0:
            results.append({"id": node["id"], "type": node["type"],
                            "title": node.get("title"), "score": score,
                            "file": node["file"]})
    results.sort(key=lambda r: -r["score"])
    return results[:limit]


# --- minimal CLI ---------------------------------------------------------

def _cli(argv: list[str]) -> int:
    import json
    if not argv:
        print(__doc__)
        return 1
    cmd = argv[0]
    if cmd == "search" and len(argv) >= 2:
        for r in search(" ".join(argv[1:])):
            print(f"{r['score']:4d}  {r['id']}  ({r['title']})")
        return 0
    if cmd == "paths":
        print(json.dumps({"brain": str(brain_dir()), "notes": str(notes_dir()),
                          "raw": str(raw_dir()), "graph": str(graph_dir())}, indent=2))
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    import sys
    raise SystemExit(_cli(sys.argv[1:]))
