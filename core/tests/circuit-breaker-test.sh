#!/usr/bin/env bash
# circuit-breaker-test.sh — verify core/hooks/circuit-breaker.py failure classification.
#
# Feeds canonical PostToolUse event JSON (Bash tool_response) to the hook via
# stdin and asserts whether the event is classified as a failure. With
# AGENT_CIRCUIT_BREAKER_THRESHOLD=1 a single classified failure fires the
# advisory, so non-empty stdout == "classified as failure" and empty stdout ==
# "classified as clean". That makes single-event classification observable.
#
# WHY this battery exists: the hook shipped with an `or`-chained exit-status
# lookup (`result.get("exit_code") or result.get("exitCode")`) which discards a
# successful `0` as falsy and falls through to a substring text heuristic, so a
# passing command whose output merely contains "error" was counted as a failure.
# The hook had no battery at all — the one untested hook in core/hooks — which
# is exactly why the defect survived.
#
# GROUPING MATTERS (anti-vacuous): group A uses the shape Claude Code actually
# sends and is load-bearing; group B uses payloads that carry an exit status,
# which THIS runtime does not send today (measured 2026-07-30 — see the hook
# docstring) and is therefore explicitly labelled forward-compatibility. Testing
# only group B would be green-by-construction: every assertion would pass over
# an input shape production never produces.
#
# Usage: bash core/tests/circuit-breaker-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/circuit-breaker.py"

STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/circuit-breaker-test.XXXXXX")"
trap 'rm -rf "$STATE_DIR"' EXIT

# Every case fires the hook, which now appends to a jsonl sink (X-3). Point it at
# the scratch dir for the whole battery so no case can write a real .agent/logs
# (the fixture cwd is /tmp) — section F asserts that isolation holds.
export AGENT_CIRCUIT_BREAKER_SINK="$STATE_DIR/sink-default.jsonl"
export AGENT_REPRODUCE_TEST=1

PASS=0
FAIL=0
CASE_N=0

