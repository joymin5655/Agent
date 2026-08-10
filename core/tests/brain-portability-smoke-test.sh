#!/usr/bin/env bash
# brain-portability-smoke-test.sh — the install→query end-to-end the other
# batteries leave open. It proves the portable-harness promise for the brain at
# RUNTIME: on a machine that has never seen the harness (a scratch $HOME) and an
# EMPTY brain (no AGENT_BRAIN_DIR, so the default ~/.agent/brain does not yet
# exist), the EXACT command the install registers boots, resolves its brain dir
# under that fresh home, and serves graceful-empty results instead of crashing.
#
# Division of labour (why this is not a duplicate):
#   - clean-install (ci.yml)  proves setup.sh WRITES correctly-templated configs
#                             ({{FRAMEWORK_ROOT}} expanded) — the install side.
#   - brain-mcp-test.sh       drives the server by a HARDCODED path after SEEDING
#                             notes — full tool + robustness + template-parity.
#   - THIS test               takes the shipped registration TEMPLATE, renders it
#                             the same way the harness does, and launches THAT
#                             command against an EMPTY brain under a fresh home —
#                             the runtime side of "install once, use everywhere".
#
# Stdlib only; no claude/codex/gemini CLI, no MCP client dependency. Usage:
#   bash core/tests/brain-portability-smoke-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# A scratch home = a machine that has never seen the harness. The brain default
# (~/.agent/brain) lands under HERE and does not exist until first write.
SCRATCH_HOME="$(mktemp -d)"
export SCRATCH_HOME

cleanup() { [[ -n "${SCRATCH_HOME:-}" && -d "$SCRATCH_HOME" ]] && rm -rf "$SCRATCH_HOME"; }
trap cleanup EXIT

# Deliberately NOT set: AGENT_BRAIN_DIR. The server must fall back to
# $HOME/.agent/brain, exercising the home-relative default on an unseen machine.
unset AGENT_BRAIN_DIR

python3 - <<'PY'
import json, os, re, subprocess, sys
from pathlib import Path

repo = os.environ["REPO_ROOT"]
scratch_home = os.environ["SCRATCH_HOME"]

PASS = FAIL = 0
def check(name, cond, ctx=""):
    global PASS, FAIL
    if cond:
        print(f"  ok   [{name}]"); PASS += 1
    else:
        print(f"  FAIL [{name}] {ctx}"); FAIL += 1


# --- render the SHIPPED registration templates the way the harness does -------
# setup.sh substitutes {{FRAMEWORK_ROOT}} with the checkout path via sed; we do
# the identical substitution with the REAL repo root, then launch what it yields.
def render(rel):
    return Path(repo, rel).read_text().replace("{{FRAMEWORK_ROOT}}", repo)

claude_reg = json.loads(render("adapters/claude-code/mcp.json.template"))
launch = claude_reg["mcpServers"]["brain"]           # {"command": ..., "args": [...]}
cmd = [launch["command"], *launch["args"]]

print("=== (a) all three runtime templates render to the SAME launch command ===")
# claude + gemini are JSON — parse fully into [command, *args] and require an
# EXACT match with what we launch. codex is TOML (no stdlib parser on 3.9), so
# assert its rendered text contains BOTH the same interpreter (command = "<cmd>")
# and the same server path. This is a format-TOLERANT containment check: it
# catches a wrong codex interpreter or path, yet does not false-red on valid TOML
# reformatting (multi-line array, whitespace/comment on the table header) the way
# a hand-rolled line scanner would. brain-mcp-test covers the section header.
gem = json.loads(render("adapters/gemini/gemini-settings.json.template"))
gem_cmd = [gem["mcpServers"]["brain"]["command"], *gem["mcpServers"]["brain"]["args"]]
codex_txt = render("adapters/codex/codex-config.toml.template")
codex_cmd_ok = bool(re.search(r'command\s*=\s*"' + re.escape(launch["command"]) + r'"', codex_txt))
codex_path_ok = launch["args"][0] in codex_txt
check("template-parity",
      gem_cmd == cmd and codex_cmd_ok and codex_path_ok,
      f"claude={cmd} gemini={gem_cmd} codex_cmd_ok={codex_cmd_ok} codex_path_ok={codex_path_ok}")

print("=== (b) the registered command exists and is a readable file ===")
server_path = Path(launch["args"][0])
check("server-file-exists", server_path.is_file(), server_path)

