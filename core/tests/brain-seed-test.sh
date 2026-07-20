#!/usr/bin/env bash
# brain-seed-test.sh — verify core/brain/seed.py: the selective one-time bootstrap
# that imports high-signal curated notes from a wiki vault + a native-memory dir
# into the brain (source -> brain), never a bulk dump and never writing back.
#
# Covers: vault selection by status + confidence; memory selection by
# metadata.type with the type mapping (feedback->insight, project->episode);
# dry-run writes NOTHING; --apply writes notes with provenance kind=user + a
# source trace and preserves typed edges; an unsafe id is reported skipped (not
# written); the seeded store passes lint.py; and the SOURCE files are untouched
# (one-way import).
#
# All sources are `mktemp -d` synthetic fixtures — NEVER the real vault or the
# real ~/.claude memory. Usage: bash core/tests/brain-seed-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
SEED="$REPO_ROOT/core/brain/seed.py"
LINT="$REPO_ROOT/core/brain/lint.py"
BRAIN_DIR="$(mktemp -d)"; export AGENT_BRAIN_DIR="$BRAIN_DIR"
VAULT="$(mktemp -d)"
MEM="$(mktemp -d)"

PASS=0; FAIL=0
cleanup() { rm -rf "$BRAIN_DIR" "$VAULT" "$MEM"; }
trap cleanup EXIT
ok() { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
no() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }
reset_brain() { rm -rf "$BRAIN_DIR"/notes "$BRAIN_DIR"/raw "$BRAIN_DIR"/.graph 2>/dev/null; }

# --- build the vault fixture -------------------------------------------------
mkdir -p "$VAULT/wiki"
cat > "$VAULT/wiki/concept-alpha.md" <<'EOF'
---
id: concept-alpha
type: concept
title: "Alpha concept"
status: evergreen
confidence: 0.9
edges:
  supports: [[concept-beta]]
---
Body of alpha.
EOF
cat > "$VAULT/wiki/insight-gamma.md" <<'EOF'
---
id: insight-gamma
type: insight
title: "Gamma insight"
status: growing
edges: {}
---
Body of gamma.
EOF
cat > "$VAULT/wiki/concept-draft.md" <<'EOF'
---
id: concept-draft
type: concept
title: "Draft"
status: seed
edges: {}
---
Not selected — status seed.
EOF
cat > "$VAULT/wiki/concept-lowconf.md" <<'EOF'
---
id: concept-lowconf
type: concept
title: "Low confidence"
status: evergreen
confidence: 0.2
edges: {}
---
Selected by status but low confidence.
EOF
cat > "$VAULT/wiki/concept-badid.md" <<'EOF'
---
id: ../evil
type: concept
title: "Unsafe id"
status: evergreen
edges: {}
---
Its id is a path-traversal string.
EOF

# --- build the native-memory fixture ----------------------------------------
cat > "$MEM/feedback-tone.md" <<'EOF'
---
name: feedback-tone
description: "Keep answers concise"
metadata:
  node_type: memory
  type: feedback
---
The user prefers concise answers.
EOF
cat > "$MEM/project-brain.md" <<'EOF'
---
name: project-brain
description: "Agent brain build"
metadata:
  node_type: memory
  type: project
---
Ongoing cross-AI brain work.
EOF
cat > "$MEM/user-who.md" <<'EOF'
---
name: user-who
description: "Who the user is"
metadata:
  node_type: memory
  type: user
---
Not selected — type user.
EOF
cat > "$MEM/MEMORY.md" <<'EOF'
# Memory Index
- [x](feedback-tone.md) — hook
EOF

