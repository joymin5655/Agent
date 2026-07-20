#!/usr/bin/env python3
"""brain-mcp.py — headless stdio MCP server for the cross-AI agent brain.

A dependency-free Model Context Protocol server (newline-delimited JSON-RPC 2.0
over stdio) that exposes the brain to Claude / Codex / Gemini identically. It is
the shared retrieval surface: the same `brain_search` from a Claude session and a
Codex session hits the same notes/ and returns the same result.

Tools:
  brain_search    keyword search over notes/            (read)
  brain_get       fetch one note by id (frontmatter+body) (read)
  brain_neighbors typed-edge BFS neighborhood            (read)
  brain_stats     note/edge/type counts                  (read)
  brain_capture   append a session observation to raw/   (WRITE — quarantine only)

Write policy (the hybrid invariant, enforced here): the ONLY write tool is
brain_capture, and it calls store.write_raw — which writes to raw/ with
provenance kind=generated and can never touch notes/ or the human-curated vault.
Promotion raw/ → notes/ is a separate, gated distill (/brain-ingest), never an
MCP call. So an agent (or an injected instruction inside a captured observation)
cannot forge a trusted note through this server.

Transport: reads one JSON-RPC message per line from stdin, writes one response
line per request to stdout (notifications get no response). Runs until EOF.
Never crashes the loop: a parse error → JSON-RPC -32700; a tool exception →
an isError tool result. Stdlib only; Python 3.9+.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import graph  # noqa: E402
import store  # noqa: E402

SERVER_NAME = "agent-brain"
SERVER_VERSION = "0.1.0"
# Fallback protocol version if the client doesn't send one; otherwise we echo the
# client's requested version (accept-what-you-can-serve keeps us compatible with
# a range of MCP clients without tracking a hardcoded latest).
PROTOCOL_VERSION = "2025-06-18"

_MAX_LIMIT = 100
_MAX_DEPTH = 6


# --- helpers -------------------------------------------------------------

def _bounded_int(value, default: int, lo: int, hi: int) -> int:
    """Coerce an argument to an int clamped to [lo, hi]; bad input → default.
    Bounds keep a hostile limit/depth from turning a query into a DoS."""
    try:
        n = int(value)
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, n))


def _require_id(args: dict) -> str:
    node_id = str(args.get("id", "")).strip()
    if not node_id:
        raise ValueError("id is required")
    return node_id


def _rel_to_brain(p: Path) -> str:
    try:
        return str(p.relative_to(store.brain_dir()))
    except ValueError:
        return str(p)


# --- tool implementations ------------------------------------------------

def tool_search(args: dict) -> dict:
    query = str(args.get("query", ""))
    limit = _bounded_int(args.get("limit"), 20, 1, _MAX_LIMIT)
    hits = store.search(query, limit=limit)
    return {"query": query, "count": len(hits), "results": hits}


def tool_get(args: dict) -> dict:
    node_id = _require_id(args)
    found = store.get_note(node_id)
    if found is None:
        return {"id": node_id, "found": False}
    node, edges, body = found
    return {"id": node_id, "found": True, "node": node, "edges": edges, "body": body}


def tool_neighbors(args: dict) -> dict:
    node_id = _require_id(args)
    depth = _bounded_int(args.get("depth"), 2, 1, _MAX_DEPTH)
    byid, out, inc, _ = graph.build()
    if node_id not in byid:
        return {"id": node_id, "found": False, "neighbors": []}
    used, reached = graph.neighbors(out, inc, node_id, depth)
    return {
        "id": node_id, "found": True, "depth": depth, "reached": reached,
        "neighbors": [
            {"src": e["src"], "type": e["type"], "dst": e["dst"], "hop": e["hop"],
             "title": graph.title(byid, e["discovered"])}
            for e in used
        ],
    }


def tool_stats(args: dict) -> dict:
    return graph.stats()


def tool_capture(args: dict) -> dict:
    """The ONLY write path. Delegates to store.write_raw → raw/ quarantine with
    provenance kind=generated. Never writes notes/ or the vault.

    Enforces the inputSchema's declared required fields server-side so the
    declared contract and the runtime behavior agree — a non-validating client
    can't smuggle an empty, unattributed capture through the defaults. The raise
    is caught by _call_tool and degrades to a clean isError."""
    missing = [k for k in ("ai", "session", "slug", "body")
               if not str(args.get(k, "")).strip()]
    if missing:
        raise ValueError(f"missing required field(s): {', '.join(missing)}")
    p = store.write_raw(
        ai=str(args["ai"]),
        session=str(args["session"]),
        slug=str(args["slug"]),
        body=str(args["body"]),
        source=str(args.get("source", "mcp:brain_capture")),
        title=(str(args["title"]) if args.get("title") else None),
        generated_by="brain-capture",
    )
    return {"captured": _rel_to_brain(p), "kind": "generated", "quarantine": True}


TOOLS = [
    {
        "name": "brain_search",
        "description": "Keyword search the shared agent brain's curated notes. "
                       "Returns notes ranked by relevance (id/title weighted, then "
                       "body frequency). Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "search terms"},
                "limit": {"type": "integer", "description": "max results (1-100)",
                          "default": 20},
            },
            "required": ["query"],
        },
    },
    {
        "name": "brain_get",
        "description": "Fetch one brain note by its id — frontmatter fields, typed "
                       "edges, and body. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "note id"}},
            "required": ["id"],
        },
    },
    {
        "name": "brain_neighbors",
        "description": "All typed edges within N hops of a note (default 2), each "
                       "in true direction — parallel and same-hop edges included, "
                       "not just a spanning tree. Read-only.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "note id"},
                "depth": {"type": "integer", "description": "hops (1-6)",
                          "default": 2},
            },
            "required": ["id"],
        },
    },
    {
        "name": "brain_stats",
        "description": "Counts for the brain: total notes, edges, per-type "
                       "breakdown, and dangling edges. Read-only.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "brain_capture",
        "description": "Append a session observation to the brain's raw/ quarantine "
                       "(provenance kind=generated). This is the ONLY write tool and "
                       "it CANNOT create a curated note — promotion to notes/ is a "
                       "separate gated distill, never this call.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ai": {"type": "string", "description": "claude | codex | gemini"},
                "session": {"type": "string", "description": "session id"},
                "slug": {"type": "string", "description": "short slug for the filename"},
                "body": {"type": "string", "description": "the observation text"},
                "source": {"type": "string", "description": "semantic origin"},
                "title": {"type": "string", "description": "optional title"},
            },
            "required": ["ai", "session", "slug", "body"],
        },
    },
]

TOOL_FUNCS = {
    "brain_search": tool_search,
    "brain_get": tool_get,
    "brain_neighbors": tool_neighbors,
    "brain_stats": tool_stats,
    "brain_capture": tool_capture,
}


# --- JSON-RPC plumbing ---------------------------------------------------

def _result(rid, result) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _error(rid, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def _initialize(params: dict) -> dict:
    client_ver = params.get("protocolVersion")
    version = client_ver if isinstance(client_ver, str) and client_ver else PROTOCOL_VERSION
    return {
        "protocolVersion": version,
        "capabilities": {"tools": {}},
        "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
    }


def _call_tool(params: dict) -> dict:
    name = params.get("name")
    if not isinstance(name, str):
        return {"content": [{"type": "text", "text": "tool name must be a string"}],
                "isError": True}
    args = params.get("arguments") or {}
    if not isinstance(args, dict):
        return {"content": [{"type": "text", "text": "arguments must be an object"}],
                "isError": True}
    fn = TOOL_FUNCS.get(name)
    if fn is None:
        return {"content": [{"type": "text", "text": f"unknown tool: {name}"}],
                "isError": True}
    try:
        data = fn(args)
    except Exception as exc:  # tool errors are reported in-band, never crash the loop
        return {"content": [{"type": "text", "text": f"error: {exc}"}], "isError": True}
    return {"content": [{"type": "text",
                         "text": json.dumps(data, ensure_ascii=False, indent=2)}]}


def handle(req: dict):
    """Dispatch one JSON-RPC request. Returns a response dict, or None for a
    notification (no `id`) — a notification MUST NOT get a reply, so it is
    dropped before any dispatch, whatever its method.

    `params`, when present, must be an object; a non-object `params` (array,
    string, number) is rejected with -32602 rather than being handed to a
    handler that would call `.get()` on it and crash the loop."""
    if not isinstance(req, dict) or req.get("jsonrpc") != "2.0":
        return _error(None, -32600, "invalid request")
    if "id" not in req:
        return None  # notification — never reply
    rid = req.get("id")
    method = req.get("method")
    params = req.get("params")
    if params is None:
        params = {}
    if not isinstance(params, dict):
        return _error(rid, -32602, "invalid params: expected an object")

    if method == "initialize":
        return _result(rid, _initialize(params))
    if method == "tools/list":
        return _result(rid, {"tools": TOOLS})
    if method == "tools/call":
        return _result(rid, _call_tool(params))
    if method == "ping":
        return _result(rid, {})
    return _error(rid, -32601, f"method not found: {method}")


def _write(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            _write(_error(None, -32700, "parse error"))
            continue
        try:
            resp = handle(req)
        except Exception:  # last-resort guard: one bad request must never kill the loop
            rid = req.get("id") if isinstance(req, dict) else None
            resp = _error(rid, -32603, "internal error")
        if resp is not None:
            _write(resp)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