# --- launch THAT command against a fresh home + empty brain ------------------
env = dict(os.environ)
env["HOME"] = scratch_home
env.pop("AGENT_BRAIN_DIR", None)   # force the ~/.agent/brain default under scratch home

reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "smoke", "version": "0"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    # empty-brain reads must all answer gracefully, never crash the loop:
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
     "params": {"name": "brain_stats", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
     "params": {"name": "brain_search", "arguments": {"query": "anything at all"}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
     "params": {"name": "brain_get", "arguments": {"id": "note-that-does-not-exist"}}},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
     "params": {"name": "brain_neighbors", "arguments": {"id": "note-that-does-not-exist", "depth": 1}}},
    # first write on a never-seen machine must create the dir lazily (raw/ only):
    {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
     "params": {"name": "brain_capture",
                "arguments": {"ai": "claude", "session": "smoke", "slug": "first ever note",
                              "body": "the very first capture on a fresh machine", "source": "smoke"}}},
    # re-read after the write: the note is quarantined in raw/, curated count still 0:
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
     "params": {"name": "brain_stats", "arguments": {}}},
    {"jsonrpc": "2.0", "id": 8, "method": "ping"},   # loop-alive after everything
]
inp = "\n".join(json.dumps(r) for r in reqs) + "\n"
proc = subprocess.run(cmd, input=inp, capture_output=True, text=True,
                      timeout=30, env=env)

resp = {}
for line in proc.stdout.splitlines():
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if obj.get("id") is not None:
        resp[obj["id"]] = obj

def payload(rid):
    r = resp[rid]["result"]
    # Explicit raise (not a bare `assert`, which python -O / PYTHONOPTIMIZE=1
    # strips) so a tool that errored surfaces its own payload legibly instead of
    # falling through to a misleading json.loads() crash on the error string.
    if r.get("isError"):
        raise RuntimeError(f"tool call {rid} returned isError: {r}")
    return json.loads(r["content"][0]["text"])

print("=== (c) the REGISTERED command boots (initialize → agent-brain) ===")
booted = 1 in resp and resp[1].get("result", {}).get("serverInfo", {}).get("name") == "agent-brain"
check("registered-command-boots", booted,
      f"rc={proc.returncode} stderr={proc.stderr[:400]!r}")

if not booted:
    # nothing downstream is meaningful if it never started
    print()
    print(f"=== Portability smoke: {PASS} passed, {FAIL} failed ===")
    sys.exit(1)

print("=== (d) empty brain: stats report 0 notes / 0 edges (no crash) ===")
st0 = payload(2)
check("empty-stats", st0.get("notes") == 0 and st0.get("edges") == 0, st0)

print("=== (e) empty brain: search returns [] rather than erroring ===")
s = payload(3)
check("empty-search", s.get("results") == [], s)

print("=== (f) empty brain: get(missing) → found False, not an exception ===")
g = payload(4)
check("empty-get", g.get("found") is False, g)

print("=== (g) empty brain: neighbors(missing) → found False, graceful ===")
n = payload(5)
check("empty-neighbors", n.get("found") is False, n)

print("=== (h) first-ever capture on a fresh home succeeds, quarantined ===")
cap = payload(6)
check("fresh-capture", cap.get("quarantine") is True and cap.get("kind") == "generated", cap)

print("=== (i) the default brain dir was created UNDER the scratch home ===")
brain = Path(scratch_home, ".agent", "brain")
raw_md = list((brain / "raw").rglob("*.md")) if (brain / "raw").exists() else []
notes_md = list((brain / "notes").rglob("*.md")) if (brain / "notes").exists() else []
check("home-relative-default-dir",
      brain.exists() and len(raw_md) == 1 and len(notes_md) == 0,
      f"brain={brain} exists={brain.exists()} raw={len(raw_md)} notes={len(notes_md)}")

print("=== (j) write policy holds on a fresh home: capture made 0 curated notes ===")
st1 = payload(7)
check("fresh-write-policy", st1.get("notes") == 0, st1)

print("=== (k) loop survived the whole empty→write→read cycle (final ping) ===")
check("loop-alive", resp.get(8, {}).get("result") == {}, resp.get(8))

print()
print(f"=== Portability smoke: {PASS} passed, {FAIL} failed ===")
sys.exit(1 if FAIL else 0)
PY
