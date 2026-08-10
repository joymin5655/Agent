#!/usr/bin/env python3
"""Materialize + traverse the agent-brain typed-edge graph.

Domain-neutral port of the reference vault's extract_graph.py + query.py: reads
notes/ via core/brain/store.py and writes .graph/{nodes,edges}.jsonl under the
brain dir ($AGENT_BRAIN_DIR or ~/.agent/brain). The LLM does semantic answering;
this does exact graph walks — neighborhoods, shortest typed paths, hubs — that
keyword search misses.

Usage:
  python3 graph.py extract                       # materialize .graph/*.jsonl
  python3 graph.py neighbors <id> [--depth N]    # reachable within N hops (default 2)
  python3 graph.py path <from> <to>              # shortest typed path (undirected)
  python3 graph.py incoming <id>                 # who points to id
  python3 graph.py hubs [--top N]                # top nodes by total degree
  python3 graph.py edge <edge-type>              # all edges of a type
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict, deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import store  # noqa: E402


def extract() -> int:
    nodes, edges = store.load_graph()
    out = store.graph_dir()
    out.mkdir(parents=True, exist_ok=True)
    with (out / "nodes.jsonl").open("w", encoding="utf-8") as f:
        for n in nodes:
            f.write(json.dumps(n, ensure_ascii=False) + "\n")
    with (out / "edges.jsonl").open("w", encoding="utf-8") as f:
        for e in edges:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    ids = {n["id"] for n in nodes}
    dangling = sum(1 for e in edges if e["target"] not in ids)
    print(f"nodes: {len(nodes)}  edges: {len(edges)}  dangling: {dangling}")
    print(f"wrote {out}/nodes.jsonl, {out}/edges.jsonl")
    return 0


def build():
    nodes, edges = store.load_graph()
    byid = {n["id"]: n for n in nodes}
    out = defaultdict(list)   # source -> [(type, target)]
    inc = defaultdict(list)   # target -> [(type, source)]
    for e in edges:
        out[e["source"]].append((e["type"], e["target"]))
        inc[e["target"]].append((e["type"], e["source"]))
    return byid, out, inc, edges


def _title(byid, i):
    return byid[i]["title"] if i in byid and byid[i].get("title") else i


def title(byid, i):
    """Public display title for a node id (falls back to the id). Cross-module
    callers (e.g. the MCP server) use this instead of the module-private _title."""
    return _title(byid, i)


def _flag_int(args, flag, default):
    """Parse `--flag N`; return default if the flag is absent, trailing, or the
    value is non-numeric — never crash on bad CLI input."""
    if flag in args:
        i = args.index(flag) + 1
        if i < len(args):
            try:
                return int(args[i])
            except ValueError:
                pass
    return default


def neighbors(out, inc, start, depth):
    """Every typed edge within `depth` hops of `start`. Returns (edges, reached)
    where each edge is a dict {src, type, dst, hop, discovered} rendered in TRUE
    direction (an incoming edge stays src --type--> cur, never reversed),
    `discovered` is the node the edge reaches from the frontier (for title
    lookup), and `hop` is the frontier distance at which the edge was crossed.
    Ordered by hop.

    Emits the full set of in-range edges — parallel edges (two types between the
    same pair) and same-hop multi-paths included — NOT just a BFS spanning tree,
    which would hide a co-existing edge (e.g. a `contradicts` alongside a
    `supports`) from the consumer. An edge is deduped by (src, type, dst) so the
    same edge seen from both endpoints is emitted once. The single source of
    truth for the CLI and the MCP brain_neighbors tool, so the two can't drift."""
    seen = {start: 0}
    q = deque([start])
    used = []
    emitted = set()   # (src, type, dst) — one edge, whichever endpoint reaches it first

    def emit(src, t, dst, hop, discovered):
        key = (src, t, dst)
        if key not in emitted:
            emitted.add(key)
            used.append({"src": src, "type": t, "dst": dst,
                         "hop": hop, "discovered": discovered})

    while q:
        cur = q.popleft()
        if seen[cur] >= depth:       # frontier node: its edges are out of range
            continue
        hop = seen[cur] + 1
        for t, tgt in out.get(cur, []):          # cur --t--> tgt
            if tgt not in seen:
                seen[tgt] = hop
                q.append(tgt)
            emit(cur, t, tgt, hop, tgt)
        for t, src in inc.get(cur, []):          # src --t--> cur (render TRUE dir)
            if src not in seen:
                seen[src] = hop
                q.append(src)
            emit(src, t, cur, hop, src)
    used.sort(key=lambda e: e["hop"])
    return used, len(seen) - 1


