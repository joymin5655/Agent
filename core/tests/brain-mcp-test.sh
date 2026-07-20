#!/usr/bin/env bash
# brain-mcp-test.sh — verify core/brain/brain-mcp.py: the headless stdio MCP
# server. Drives a real JSON-RPC handshake (initialize → tools/list → tools/call)
# against a subprocess and asserts each tool, plus the write-policy invariant that
# brain_capture writes raw/ ONLY and can never create a curated note.
#
# Uses a `mktemp -d` fixture as AGENT_BRAIN_DIR — never the real ~/.agent/brain.
# Stdlib only; no MCP client dependency. Usage:
#   bash core/tests/brain-mcp-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
BRAIN_DIR="$(mktemp -d)"
export AGENT_BRAIN_DIR="$BRAIN_DIR"

cleanup() { [[ -n "${BRAIN_DIR:-}" && -d "$BRAIN_DIR" ]] && rm -rf "$BRAIN_DIR"; }
trap cleanup EXIT

# One Python driver: seed a tiny graph, run a single stdio handshake, then assert
# every tool. Prints the same "  ok/FAIL [name]" report the other batteries use,
# and exits non-zero if any check fails.
python3 - <<'PY'
import json, os, subprocess, sys

repo = os.environ["REPO_ROOT"]
sys.path.insert(0, repo + "/core/brain")
import store

# --- seed: concept-brain --supports--> concept-memory --------------------
prov = {"ai": "claude", "session": "seed", "generated_by": "brain-seed",
        "source": "test", "kind": "user"}
store.write_note(node_id="concept-brain", note_type="concept", title="Agent brain",
                 body="a shared cross-AI knowledge store for sessions",
                 edges={"supports": ["concept-memory"]}, provenance=prov)
store.write_note(node_id="concept-memory", note_type="concept", title="Memory",
                 body="durable notes that outlive one session", edges={},
                 provenance=prov)
notes_before = len(list(store.notes_dir().rglob("*.md")))

# --- drive one stdio handshake, collect responses keyed by id ------------
reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "test", "version": "0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "brain_search", "arguments": {"query": "shared"}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
     "params": {"name": "brain_get", "arguments": {"id": "concept-brain"}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
     "params": {"name": "brain_neighbors", "arguments": {"id": "concept-brain", "depth": 1}}},
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
     "params": {"name": "brain_stats", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
     "params": {"name": "brain_capture",
                "arguments": {"ai": "codex", "session": "s1", "slug": "observed x",
                              "body": "observed something", "source": "mcp"}}},
    {"jsonrpc": "2.0", "id": 8, "method": "bogus/method"},
    # --- robustness probes: one bad request must never kill the loop ---
    {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["x"]},        # non-object params
    {"jsonrpc": "2.0", "id": 10, "method": "initialize", "params": "bad"},        # non-object params
    {"jsonrpc": "2.0", "id": 11, "method": "tools/call",
     "params": {"name": ["x"], "arguments": {}}},                                 # non-string tool name
    {"jsonrpc": "2.0", "id": 12, "method": "tools/call",
     "params": {"name": "brain_capture", "arguments": {}}},                       # missing required fields
    {"jsonrpc": "2.0", "method": "ping"},                                         # NOTIFICATION (no id) — no reply
    {"jsonrpc": "2.0", "id": 13, "method": "ping"},                               # loop-alive probe (must answer)
]
lines = [json.dumps(r) for r in reqs]
# splice a raw invalid-JSON line just before the loop-alive probe so the -32700
# parse-error path is exercised mid-stream and we prove the loop survives it.
lines.insert(len(lines) - 1, "{ this is not valid json")
inp = "\n".join(lines) + "\n"
proc = subprocess.run([sys.executable, repo + "/core/brain/brain-mcp.py"],
                      input=inp, capture_output=True, text=True, timeout=30)
resp = {}
null_id = []   # responses with id null (parse errors); a leaked notification reply lands here too
for line in proc.stdout.splitlines():
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if obj.get("id") is not None:
        resp[obj["id"]] = obj
    else:
        null_id.append(obj)


def tool_payload(rid):
    """Decode the JSON a tool call returned in its text content block."""
    r = resp[rid]["result"]
    assert not r.get("isError"), r
    return json.loads(r["content"][0]["text"])


PASS = FAIL = 0
def check(name, cond, ctx=""):
    global PASS, FAIL
    if cond:
        print(f"  ok   [{name}]"); PASS += 1
    else:
        print(f"  FAIL [{name}] {ctx}"); FAIL += 1

print("=== (a) initialize returns serverInfo + protocolVersion ===")
init = resp[1]["result"]
check("initialize", init["serverInfo"]["name"] == "agent-brain"
      and bool(init.get("protocolVersion")), init)

print("=== (b) tools/list exposes the 5 brain tools ===")
names = {t["name"] for t in resp[2]["result"]["tools"]}
want = {"brain_search", "brain_get", "brain_neighbors", "brain_stats", "brain_capture"}
check("tools-list", names == want, names)

print("=== (c) brain_search finds the seeded note by a body term ===")
s = tool_payload(3)
check("search", "concept-brain" in [h["id"] for h in s["results"]], s)

print("=== (d) brain_get returns frontmatter + edges + body ===")
g = tool_payload(4)
check("get", g["found"] and g["node"]["title"] == "Agent brain"
      and any(e["target"] == "concept-memory" for e in g["edges"])
      and "cross-AI" in g["body"], g)

print("=== (e) brain_neighbors walks the typed edge ===")
n = tool_payload(5)
check("neighbors", n["found"] and any(
    e["src"] == "concept-brain" and e["dst"] == "concept-memory"
    and e["type"] == "supports" for e in n["neighbors"]), n)

