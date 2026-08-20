#!/usr/bin/env bash
# completion-gate-test.sh — verify P1 grounded-completion-gate:
# core/infra/completion-gate.sh, the first BLOCKING consumer of
# completion-verify.py's verdict (docs/gate-registry.md `completion-gate` row).
#
# Every scenario runs against a fixture git repo (mktemp -d, git init) so the
# real repo's .agent/logs and .agent/claims are never touched. The real
# completion-verify.py is reached via AGENT_COMPLETION_VERIFY_BIN — the gate's
# test seam — since the fixture repo is not the Agent repo itself and the
# gate's default resolves the verifier relative to `git rev-parse --show-toplevel`.
# The seam is honored ONLY alongside AGENT_REPRODUCE_TEST=1 (security fix,
# case (n) proves the negative — without it the seam is ignored even when set).
#
# Contract covered:
#   (a) off mode                       -> no-op, exit 0, no sink, no canary run
#   (b) dryrun + false claim           -> exit 0, sink records REFUTED
#   (c) block + false claim            -> exit 1, refutations printed
#   (d) block + true claim             -> exit 0, CONFIRMED
#   (e) canary death (stubbed verifier always exits 0) -> exit 2, fail-closed
#   (f) sink escape override           -> falls back to the default in-repo sink
#   (g) AGENT_REPRODUCE_TEST=1         -> record marked reproduce:true
#   (h) claim cites nothing but PARSES -> needs_semantic, exit 0 (never a hard block)
#   (i) explicit claim path is missing -> distinct "claim file missing", block mode exit 1
#   (j) Blocker-1 regression: code diff + EMPTY claim -> block mode still exit 1
#       (needs_semantic must NOT downgrade a real --require-evidence REFUTED)
#   (k) canary PARTIAL death (file-check works, test-check silently broken) -> exit 2
#   (l) RECORD always carries diff_base_used (ref or null)
#   (m) empty verifier stdout -> explicit named refutation, not a bare REFUTED
#   (n) AGENT_COMPLETION_VERIFY_BIN is IGNORED without AGENT_REPRODUCE_TEST=1
#   (o) claim path fallback: wave-suffixed file exists -> used
#   (p) claim path fallback: wave-suffixed absent, slug-only convention exists -> falls back
#   (q) claim path fallback: NEITHER exists -> "claim file missing" names both paths
#
# Usage: bash core/tests/completion-gate-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/core/infra/completion-gate.sh"
REAL_VERIFY="$REPO_ROOT/core/infra/completion-verify.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

if ! command -v git >/dev/null 2>&1; then
  echo "  FAIL [git-available] — this battery needs git to build fixture repos"
  echo "=== Results: 0 passed, 1 failed ==="
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# fixture — a fresh isolated git repo with a real src file to cite.
FIX="$TMP_ROOT/fixture"
mkdir -p "$FIX/src" "$FIX/.agent/claims"
( cd "$FIX" && git init -q && git config user.email t@t.com && git config user.name t )
printf 'x = 1\n' > "$FIX/src/mod.py"
( cd "$FIX" && git add -A && git commit -qm init )

CLAIM_FILE="$FIX/.agent/claims/demo-w1.yml"
SINK_FILE="$FIX/.agent/logs/completion-gate.jsonl"
WAVE_CLAIM_PATH="$FIX/.agent/claims/demo-w1.yml"
SLUG_CLAIM_PATH="$FIX/.agent/claims/demo.yml"