def stats():
    """Aggregate the materialized graph: note/edge counts, per-type breakdown,
    and dangling-edge count (edges whose target has no note). Backs brain_stats."""
    nodes, edges = store.load_graph()
    ids = {n["id"] for n in nodes}
    by_type: dict[str, int] = {}
    for n in nodes:
        by_type[n["type"]] = by_type.get(n["type"], 0) + 1
    dangling = sum(1 for e in edges if e["target"] not in ids)
    return {"notes": len(nodes), "edges": len(edges),
            "by_type": by_type, "dangling": dangling}


def cmd_neighbors(byid, out, inc, args) -> int:
    start = args[0]
    depth = _flag_int(args, "--depth", 2)
    if start not in byid:
        print(f"unknown id: {start}")
        return 1
    used, reached = neighbors(out, inc, start, depth)
    print(f"# neighbors of {start} (<={depth} hops): {reached}\n")
    for e in used:
        print(f"  {'.' * e['hop']} {e['src']} --{e['type']}--> {e['dst']}"
              f"  ({_title(byid, e['discovered'])})")
    return 0


def cmd_path(byid, out, inc, args) -> int:
    a, b = args[0], args[1]
    if a not in byid or b not in byid:
        print("unknown id")
        return 1
    adj = defaultdict(list)
    for src, lst in out.items():
        for t, tgt in lst:
            adj[src].append((t, tgt))
            adj[tgt].append((f"{t}-inv", src))   # undirected for pathfinding
    prev = {a: None}
    q = deque([a])
    while q:
        cur = q.popleft()
        if cur == b:
            break
        for t, tgt in adj[cur]:
            if tgt not in prev:
                prev[tgt] = (cur, t)
                q.append(tgt)
    if b not in prev:
        print(f"no path {a} -> {b}")
        return 1
    chain = []
    cur = b
    while prev[cur] is not None:
        p, t = prev[cur]
        chain.append(f"{p} --{t}--> {cur}")
        cur = p
    print(f"# shortest path {a} -> {b} ({len(chain)} hops)\n")
    for step in reversed(chain):
        print("  " + step)
    return 0


def cmd_incoming(byid, out, inc, args) -> int:
    i = args[0]
    if i not in byid:
        print(f"unknown id: {i}")
        return 1
    items = inc.get(i, [])
    print(f"# {len(items)} nodes point to {i} ({_title(byid, i)})\n")
    for t, src in sorted(items):
        print(f"  {src} --{t}--> {i}  ({_title(byid, src)})")
    return 0


def cmd_hubs(byid, out, inc, args) -> int:
    top = _flag_int(args, "--top", 15)
    deg = {i: len(out.get(i, [])) + len(inc.get(i, [])) for i in byid}
    print(f"# top {top} hubs by degree\n")
    for i, d in sorted(deg.items(), key=lambda x: -x[1])[:top]:
        print(f"  {d:3d}  {i}  ({len(inc.get(i, []))} in / {len(out.get(i, []))} out)"
              f"  {_title(byid, i)}")
    return 0


def cmd_edge(byid, out, inc, args, edges) -> int:
    et = args[0]
    hits = [e for e in edges if e["type"] == et]
    print(f"# {len(hits)} '{et}' edges\n")
    for e in hits:
        print(f"  {e['source']} --{et}--> {e['target']}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "extract":
        return extract()
    byid, out, inc, edges = build()
    if cmd == "neighbors" and args:
        return cmd_neighbors(byid, out, inc, args)
    if cmd == "path" and len(args) >= 2:
        return cmd_path(byid, out, inc, args)
    if cmd == "incoming" and args:
        return cmd_incoming(byid, out, inc, args)
    if cmd == "hubs":
        return cmd_hubs(byid, out, inc, args)
    if cmd == "edge" and args:
        if args[0] not in store.EDGE_TYPES:
            print(f"edge type must be one of: {', '.join(store.EDGE_TYPES)}")
            return 1
        return cmd_edge(byid, out, inc, args, edges)
    print(__doc__)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