print("=== (f) brain_stats counts notes and edges ===")
st = tool_payload(6)
check("stats", st["notes"] == 2 and st["edges"] == 1, st)

print("=== (g) brain_capture writes raw/ ONLY, never notes/ (write policy) ===")
cap = tool_payload(7)
raw_files = list(store.raw_dir().rglob("*.md"))
notes_after = len(list(store.notes_dir().rglob("*.md")))
check("capture-raw-quarantine",
      cap["quarantine"] is True and cap["kind"] == "generated"
      and len(raw_files) == 1 and store.raw_dir() in raw_files[0].parents
      and notes_after == notes_before,
      f"cap={cap} raw={len(raw_files)} notes {notes_before}->{notes_after}")

print("=== (h) unknown method → JSON-RPC error, server stays alive ===")
check("unknown-method", resp[8].get("error", {}).get("code") == -32601, resp.get(8))

print("=== (i) non-object params → -32602, not a crash ===")
check("params-nonobject-array", resp.get(9, {}).get("error", {}).get("code") == -32602, resp.get(9))
check("params-nonobject-string", resp.get(10, {}).get("error", {}).get("code") == -32602, resp.get(10))

print("=== (j) non-string tool name → clean isError (not TypeError crash) ===")
check("name-nonstring", resp.get(11, {}).get("result", {}).get("isError") is True, resp.get(11))

print("=== (k) brain_capture missing required fields → isError (schema enforced) ===")
check("capture-missing-required", resp.get(12, {}).get("result", {}).get("isError") is True, resp.get(12))

print("=== (l) invalid JSON → exactly one -32700 AND notification got no reply ===")
check("parse-error-and-notif-suppressed",
      len(null_id) == 1 and null_id[0].get("error", {}).get("code") == -32700,
      f"null_id responses={null_id}")

print("=== (m) loop survived every hostile request (final ping answered) ===")
check("loop-alive", resp.get(13, {}).get("result") == {}, resp.get(13))

print()
print(f"=== Server: {PASS} passed, {FAIL} failed ===")
sys.exit(1 if FAIL else 0)
PY
SERVER_RC=$?

# --- registration parity: all 3 runtime templates register the same server ---
RPASS=0
RFAIL=0
rok() { echo "  ok   [$1]"; RPASS=$((RPASS + 1)); }
rno() { echo "  FAIL [$1] $2"; RFAIL=$((RFAIL + 1)); }
FAKE_ROOT="/opt/agent-fake"
render() { sed "s|{{FRAMEWORK_ROOT}}|$FAKE_ROOT|g" "$1"; }
EXPECT_ARG="$FAKE_ROOT/core/brain/brain-mcp.py"
EXPECT_CMD="python3"   # all three runtimes must launch the server via this interpreter

echo "=== (n) codex template: [mcp_servers.brain] table launches python3 brain-mcp.py ==="
CODEX_T="$REPO_ROOT/adapters/codex/codex-config.toml.template"
# Slice to the [mcp_servers.brain] table body ONLY, then verify command + arg
# path INSIDE it — so a `command = "python3"` belonging to some other
# [mcp_servers.*] server can't satisfy brain's check (section-scoped parity,
# matching what (o)/(p) get for free by parsing the brain object). Quote class
# ["'] accepts either TOML string style. Header regex tolerates whitespace.
CODEX_BRAIN="$(render "$CODEX_T" | awk '
  /^\[[[:space:]]*mcp_servers\.brain[[:space:]]*\]/ { f=1; next }
  /^\[/ { f=0 }
  f')"
if [[ -n "$CODEX_BRAIN" ]] \
   && grep -qE "command[[:space:]]*=[[:space:]]*[\"']$EXPECT_CMD[\"']" <<<"$CODEX_BRAIN" \
   && grep -qF "$EXPECT_ARG" <<<"$CODEX_BRAIN"; then
  rok "codex-mcp"
else
  rno "codex-mcp" "no [mcp_servers.brain] table launching \"$EXPECT_CMD\" -> brain-mcp.py"
fi

echo "=== (o) gemini template: valid JSON, mcpServers.brain -> python3 brain-mcp.py ==="
GEMINI_T="$REPO_ROOT/adapters/gemini/gemini-settings.json.template"
if render "$GEMINI_T" | EXPECT="$EXPECT_ARG" EXPECT_CMD="$EXPECT_CMD" python3 -c '
import json, os, sys
b = json.load(sys.stdin)["mcpServers"]["brain"]
sys.exit(0 if b.get("command") == os.environ["EXPECT_CMD"]
         and os.environ["EXPECT"] in b["args"] else 1)' 2>/dev/null; then
  rok "gemini-mcp"
else
  rno "gemini-mcp" "invalid JSON or mcpServers.brain not (command=\"$EXPECT_CMD\", args->brain-mcp.py)"
fi

echo "=== (p) claude .mcp.json template: valid JSON, mcpServers.brain -> python3 brain-mcp.py ==="
CLAUDE_T="$REPO_ROOT/adapters/claude-code/mcp.json.template"
if render "$CLAUDE_T" | EXPECT="$EXPECT_ARG" EXPECT_CMD="$EXPECT_CMD" python3 -c '
import json, os, sys
b = json.load(sys.stdin)["mcpServers"]["brain"]
sys.exit(0 if b.get("command") == os.environ["EXPECT_CMD"]
         and os.environ["EXPECT"] in b["args"] else 1)' 2>/dev/null; then
  rok "claude-mcp"
else
  rno "claude-mcp" "invalid JSON or mcpServers.brain not (command=\"$EXPECT_CMD\", args->brain-mcp.py)"
fi

echo
echo "=== Registration: $RPASS passed, $RFAIL failed ==="
[[ "$SERVER_RC" -eq 0 && "$RFAIL" -eq 0 ]]