echo "=== (a) dry-run selects evergreen+growing vault notes, skips seed-status, writes NOTHING ==="
reset_brain
OUT="$(python3 "$SEED" --vault "$VAULT" 2>&1)"; RC=$?
NOTES_AFTER=$(find "$BRAIN_DIR/notes" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RC" -eq 0 && "$OUT" == *"concept-alpha"* && "$OUT" == *"insight-gamma"* \
      && "$OUT" != *"+ concept-draft"* && "$NOTES_AFTER" -eq 0 ]]; then
  ok "vault-dryrun-selects"
else
  no "vault-dryrun-selects" "rc=$RC notes=$NOTES_AFTER out<<<$OUT>>>"
fi

echo "=== (b) memory selection by metadata.type (feedback,project) skips type=user ==="
reset_brain
OUT="$(python3 "$SEED" --memory "$MEM" 2>&1)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == *"mem-feedback-tone"* && "$OUT" == *"mem-project-brain"* \
      && "$OUT" != *"user-who"* ]]; then
  ok "memory-dryrun-selects"
else
  no "memory-dryrun-selects" "rc=$RC out<<<$OUT>>>"
fi

echo "=== (c) --apply writes notes (kind=user, source, type mapping, edges) + lint passes ==="
reset_brain
python3 "$SEED" --vault "$VAULT" --memory "$MEM" --apply >/dev/null 2>&1
if REPO_ROOT="$REPO_ROOT" AGENT_BRAIN_DIR="$BRAIN_DIR" python3 - <<'PY' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/core/brain")
import store
# vault note imported as concept, kind=user (human-curated origin), edge preserved
g = store.get_note("concept-alpha")
assert g, "concept-alpha not written"
node, edges, _ = g
assert node["type"] == "concept" and node["provenance"]["kind"] == "user", node
assert node["provenance"]["source"] == "vault:concept-alpha", node["provenance"]
assert node["provenance"]["generated_by"] == "brain-seed", node["provenance"]
assert ("supports", "concept-beta") in {(e["type"], e["target"]) for e in edges}, edges
# memory feedback -> insight, project -> episode; kind=generated (AI-authored origin)
assert store.get_note("mem-feedback-tone")[0]["type"] == "insight"
assert store.get_note("mem-project-brain")[0]["type"] == "episode"
assert store.get_note("mem-feedback-tone")[0]["provenance"]["kind"] == "generated"
PY
then LINT_OUT="$(python3 "$LINT" 2>&1)"; LRC=$?
     if [[ "$LRC" -eq 0 ]]; then ok "apply-writes-and-lints"; else no "apply-writes-and-lints" "lint rc=$LRC: $LINT_OUT"; fi
else no "apply-writes-and-lints" "provenance/type/edge assertion failed"; fi

echo "=== (d) an unsafe id is reported skipped and never written ==="
reset_brain
OUT="$(python3 "$SEED" --vault "$VAULT" --apply 2>&1)"; RC=$?
BADID=$(find "$BRAIN_DIR/notes" -name 'evil*' 2>/dev/null | wc -l | tr -d ' ')
ESCAPED=$([[ -e "$BRAIN_DIR/notes/../evil.md" ]] && echo yes || echo no)
if [[ "$OUT" == *"SKIPPED"* && "$BADID" -eq 0 && "$ESCAPED" == "no" ]]; then
  ok "unsafe-id-skipped"
else
  no "unsafe-id-skipped" "rc=$RC badid=$BADID escaped=$ESCAPED out<<<$OUT>>>"
fi

echo "=== (e) --min-confidence drops low-confidence vault notes ==="
reset_brain
OUT="$(python3 "$SEED" --vault "$VAULT" --min-confidence 0.5 2>&1)"
# concept-alpha (0.9) stays; concept-lowconf (0.2) is dropped from the selected list
if [[ "$OUT" == *"+ concept-alpha"* && "$OUT" != *"+ concept-lowconf"* ]]; then
  ok "min-confidence-filter"
else
  no "min-confidence-filter" "out<<<$OUT>>>"
fi

echo "=== (f) import is one-way: source files are byte-identical after --apply ==="
reset_brain
BEFORE=$(cat "$VAULT/wiki/concept-alpha.md" "$MEM/feedback-tone.md" | shasum | awk '{print $1}')
python3 "$SEED" --vault "$VAULT" --memory "$MEM" --apply >/dev/null 2>&1
AFTER=$(cat "$VAULT/wiki/concept-alpha.md" "$MEM/feedback-tone.md" | shasum | awk '{print $1}')
if [[ "$BEFORE" == "$AFTER" ]]; then ok "sources-untouched"; else no "sources-untouched" "source mutated"; fi

echo "=== (g) an in-run id collision is reported skipped, first write wins (no silent loss) ==="
reset_brain
# two memory dirs whose notes share the same frontmatter name -> same mem-<slug> id
COLA="$(mktemp -d)"; COLB="$(mktemp -d)"
cat > "$COLA/n.md" <<'EOF'
---
name: shared-name
description: "from A"
metadata:
  type: project
---
body A
EOF
cat > "$COLB/n.md" <<'EOF'
---
name: shared-name
description: "from B"
metadata:
  type: project
---
body B
EOF
OUT="$(python3 "$SEED" --memory "$COLA" --memory "$COLB" --apply 2>&1)"
WRITTEN=$(find "$BRAIN_DIR/notes" -name 'mem-shared-name.md' | wc -l | tr -d ' ')
rm -rf "$COLA" "$COLB"
if [[ "$OUT" == *"collision"* && "$WRITTEN" -eq 1 && "$OUT" == *"wrote 1 note"* ]]; then
  ok "collision-reported-not-silent"
else
  no "collision-reported-not-silent" "written=$WRITTEN out<<<$OUT>>>"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
