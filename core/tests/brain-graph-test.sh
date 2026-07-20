#!/usr/bin/env bash
# brain-graph-test.sh — verify core/brain/graph.py: materialize the typed-edge
# graph from notes/ frontmatter, then traverse it (neighbors BFS, incoming, hubs).
# Ported from the vault's extract_graph.py + query.py, generalized + domain-neutral.
#
# Uses a `mktemp -d` fixture as AGENT_BRAIN_DIR. Usage:
#   bash core/tests/brain-graph-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
BRAIN_DIR="$(mktemp -d)"
export AGENT_BRAIN_DIR="$BRAIN_DIR"

PASS=0
FAIL=0
cleanup() { [[ -n "${BRAIN_DIR:-}" && -d "$BRAIN_DIR" ]] && rm -rf "$BRAIN_DIR"; }
trap cleanup EXIT

# Seed a tiny typed-edge graph: a --supports--> b --extends--> c
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/core/brain")
import store
prov = {"ai": "claude", "session": "s", "generated_by": "brain-seed",
        "source": "test", "kind": "user"}
store.write_note(node_id="concept-a", note_type="concept", title="A",
                 body="a", edges={"supports": ["concept-b"]}, provenance=prov)
store.write_note(node_id="concept-b", note_type="concept", title="B",
                 body="b", edges={"extends": ["concept-c"]}, provenance=prov)
store.write_note(node_id="concept-c", note_type="concept", title="C",
                 body="c", edges={}, provenance=prov)
PY

echo "=== (a) extract materializes .graph/{nodes,edges}.jsonl ==="
run_extract=$(python3 "$REPO_ROOT/core/brain/graph.py" extract 2>&1)
NODES="$BRAIN_DIR/.graph/nodes.jsonl"
EDGES="$BRAIN_DIR/.graph/edges.jsonl"
if [[ -f "$NODES" && -f "$EDGES" ]]; then
  n_nodes=$(grep -c . "$NODES" || true)
  n_edges=$(grep -c . "$EDGES" || true)
  if [[ "$n_nodes" -eq 3 && "$n_edges" -eq 2 ]]; then
    echo "  ok   [extract] 3 nodes / 2 edges materialized"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [extract] expected 3 nodes / 2 edges, got $n_nodes / $n_edges :: $run_extract"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL [extract] .graph/*.jsonl not created :: $run_extract"
  FAIL=$((FAIL + 1))
fi

echo "=== (b) neighbors BFS reaches 2 hops (a → b → c) ==="
OUT=$(python3 "$REPO_ROOT/core/brain/graph.py" neighbors concept-a --depth 2 2>&1)
if [[ "$OUT" == *"concept-b"* && "$OUT" == *"concept-c"* ]]; then
  echo "  ok   [neighbors] reaches b and c"
  PASS=$((PASS + 1))
else
  echo "  FAIL [neighbors] :: $OUT"
  FAIL=$((FAIL + 1))
fi

echo "=== (c) incoming lists who points to b ==="
OUT=$(python3 "$REPO_ROOT/core/brain/graph.py" incoming concept-b 2>&1)
if [[ "$OUT" == *"concept-a"* ]]; then
  echo "  ok   [incoming] a → b found"
  PASS=$((PASS + 1))
else
  echo "  FAIL [incoming] :: $OUT"
  FAIL=$((FAIL + 1))
fi

echo "=== (d) hubs ranks nodes by degree ==="
OUT=$(python3 "$REPO_ROOT/core/brain/graph.py" hubs --top 5 2>&1)
if [[ "$OUT" == *"concept-b"* ]]; then
  echo "  ok   [hubs] emits ranked nodes"
  PASS=$((PASS + 1))
else
  echo "  FAIL [hubs] :: $OUT"
  FAIL=$((FAIL + 1))
fi

echo "=== (e) neighbors renders TRUE edge direction for an incoming edge ==="
# From concept-c the only edge is b --extends--> c (incoming to c). The output
# must render it in true direction, NOT reversed as c --extends--> b.
OUT=$(python3 "$REPO_ROOT/core/brain/graph.py" neighbors concept-c --depth 1 2>&1)
if [[ "$OUT" == *"concept-b --extends--> concept-c"* \
   && "$OUT" != *"concept-c --extends--> concept-b"* ]]; then
  echo "  ok   [neighbors-direction] incoming edge rendered b --extends--> c"
  PASS=$((PASS + 1))
else
  echo "  FAIL [neighbors-direction] edge direction wrong :: $OUT"
  FAIL=$((FAIL + 1))
fi

echo "=== (f) neighbors emits BOTH parallel typed edges, not a spanning tree ==="
# Two distinct typed edges between the same pair: a spanning-tree BFS would keep
# only the first-seen and silently drop the other. Both must surface.
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/core/brain")
import store
prov = {"ai": "claude", "session": "s", "generated_by": "brain-seed",
        "source": "test", "kind": "user"}
store.write_note(node_id="concept-p", note_type="concept", title="P", body="p",
                 edges={"supports": ["concept-q"], "contradicts": ["concept-q"]},
                 provenance=prov)
store.write_note(node_id="concept-q", note_type="concept", title="Q", body="q",
                 edges={}, provenance=prov)
PY
OUT=$(python3 "$REPO_ROOT/core/brain/graph.py" neighbors concept-p --depth 1 2>&1)
if [[ "$OUT" == *"concept-p --supports--> concept-q"* \
   && "$OUT" == *"concept-p --contradicts--> concept-q"* ]]; then
  echo "  ok   [neighbors-parallel-edges] both supports and contradicts surfaced"
  PASS=$((PASS + 1))
else
  echo "  FAIL [neighbors-parallel-edges] a parallel edge was dropped :: $OUT"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
