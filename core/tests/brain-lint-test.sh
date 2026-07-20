#!/usr/bin/env bash
# brain-lint-test.sh — verify core/brain/lint.py: the deterministic notes/ lint
# gate the brain-ingest distill skill runs a candidate note through (0 errors)
# before it is promotable, mirroring the reference vault's wiki_lint discipline.
#
# Covers: a store written entirely through store.write_note is clean (the writer
# and the linter agree); a hand-corrupted note trips the right ERROR code
# (E2 id-mismatch, E4 provenance-incomplete, E5 kind-invalid); a note with no
# edges / a dangling edge is a WARNING by default but an ERROR under --strict
# (the >=1-edge / no-dangling promotion gate); and --json is machine-readable.
#
# Uses a `mktemp -d` fixture as AGENT_BRAIN_DIR — never the real ~/.agent/brain.
# Usage: bash core/tests/brain-lint-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
LINT="$REPO_ROOT/core/brain/lint.py"
BRAIN_DIR="$(mktemp -d)"
export AGENT_BRAIN_DIR="$BRAIN_DIR"

PASS=0
FAIL=0
cleanup() { [[ -n "${BRAIN_DIR:-}" && -d "$BRAIN_DIR" ]] && rm -rf "$BRAIN_DIR"; }
trap cleanup EXIT
ok() { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
no() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# seed <id> <type> — write one clean, fully-provenanced note with >=1 edge.
seed() {
  REPO_ROOT="$REPO_ROOT" AGENT_BRAIN_DIR="$BRAIN_DIR" ID="$1" TYPE="$2" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/core/brain")
import store
store.write_note(node_id=os.environ["ID"], note_type=os.environ["TYPE"],
                 title="seed note", body="a clean body",
                 edges={"topic-tag": ["topic-x"]},
                 provenance={"ai": "claude", "session": "s", "generated_by": "brain-ingest",
                             "source": "raw:x", "kind": "generated"})
PY
}

reset_store() { rm -rf "$BRAIN_DIR"/notes "$BRAIN_DIR"/raw "$BRAIN_DIR"/.graph 2>/dev/null; }

echo "=== (a) a store written via write_note is clean (exit 0, PASS) ==="
reset_store
seed "concept-alpha" "concept"
# 'topic-x' is a dangling target here (only a warning) → give it a home so the
# default run is truly clean.
seed "topic-x" "topic"
OUT="$(python3 "$LINT" 2>&1)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == PASS* ]]; then ok "clean-store-passes"; else no "clean-store-passes" "rc=$RC out='$OUT'"; fi

echo "=== (b) an id-mismatch note trips E2 (exit 1) ==="
reset_store
seed "concept-alpha" "concept"
# rewrite the frontmatter id so it no longer equals the filename stem
python3 - "$BRAIN_DIR/notes/concept/concept-alpha.md" <<'PY'
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(re.sub(r"(?m)^id: .*$", "id: concept-WRONG", p.read_text()), encoding="utf-8")
PY
OUT="$(python3 "$LINT" 2>&1)"; RC=$?
if [[ "$RC" -eq 1 && "$OUT" == *"E2"* ]]; then ok "id-mismatch-E2"; else no "id-mismatch-E2" "rc=$RC out='$OUT'"; fi

echo "=== (c) incomplete provenance trips E4, invalid kind trips E5 (exit 1) ==="
reset_store
mkdir -p "$BRAIN_DIR/notes/insight"
cat > "$BRAIN_DIR/notes/insight/insight-bad.md" <<'EOF'
---
id: insight-bad
type: insight
title: "bad provenance"
status: seed
edges: {}
provenance:
  ai: ""
  session: "s"
  generated_by: ""
  source: "x"
  kind: "forged"
---

body
EOF
OUT="$(python3 "$LINT" 2>&1)"; RC=$?
if [[ "$RC" -eq 1 && "$OUT" == *"E4"* && "$OUT" == *"E5"* ]]; then ok "provenance-E4-E5"; else no "provenance-E4-E5" "rc=$RC out='$OUT'"; fi

echo "=== (d) no-edge + dangling edge = warnings by default (exit 0) but errors under --strict (exit 1) ==="
reset_store
mkdir -p "$BRAIN_DIR/notes/concept"
# concept-lonely: 0 edges (W1). concept-dangle: one edge to a note that doesn't exist (W2).
cat > "$BRAIN_DIR/notes/concept/concept-lonely.md" <<'EOF'
---
id: concept-lonely
type: concept
title: "lonely"
status: seed
edges: {}
provenance:
  ai: "claude"
  session: "s"
  generated_by: "brain-ingest"
  source: "x"
  kind: "generated"
---

body
EOF
cat > "$BRAIN_DIR/notes/concept/concept-dangle.md" <<'EOF'
---
id: concept-dangle
type: concept
title: "dangle"
status: seed
edges:
  supports: [[concept-ghost]]
provenance:
  ai: "claude"
  session: "s"
  generated_by: "brain-ingest"
  source: "x"
  kind: "generated"
---

body
EOF
OUT_DEFAULT="$(python3 "$LINT" 2>&1)"; RC_DEFAULT=$?
OUT_STRICT="$(python3 "$LINT" --strict 2>&1)"; RC_STRICT=$?
if [[ "$RC_DEFAULT" -eq 0 && "$OUT_DEFAULT" == *"W1"* && "$OUT_DEFAULT" == *"W2"* \
      && "$RC_STRICT" -eq 1 ]]; then
  ok "warnings-default-strict"
else
  no "warnings-default-strict" "def(rc=$RC_DEFAULT) strict(rc=$RC_STRICT) out='$OUT_DEFAULT'"
fi

echo "=== (e) a note with no frontmatter trips E1 (exit 1) ==="
reset_store
mkdir -p "$BRAIN_DIR/notes/concept"
printf 'just a body, no frontmatter\n' > "$BRAIN_DIR/notes/concept/concept-nofm.md"
OUT="$(python3 "$LINT" 2>&1)"; RC=$?
if [[ "$RC" -eq 1 && "$OUT" == *"E1"* ]]; then ok "no-frontmatter-E1"; else no "no-frontmatter-E1" "rc=$RC out='$OUT'"; fi

echo "=== (f) --json emits a machine-readable summary with clean flag ==="
reset_store
seed "concept-alpha" "concept"
seed "topic-x" "topic"
JSON="$(python3 "$LINT" --json 2>&1)"; RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["clean"] is True; assert d["errors"]==[]' 2>/dev/null; then
  ok "json-summary"
else
  no "json-summary" "rc=$RC json='$JSON'"
fi

echo "=== (g) an empty store (no notes/) is clean, never crashes ==="
reset_store
OUT="$(python3 "$LINT" 2>&1)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == PASS* ]]; then ok "empty-store-clean"; else no "empty-store-clean" "rc=$RC out='$OUT'"; fi

echo "=== (h) a brain-ingest note forged to kind=user trips E6 (trust sentinel, exit 1) ==="
reset_store
mkdir -p "$BRAIN_DIR/notes/insight"
# provenance is COMPLETE and kind is a VALID enum value ('user') — so E4 and E5
# both stay silent. Only E6 catches that an AI distillation (generated_by=
# brain-ingest) laundered its trust sentinel to 'user'.
cat > "$BRAIN_DIR/notes/insight/insight-forged.md" <<'EOF'
---
id: insight-forged
type: insight
title: "forged trust"
status: growing
edges:
  supports: [[concept-x]]
provenance:
  ai: "claude"
  session: "s"
  generated_by: "brain-ingest"
  source: "raw:x"
  kind: "user"
---

body
EOF
OUT="$(python3 "$LINT" 2>&1)"; RC=$?
if [[ "$RC" -eq 1 && "$OUT" == *"E6"* && "$OUT" != *"E5"* ]]; then ok "forged-trust-E6"; else no "forged-trust-E6" "rc=$RC out='$OUT'"; fi

echo "=== (i) a note whose frontmatter omits the id: key trips E2 (not vacuously clean) ==="
reset_store
mkdir -p "$BRAIN_DIR/notes/concept"
# valid title/type/provenance but NO id: line. The parser would default id to the
# filename stem; E2 must still fire because the key is absent (schema requires it).
cat > "$BRAIN_DIR/notes/concept/concept-noid.md" <<'EOF'
---
type: concept
title: "no id key"
status: seed
edges:
  topic-tag: [[topic-x]]
provenance:
  ai: "claude"
  session: "s"
  generated_by: "brain-ingest"
  source: "raw:x"
  kind: "generated"
---

body
EOF
OUT="$(python3 "$LINT" 2>&1)"; RC=$?
if [[ "$RC" -eq 1 && "$OUT" == *"E2"* && "$OUT" == *"no id: key"* ]]; then ok "absent-id-key-E2"; else no "absent-id-key-E2" "rc=$RC out='$OUT'"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