ok()   { echo "  ok   [$1] $2"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# ev_text <text> — live Claude Code shape: stdout/stderr only, NO exit status.
ev_text() {
  T="$1" python3 -c '
import os, json
print(json.dumps({
    "ai": "claude-code", "event": "PostToolUse", "session_id": "cb-test",
    "tool_name": "Bash", "tool_input": {"command": "probe"},
    "tool_response": {"stdout": os.environ["T"], "stderr": ""},
    "cwd": "/tmp",
}))'
}

# ev_exit <key> <json-value> <text> — payload that DOES carry an exit status.
# The value is parsed as JSON so `0` stays an int and `"1"` stays a string.
ev_exit() {
  K="$1" V="$2" T="$3" python3 -c '
import os, json
resp = {os.environ["K"]: json.loads(os.environ["V"]),
        "stdout": os.environ["T"], "stderr": ""}
print(json.dumps({
    "ai": "claude-code", "event": "PostToolUse", "session_id": "cb-test",
    "tool_name": "Bash", "tool_input": {"command": "probe"},
    "tool_response": resp, "cwd": "/tmp",
}))'
}

# classify <event-json> [hook-path] — echo "error" or "clean"
classify() {
  local event="$1" hook="${2:-$HOOK}" state out
  CASE_N=$((CASE_N + 1))
  state="$STATE_DIR/state-$CASE_N.json"
  out=$(printf '%s' "$event" \
    | AGENT_CIRCUIT_BREAKER_STATE="$state" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 \
      python3 "$hook" 2>/dev/null || true)
  [[ -n "$out" ]] && echo "error" || echo "clean"
}

# expect <name> <event-json> <error|clean>
expect() {
  local name="$1" event="$2" want="$3" got
  got=$(classify "$event")
  if [[ "$got" == "$want" ]]; then
    ok "$name" "want=$want"
  else
    bad "$name" "want=$want got=$got"
  fi
}

echo "=== A. live Claude Code shape (no exit status) — load-bearing ==="
expect "zero-count-errors-clean"    "$(ev_text 'test suite complete: 0 errors')"        clean
expect "no-errors-found-clean"      "$(ev_text 'lint finished, no errors found')"       clean
expect "errors-colon-zero-clean"    "$(ev_text 'summary -- errors: 0, warnings: 2')"    clean
expect "zero-failures-clean"        "$(ev_text '12 passed, 0 failed')"                  clean
expect "benign-output-clean"        "$(ev_text '3 files changed, 47 insertions(+)')"     clean
expect "traceback-error"            "$(ev_text 'Traceback (most recent call last):')"    error
expect "pytest-failed-error"        "$(ev_text 'FAILED tests/test_x.py::test_y')"        error
expect "command-not-found-error"    "$(ev_text 'bash: fooo: command not found')"         error
expect "git-error-prefix-error"     "$(ev_text "error: pathspec 'x' did not match")"     error
expect "mixed-nonzero-count-error"  "$(ev_text '0 warnings, 2 errors')"                  error

echo
echo "=== B. forward-compat: runtime that DOES supply an exit status ==="
echo "    (not sent by Claude Code today — see hook docstring, measured 2026-07-30)"
expect "exit0-with-error-word-clean"  "$(ev_exit exit_code 0 'npm WARN deprecated; error')" clean
expect "exitCode0-camel-clean"        "$(ev_exit exitCode 0 'error in log tail')"           clean
expect "exit0-quiet-clean"            "$(ev_exit exit_code 0 'quiet')"                      clean
expect "exit1-despite-success-words"  "$(ev_exit exit_code 1 'all tests passed')"           error
expect "exit-string-1-error"          "$(ev_exit exit_code '"1"' 'quiet')"                  error
expect "exit-status-overrides-text"   "$(ev_exit exit_code 0 'Traceback (most recent call last):')" clean

echo
echo "=== C. protocol contract: pass-through writes zero bytes, always exit 0 ==="
NON_BASH=$(python3 -c '
import json
print(json.dumps({"ai": "claude-code", "event": "PostToolUse", "session_id": "cb-test",
                  "tool_name": "Read", "tool_input": {"file_path": "/tmp/x"},
                  "tool_response": {"stdout": "Traceback (most recent call last):"},
                  "cwd": "/tmp"}))')
OUT=$(printf '%s' "$NON_BASH" | AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/nb.json" \
  AGENT_CIRCUIT_BREAKER_THRESHOLD=1 python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  ok "non-bash-tool-ignored" "zero bytes, rc=0"
else
  bad "non-bash-tool-ignored" "rc=$RC out=$OUT"
fi

OUT=$(printf '' | AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/e.json" python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  ok "empty-stdin-failsafe" "zero bytes, rc=0"
else
  bad "empty-stdin-failsafe" "rc=$RC out=$OUT"
fi

OUT=$(printf 'not json' | AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/m.json" python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  ok "malformed-stdin-failsafe" "zero bytes, rc=0"
else
  bad "malformed-stdin-failsafe" "rc=$RC out=$OUT"
fi

NO_RESP=$(python3 -c '
import json
print(json.dumps({"ai": "claude-code", "event": "PostToolUse", "session_id": "cb-test",
                  "tool_name": "Bash", "tool_input": {"command": "probe"}, "cwd": "/tmp"}))')
OUT=$(printf '%s' "$NO_RESP" | AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/nr.json" \
  AGENT_CIRCUIT_BREAKER_THRESHOLD=1 python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  ok "missing-tool-response-failsafe" "zero bytes, rc=0"
else
  bad "missing-tool-response-failsafe" "rc=$RC out=$OUT"
fi

echo
echo "=== D. threshold + window behaviour (pre-existing contract, preserved) ==="
SEQ_STATE="$STATE_DIR/seq-same.json"; rm -f "$SEQ_STATE"
SAME=$(ev_text 'Traceback (most recent call last): boom in handler')
LAST=""
for _ in 1 2 3; do
  LAST=$(printf '%s' "$SAME" | AGENT_CIRCUIT_BREAKER_STATE="$SEQ_STATE" python3 "$HOOK" 2>/dev/null || true)
done
if [[ "$LAST" == *"same error repeated"* ]]; then
  ok "same-signature-x3-fires" "repeat wording"
else
  bad "same-signature-x3-fires" "got: $LAST"
fi

SEQ_STATE="$STATE_DIR/seq-diff.json"; rm -f "$SEQ_STATE"
LAST=""
for msg in 'Traceback (most recent call last): alpha failure here' \
           'bash: bravo: command not found in this shell' \
           "error: pathspec 'charlie' did not match any file"; do
  LAST=$(printf '%s' "$(ev_text "$msg")" | AGENT_CIRCUIT_BREAKER_STATE="$SEQ_STATE" \
    python3 "$HOOK" 2>/dev/null || true)
done
if [[ "$LAST" == *"Multiple failures detected"* ]]; then
  ok "distinct-signatures-x3-fires" "multiple-failures wording"
else
  bad "distinct-signatures-x3-fires" "got: $LAST"
fi

SEQ_STATE="$STATE_DIR/seq-window.json"
python3 -c '
import json, os, time
old = time.time() - 600
json.dump([{"ts": old, "sig": "stale one"}, {"ts": old, "sig": "stale two"}],
          open(os.environ["S"], "w"))' S="$SEQ_STATE" 2>/dev/null || true
OUT=$(printf '%s' "$SAME" | AGENT_CIRCUIT_BREAKER_STATE="$SEQ_STATE" python3 "$HOOK" 2>/dev/null || true)
if [[ -z "$OUT" ]]; then
  ok "stale-records-expire" "beyond window, no fire on 1 fresh failure"
else
  bad "stale-records-expire" "fired on stale state: $OUT"
fi

echo
echo "=== E. mutation probes — the fix must be load-bearing, not decorative ==="
# Each probe reverts ONE property of the fix in a COPY of the hook and asserts
# the classification flips. A literal-substring replace that finds no anchor is
# a hard FAIL, so a later refactor cannot silently turn a probe into a no-op.
mutate() {  # mutate <name> <find> <replace> -> echoes mutant path, or "" on miss
  # NOTE: declared on separate lines on purpose — a same-line `local out=...$name`
  # self-reference is unbound under bash 3.2 + set -u (the exact crash the
  # supervisor-goal.sh cmd_init fix removed).
  local name="$1" find="$2" repl="$3"
  local out="$STATE_DIR/mutant-$name.py"
  if FIND="$find" REPL="$repl" SRC="$HOOK" DST="$out" python3 -c '
import os, sys
src = open(os.environ["SRC"], encoding="utf-8").read()
find, repl = os.environ["FIND"], os.environ["REPL"]
if find not in src:
    sys.exit(1)
open(os.environ["DST"], "w", encoding="utf-8").write(src.replace(find, repl, 1))
'; then
    echo "$out"
  else
    echo ""
  fi
}

M1=$(mutate falsy-zero 'if key in result:' 'if result.get(key):')
if [[ -z "$M1" ]]; then
  bad "mutation/falsy-zero-anchor" "anchor 'if key in result:' not found — probe is inert"
else
  ok "mutation/falsy-zero-anchor" "anchor present"
  GOT=$(classify "$(ev_exit exit_code 0 'npm WARN deprecated; error')" "$M1")
  if [[ "$GOT" == "error" ]]; then
    ok "mutation/falsy-zero-detected" "reverting key-presence check flips exit-0 to failure"
  else
    bad "mutation/falsy-zero-detected" "mutant still clean — battery does not cover the fix"
  fi
fi

M2=$(mutate zero-count '_ZERO_COUNT_RE.sub(" ", head)' 'head')
if [[ -z "$M2" ]]; then
  bad "mutation/zero-count-anchor" "anchor '_ZERO_COUNT_RE.sub' not found — probe is inert"
else
  ok "mutation/zero-count-anchor" "anchor present"
  GOT=$(classify "$(ev_text 'test suite complete: 0 errors')" "$M2")
  if [[ "$GOT" == "error" ]]; then
    ok "mutation/zero-count-detected" "removing the zero-count scrub flips '0 errors' to failure"
  else
    bad "mutation/zero-count-detected" "mutant still clean — battery does not cover the scrub"
  fi
fi

echo
echo "=== E. concurrent failures do not lose updates (state lock) ==="
PAR_STATE="$STATE_DIR/par.json"; rm -f "$PAR_STATE"
for i in $(seq 1 20); do
  printf '%s' "$(ev_text "Traceback: parallel failure $i")" \
    | AGENT_CIRCUIT_BREAKER_STATE="$PAR_STATE" AGENT_CIRCUIT_BREAKER_THRESHOLD=100 \
      python3 "$HOOK" >/dev/null 2>&1 &
done
wait
N=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$PAR_STATE" 2>/dev/null || echo 0)
if [[ "$N" -eq 20 ]]; then ok "parallel-20-failures-all-recorded" "n=$N"; else bad "parallel-lost-update" "n=$N (want 20)"; fi

echo
echo "=== F. firing sink (X-3) + pollution isolation ==="
SINK="$STATE_DIR/sink-f.jsonl"; FSTATE="$STATE_DIR/f-state.json"; rm -f "$SINK" "$FSTATE"
FEV=$(ev_text 'Traceback (most recent call last): sink probe failure')
OUT=$(printf '%s' "$FEV" | AGENT_CIRCUIT_BREAKER_SINK="$SINK" AGENT_CIRCUIT_BREAKER_STATE="$FSTATE" \
  AGENT_CIRCUIT_BREAKER_THRESHOLD=1 python3 "$HOOK" 2>/dev/null)
if [[ -n "$OUT" ]] && [[ "$(wc -l < "$SINK" 2>/dev/null || echo 0)" -eq 1 ]]; then
  ok "fire-writes-one-sink-line" "stdout non-empty, 1 jsonl line"
else
  bad "fire-writes-one-sink-line" "out=${OUT:0:40} sink=$(cat "$SINK" 2>/dev/null)"
fi
if SINK="$SINK" python3 -c '
import json, os
r = json.loads(open(os.environ["SINK"]).readline())
assert r["guard"] == "circuit-breaker" and r["hook"] == "circuit-breaker.py", r
assert r["decision"] == "advise" and r["session_id"] == "cb-test", r
assert r["signal"] == "text" and r["kind"] in ("repeat", "multi"), r
assert r["reproduce_test"] is True and r["origin"] == "session", r
assert "ts" in r and "sig_sha" in r and "Traceback" not in json.dumps(r), r
' 2>/dev/null; then
  ok "sink-record-fields" "guard/hook/decision/session_id/signal/reproduce_test, no raw text"
else
  bad "sink-record-fields" "$(cat "$SINK" 2>/dev/null)"
fi

# Below threshold = no fire = no sink line.
Q_SINK="$STATE_DIR/sink-quiet.jsonl"; rm -f "$Q_SINK" "$STATE_DIR/q-state.json"
printf '%s' "$FEV" | AGENT_CIRCUIT_BREAKER_SINK="$Q_SINK" AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/q-state.json" \
  AGENT_CIRCUIT_BREAKER_THRESHOLD=3 python3 "$HOOK" >/dev/null 2>&1
if [[ ! -s "$Q_SINK" ]]; then ok "no-fire-no-sink-line" "sink empty"; else bad "no-fire-no-sink-line" "$(cat "$Q_SINK")"; fi

# Sink failure must not change behaviour: a directory squatting on the sink path.
D_SINK="$STATE_DIR/sink-is-a-dir"; mkdir -p "$D_SINK"
OUT=$(printf '%s' "$FEV" | AGENT_CIRCUIT_BREAKER_SINK="$D_SINK" AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/d-state.json" \
  AGENT_CIRCUIT_BREAKER_THRESHOLD=1 python3 "$HOOK" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && "$OUT" == *"Circuit Breaker"* ]]; then
  ok "sink-failure-is-silent" "rc=0, advisory still emitted"
else
  bad "sink-failure-is-silent" "rc=$RC out=$OUT"
fi

# The record is out-of-band: advisory text carries none of the measurement fields.
if [[ "$OUT" != *sig_sha* && "$OUT" != *reproduce_test* && "$OUT" != *'"guard"'* ]]; then
  ok "advisory-carries-no-label" "no sink fields in additionalContext"
else
  bad "advisory-carries-no-label" "$OUT"
fi

# Pollution: no env override, event cwd = a scratch project -> default
# <cwd>/.agent/logs/circuit-breaker.jsonl, never the real repo's logs.
PROJ="$STATE_DIR/proj"; mkdir -p "$PROJ"
REAL_BEFORE=$(cat "$REPO_ROOT/.agent/logs/circuit-breaker.jsonl" 2>/dev/null | wc -l)
PEV=$(PROJ="$PROJ" python3 -c '
import os, json
print(json.dumps({"ai": "claude-code", "event": "PostToolUse", "session_id": "cb-proj",
    "tool_name": "Bash", "tool_input": {"command": "x"},
    "tool_response": {"stdout": "Traceback (most recent call last): proj"},
    "cwd": os.environ["PROJ"]}))')
printf '%s' "$PEV" | env -u AGENT_CIRCUIT_BREAKER_SINK -u AGENT_GATE_SINK_DIR AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/p-state.json" \
  AGENT_CIRCUIT_BREAKER_THRESHOLD=1 python3 "$HOOK" >/dev/null 2>&1
REAL_AFTER=$(cat "$REPO_ROOT/.agent/logs/circuit-breaker.jsonl" 2>/dev/null | wc -l)
if [[ -s "$PROJ/.agent/logs/circuit-breaker.jsonl" && "$REAL_BEFORE" -eq "$REAL_AFTER" ]]; then
  ok "default-sink-is-project-local" "wrote $PROJ/.agent/logs, repo logs untouched"
else
  bad "default-sink-is-project-local" "proj=$(ls "$PROJ/.agent/logs" 2>&1) real $REAL_BEFORE->$REAL_AFTER"
fi

# Escaping override falls back to the project default instead of writing elsewhere.
EVIL="$STATE_DIR/../circuit-breaker-evil-$$.jsonl"
printf '%s' "$PEV" | AGENT_CIRCUIT_BREAKER_SINK="/etc/cb-evil-$$.jsonl" AGENT_CIRCUIT_BREAKER_STATE="$STATE_DIR/e2-state.json" \
  AGENT_CIRCUIT_BREAKER_THRESHOLD=1 python3 "$HOOK" >/dev/null 2>&1
if [[ ! -e "/etc/cb-evil-$$.jsonl" && ! -e "$EVIL" ]]; then ok "override-confined" "escaping sink path not written"; else bad "override-confined" "wrote outside allowed roots"; rm -f "/etc/cb-evil-$$.jsonl"; fi

# Registry row is readable by the digest and counts the sink.
DIGEST="$REPO_ROOT/core/infra/telemetry-digest.sh"
GL="$STATE_DIR/gl"; mkdir -p "$GL"
python3 -c '
import json, sys, datetime
print(json.dumps({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), "guard": "circuit-breaker",
  "hook": "circuit-breaker.py", "decision": "advise", "origin": "session"}))' > "$GL/circuit-breaker.jsonl"
DOUT=$(bash "$DIGEST" --gates --logs-dir "$GL" 2>&1 || true)
if printf '%s' "$DOUT" | grep -E '^ *circuit-breaker' | grep -qv 'UNINSTRUMENTED\|DEAD'; then
  ok "digest-reads-registry-row" "$(printf '%s' "$DOUT" | grep -E '^ *circuit-breaker' | head -1)"
else
  bad "digest-reads-registry-row" "$(printf '%s' "$DOUT" | grep -i circuit | head -3)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
