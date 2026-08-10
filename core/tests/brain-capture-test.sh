#!/usr/bin/env bash
# brain-capture-test.sh — verify core/hooks/brain-capture.py: the cross-AI Stop
# hook that leaves a session breadcrumb in the brain's raw/ quarantine.
#
# Covers: a Stop event on a DIRTY tree writes exactly one raw capture with
# provenance (kind=generated), never notes/; a non-Stop event is a no-op; a CLEAN
# tree is gated out (no noise); the env-driven path (no stdin — the codex/gemini
# wrappers' call shape) also captures; stdout is always empty (pass-through); and
# malformed stdin is fail-open (exit 0, no crash).
#
# Uses mktemp -d fixtures for AGENT_BRAIN_DIR and throwaway git repos — never the
# real brain or repo. Usage: bash core/tests/brain-capture-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
HOOK="$REPO_ROOT/core/hooks/brain-capture.py"
BRAIN_DIR="$(mktemp -d)"
export AGENT_BRAIN_DIR="$BRAIN_DIR"
DIRTY="$(mktemp -d)"
CLEAN="$(mktemp -d)"
cleanup() { rm -rf "$BRAIN_DIR" "$DIRTY" "$CLEAN"; }
trap cleanup EXIT

mkrepo() {  # <dir> — init a git repo with one committed file
  git -C "$1" init -q
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name test
  echo "seed" > "$1/a.txt"
  git -C "$1" add a.txt
  git -C "$1" commit -qm init
}
mkrepo "$DIRTY"
mkrepo "$CLEAN"
echo "uncommitted change" >> "$DIRTY/a.txt"   # DIRTY tree = has WIP; CLEAN stays committed

PASS=0
FAIL=0
ok() { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
no() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }
raw_count()   { find "$BRAIN_DIR/raw"   -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }
notes_count() { find "$BRAIN_DIR/notes" -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

echo "=== (a) Stop on a DIRTY tree → one raw capture, empty stdout, exit 0 ==="
BEFORE=$(raw_count)
JSON="{\"ai\":\"codex\",\"session_id\":\"s-1\",\"event\":\"Stop\",\"cwd\":\"$DIRTY\",\"transcript_path\":\"/tmp/t.jsonl\"}"
STDOUT=$(printf '%s' "$JSON" | python3 "$HOOK" 2>/dev/null); RC=$?
AFTER=$(raw_count)
if [[ "$RC" -eq 0 && -z "$STDOUT" && "$((AFTER - BEFORE))" -eq 1 && "$(notes_count)" -eq 0 ]]; then
  ok "stop-dirty-captures"
else
  no "stop-dirty-captures" "rc=$RC stdout='$STDOUT' delta=$((AFTER - BEFORE)) notes=$(notes_count)"
fi

echo "=== (b) capture carries provenance ai=codex, kind=generated, brain-capture ==="
if REPO_ROOT="$REPO_ROOT" AGENT_BRAIN_DIR="$BRAIN_DIR" python3 - <<'PY' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/core/brain")
import store
raws = list(store.raw_dir().rglob("*.md"))
assert len(raws) == 1, raws
node, _ = store.parse_note(raws[0])
p = node["provenance"]
assert p["ai"] == "codex", p
assert p["kind"] == "generated", p
assert p["generated_by"] == "brain-capture", p
assert store.raw_dir() in raws[0].parents
body = raws[0].read_text(encoding="utf-8")
assert "a.txt" in body, "diffstat/status did not mention the changed file"
PY
then ok "provenance"; else no "provenance" "provenance/body assertion failed"; fi

echo "=== (c) non-Stop event (SessionStart) → no-op, no capture ==="
BEFORE=$(raw_count)
JSON="{\"ai\":\"codex\",\"session_id\":\"s-2\",\"event\":\"SessionStart\",\"cwd\":\"$DIRTY\"}"
printf '%s' "$JSON" | python3 "$HOOK" >/dev/null 2>&1; RC=$?
if [[ "$RC" -eq 0 && "$((`raw_count` - BEFORE))" -eq 0 ]]; then ok "non-stop-noop"; else no "non-stop-noop" "rc=$RC delta=$((`raw_count` - BEFORE))"; fi

echo "=== (d) Stop on a CLEAN tree → gated out (no noise) ==="
BEFORE=$(raw_count)
JSON="{\"ai\":\"codex\",\"session_id\":\"s-3\",\"event\":\"Stop\",\"cwd\":\"$CLEAN\"}"
printf '%s' "$JSON" | python3 "$HOOK" >/dev/null 2>&1; RC=$?
if [[ "$RC" -eq 0 && "$((`raw_count` - BEFORE))" -eq 0 ]]; then ok "clean-tree-gated"; else no "clean-tree-gated" "rc=$RC delta=$((`raw_count` - BEFORE))"; fi

echo "=== (e) env-driven path (no stdin, AGENT/AGENT_SESSION_ID) → captures ==="
BEFORE=$(raw_count)
( cd "$DIRTY" && AGENT=gemini AGENT_SESSION_ID="g-1" python3 "$HOOK" </dev/null >/dev/null 2>&1 )
AFTER=$(raw_count)
GEMINI_RAWS=$(find "$BRAIN_DIR/raw/gemini" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$((AFTER - BEFORE))" -eq 1 && "$GEMINI_RAWS" -eq 1 ]]; then ok "env-fallback-captures"; else no "env-fallback-captures" "delta=$((AFTER - BEFORE)) gemini=$GEMINI_RAWS"; fi

echo "=== (f) malformed stdin → fail-open (exit 0), empty stdout, no crash ==="
# Run from the CLEAN tree so the default-Stop path gates out — isolates the
# fail-open behavior from any side effect.
STDOUT=$(cd "$CLEAN" && printf '%s' "{ this is not json" | python3 "$HOOK" 2>/dev/null); RC=$?
if [[ "$RC" -eq 0 && -z "$STDOUT" ]]; then ok "malformed-failopen"; else no "malformed-failopen" "rc=$RC stdout='$STDOUT'"; fi

echo "=== (g) Claude's REAL native Stop shape (hook_event_name, no ai) → raw/claude ==="
# Claude's native payload has no `ai` field and uses `hook_event_name`, not
# `event`. It must still be attributed to claude (not filed under 'unknown').
BEFORE=$(raw_count)
JSON="{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"session_id\":\"c-1\",\"cwd\":\"$DIRTY\"}"
printf '%s' "$JSON" | python3 "$HOOK" >/dev/null 2>&1; RC=$?
CLAUDE_RAWS=$(find "$BRAIN_DIR/raw/claude" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RC" -eq 0 && "$((`raw_count` - BEFORE))" -eq 1 && "$CLAUDE_RAWS" -ge 1 ]]; then
  ok "claude-native-shape-attributed"
else
  no "claude-native-shape-attributed" "rc=$RC delta=$((`raw_count` - BEFORE)) claude=$CLAUDE_RAWS"
fi

echo "=== (h) Claude REAL shape, non-Stop (hook_event_name=SessionStart) → no-op ==="
# The Stop gate must read hook_event_name, not blindly default to Stop.
BEFORE=$(raw_count)
JSON="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"c-2\",\"cwd\":\"$DIRTY\"}"
printf '%s' "$JSON" | python3 "$HOOK" >/dev/null 2>&1; RC=$?
if [[ "$RC" -eq 0 && "$((`raw_count` - BEFORE))" -eq 0 ]]; then
  ok "claude-native-nonstop-noop"
else
  no "claude-native-nonstop-noop" "rc=$RC delta=$((`raw_count` - BEFORE))"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