write_false_claim() {
  cat > "$CLAIM_FILE" <<'EOF'
claim:
  summary: "false claim — cites a file that does not exist"
  files:
    - { path: "src/ghost.py" }
EOF
}
write_true_claim() {
  cat > "$CLAIM_FILE" <<'EOF'
claim:
  summary: "true claim — cites a real file"
  files:
    - { path: "src/mod.py" }
EOF
}
write_empty_but_valid_claim() {
  cat > "$CLAIM_FILE" <<'EOF'
claim:
  summary: "improved the color palette — no mechanically-checkable artifact"
EOF
}
reset_sink() { rm -f "$SINK_FILE"; }
clear_claims_dir() { rm -f "$FIX/.agent/claims"/*.yml; }

# run_gate <mode> -- always uses the seam correctly (VERIFY_BIN + REPRODUCE
# together); echoes exit code. run with the fixture repo as CWD.
run_gate() {
  local mode="$1"
  ( cd "$FIX" && env AGENT_VERIFY_BLOCKING="$mode" AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
      AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" )
  echo $?
}

echo "=== (a) off mode -> no-op, exit 0, no sink, no canary run ==="
reset_sink
write_false_claim
RC=$(run_gate off)
[[ "$RC" -eq 0 ]]; check "off-exit-0" $?
[[ ! -f "$SINK_FILE" ]]; check "off-no-sink-written" $?

echo
echo "=== (b) dryrun + false claim -> exit 0, sink records REFUTED ==="
reset_sink
write_false_claim
RC=$(run_gate dryrun)
[[ "$RC" -eq 0 ]]; check "dryrun-false-exit-0" $?
[[ -f "$SINK_FILE" ]]; check "dryrun-sink-written" $?
grep -q '"verdict": "REFUTED"' "$SINK_FILE"; check "dryrun-sink-refuted" $?

echo
echo "=== (c) block + false claim -> exit 1, refutations printed ==="
reset_sink
write_false_claim
OUT="$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ) 2>&1 )"
RC=$?
[[ "$RC" -eq 1 ]]; check "block-false-exit-1" $?
[[ "$OUT" == *"REFUTED"* ]]; check "block-false-mentions-refuted" $?
[[ "$OUT" == *"ghost.py"* ]]; check "block-false-names-refutation" $?

echo
echo "=== (d) block + true claim -> exit 0, CONFIRMED ==="
reset_sink
write_true_claim
RC=$(run_gate block)
[[ "$RC" -eq 0 ]]; check "block-true-exit-0" $?
grep -q '"verdict": "CONFIRMED"' "$SINK_FILE"; check "block-true-sink-confirmed" $?

echo
echo "=== (e) canary death (stubbed verifier always CONFIRMS) -> exit 2, fail-closed ==="
STUB="$TMP_ROOT/always-confirms.py"
cat > "$STUB" <<'EOF'
import json, sys
print(json.dumps({"verdict": "CONFIRMED", "score": 1.0, "target": "x",
                   "dimensions": {}, "refutations": [], "schema_version": "1.0.0"}))
sys.exit(0)
EOF
reset_sink
write_true_claim
OUT="$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$STUB" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ) 2>&1 )"
RC=$?
[[ "$RC" -eq 2 ]]; check "canary-death-exit-2" $?
[[ "$OUT" == *"CANARY"* ]]; check "canary-death-message-names-canary" $?

echo
echo "=== (f) sink escape override -> falls back to the default in-repo sink ==="
reset_sink
rm -f /tmp/completion-gate-escape-test.jsonl 2>/dev/null
write_true_claim
RC=$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=dryrun AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 AGENT_COMPLETION_GATE_SINK="/etc/completion-gate-escape-test.jsonl" \
    bash "$GATE" demo 1 "$CLAIM_FILE" ); echo $? )
[[ "$RC" -eq 0 ]]; check "escape-exit-0" $?
[[ -f "$SINK_FILE" ]]; check "escape-fell-back-to-default-sink" $?
[[ ! -f "/etc/completion-gate-escape-test.jsonl" ]]; check "escape-did-not-write-outside" $?

echo
echo "=== (g) AGENT_REPRODUCE_TEST=1 -> record marked reproduce:true ==="
reset_sink
write_true_claim
RC=$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=dryrun AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ); echo $? )
[[ "$RC" -eq 0 ]]; check "reproduce-exit-0" $?
grep -q '"reproduce": true' "$SINK_FILE"; check "reproduce-flag-marked" $?

echo
echo "=== (h) claim cites nothing but PARSES -> needs_semantic, exit 0 (never a hard block) ==="
reset_sink
write_empty_but_valid_claim
OUT="$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ) 2>&1 )"
RC=$?
[[ "$RC" -eq 0 ]]; check "needs-semantic-exit-0-even-in-block-mode" $?
[[ "$OUT" == *"verify-completion"* ]]; check "needs-semantic-guidance-printed" $?

echo
echo "=== (i) explicit claim path is missing -> distinct 'claim file missing', block mode exit 1 ==="
reset_sink
rm -f "$CLAIM_FILE"
OUT="$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ) 2>&1 )"
RC=$?
[[ "$RC" -eq 1 ]]; check "missing-claim-still-blocks" $?
[[ "$OUT" == *"claim file missing"* ]]; check "missing-claim-distinct-message" $?
[[ "$OUT" != *"verify-completion"* ]]; check "missing-claim-not-misrouted-to-needs-semantic" $?

echo
echo "=== (j) Blocker-1 regression: code diff present + EMPTY claim -> block mode still exit 1 ==="
# needs_semantic must NOT downgrade a real --require-evidence REFUTED just
# because core_total (files+tests+assertions) is 0 — the OLD naive check did.
reset_sink
printf 'x = 2\n' > "$FIX/src/mod.py"   # uncommitted code change -> _git_diff_names sees it
cat > "$CLAIM_FILE" <<'EOF'
claim:
  summary: "empty claim while code changed — must not be waved through as needs_semantic"
EOF
OUT="$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ) 2>&1 )"
RC=$?
[[ "$RC" -eq 1 ]]; check "blocker1-code-diff-empty-claim-blocks" $?
[[ "$OUT" == *"REFUTED"* ]]; check "blocker1-mentions-refuted" $?
[[ "$OUT" != *"dispatch /verify-completion"* ]]; check "blocker1-not-misrouted-to-needs-semantic" $?
grep -q '"verdict": "REFUTED"' "$SINK_FILE"; check "blocker1-sink-refuted" $?
grep -q "cites no runnable evidence" "$SINK_FILE"; check "blocker1-sink-names-evidence-refutation" $?
( cd "$FIX" && git checkout -q -- src/mod.py )   # restore for later tests

echo
echo "=== (k) canary PARTIAL death: file-check works, test-check silently broken -> exit 2 ==="
PARTIAL="$TMP_ROOT/partial-death.py"
cat > "$PARTIAL" <<'EOF'
import argparse, json, os, sys
ap = argparse.ArgumentParser()
ap.add_argument("claim")
ap.add_argument("--root", default=None)
ap.add_argument("--require-evidence", action="store_true")
ap.add_argument("--diff-base", default=None)
args = ap.parse_args()
root = args.root or os.getcwd()
try:
    with open(args.claim) as fh:
        doc = json.load(fh)
except Exception:
    doc = {}
claim = doc.get("claim", doc) if isinstance(doc, dict) else {}
refutations = []
for item in (claim.get("files") or []):
    path = item.get("path") if isinstance(item, dict) else item
    full = os.path.join(root, path) if path else None
    if not path or not (full and os.path.isfile(full)):
        refutations.append("file does not exist: %s" % path)
# THE INJECTED DEFECT: the test-check never runs / never refutes — exactly
# what a regressed _run() that always returns True would produce.
verdict = "CONFIRMED" if not refutations else "REFUTED"
print(json.dumps({"verdict": verdict, "score": 0.0, "target": "x",
                   "dimensions": {}, "refutations": refutations, "schema_version": "1.0.0"}))
sys.exit(0 if verdict == "CONFIRMED" else 1)
EOF
reset_sink
write_true_claim
OUT="$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$PARTIAL" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ) 2>&1 )"
RC=$?
[[ "$RC" -eq 2 ]]; check "canary-partial-death-exit-2" $?
[[ "$OUT" == *"TEST-FAILURE check did not fire"* ]]; check "canary-partial-death-names-test-check" $?

echo
echo "=== (l) RECORD always carries diff_base_used (ref or null) ==="
reset_sink
write_true_claim
run_gate dryrun >/dev/null
grep -q '"diff_base_used"' "$SINK_FILE"; check "diff-base-used-field-present" $?

echo
echo "=== (m) empty verifier stdout -> explicit named refutation, not a bare REFUTED ==="
EMPTYSTUB="$TMP_ROOT/empty-stdout.py"
cat > "$EMPTYSTUB" <<'EOF'
import argparse, json, os, sys
ap = argparse.ArgumentParser()
ap.add_argument("claim")
ap.add_argument("--root", default=None)
ap.add_argument("--require-evidence", action="store_true")
ap.add_argument("--diff-base", default=None)
args = ap.parse_args()
if "canary" in os.path.basename(args.claim):
    # behave like the real verifier for the liveness canary probe
    root = args.root or os.getcwd()
    try:
        with open(args.claim) as fh:
            doc = json.load(fh)
    except Exception:
        doc = {}
    claim = doc.get("claim", doc) if isinstance(doc, dict) else {}
    refs = []
    for item in (claim.get("files") or []):
        path = item.get("path") if isinstance(item, dict) else item
        full = os.path.join(root, path) if path else None
        if not path or not (full and os.path.isfile(full)):
            refs.append("file does not exist: %s" % path)
    for cmd in (claim.get("tests") or []):
        refs.append("test did not pass: %s" % cmd)
    verdict = "REFUTED" if refs else "CONFIRMED"
    print(json.dumps({"verdict": verdict, "score": 0.0, "target": "x",
                       "dimensions": {}, "refutations": refs, "schema_version": "1.0.0"}))
    sys.exit(0 if verdict == "CONFIRMED" else 1)
else:
    # simulate a crash on the REAL claim call: no stdout at all
    sys.exit(1)
EOF
reset_sink
write_true_claim
RC=$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=dryrun AGENT_COMPLETION_VERIFY_BIN="$EMPTYSTUB" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 "$CLAIM_FILE" ); echo $? )
[[ "$RC" -eq 0 ]]; check "empty-stdout-dryrun-exit-0" $?
grep -q '"verdict": "REFUTED"' "$SINK_FILE"; check "empty-stdout-sink-refuted" $?
grep -q "did not parse/empty" "$SINK_FILE"; check "empty-stdout-explicit-refutation" $?

echo
echo "=== (n) AGENT_COMPLETION_VERIFY_BIN is IGNORED without AGENT_REPRODUCE_TEST=1 ==="
# The fixture repo has no core/infra/completion-verify.py of its own — with the
# seam correctly ignored, the gate tries the (here, nonexistent) hardcoded
# in-repo path and fails closed at the canary. This proves the override was
# NOT honored (security fix response to the code-review finding).
reset_sink
write_true_claim
RC=$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    bash "$GATE" demo 1 "$CLAIM_FILE" ); echo $? )
[[ "$RC" -eq 2 ]]; check "seam-ignored-without-reproduce-flag" $?

echo
echo "=== (o) claim path fallback: wave-suffixed file exists -> used ==="
reset_sink
clear_claims_dir
cat > "$WAVE_CLAIM_PATH" <<'EOF'
claim:
  summary: "wave-suffixed claim"
  files:
    - { path: "src/mod.py" }
EOF
RC=$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 ); echo $? )   # no explicit claim-path arg
[[ "$RC" -eq 0 ]]; check "fallback-wave-suffixed-confirmed" $?
grep -qF "demo-w1.yml" "$SINK_FILE"; check "fallback-wave-suffixed-path-recorded" $?

echo
echo "=== (p) claim path fallback: wave-suffixed absent, slug-only convention exists -> falls back ==="
reset_sink
clear_claims_dir
cat > "$SLUG_CLAIM_PATH" <<'EOF'
claim:
  summary: "slug-only convention claim"
  files:
    - { path: "src/mod.py" }
EOF
RC=$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 ); echo $? )
[[ "$RC" -eq 0 ]]; check "fallback-slug-only-confirmed" $?
grep -qF "demo.yml" "$SINK_FILE"; check "fallback-slug-only-path-recorded" $?

echo
echo "=== (q) claim path fallback: NEITHER exists -> 'claim file missing' names both paths ==="
reset_sink
clear_claims_dir
OUT="$( ( cd "$FIX" && env AGENT_VERIFY_BLOCKING=block AGENT_COMPLETION_VERIFY_BIN="$REAL_VERIFY" \
    AGENT_REPRODUCE_TEST=1 bash "$GATE" demo 1 ) 2>&1 )"
RC=$?
[[ "$RC" -eq 1 ]]; check "fallback-neither-blocks" $?
[[ "$OUT" == *"claim file missing"* ]]; check "fallback-neither-names-missing" $?
[[ "$OUT" == *"demo-w1.yml"* && "$OUT" == *"demo.yml"* ]]; check "fallback-neither-names-both-paths" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
