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

# run_cb <proj-cwd|-> <extra env assignments...> — fire the hook once for a failing
# Bash event with the live sink env cleared; echoes "rc=<n>". Bounded by a python
# subprocess timeout (macOS has no `timeout`), so a hang is a FAIL, not a stall.
run_cb() {
  local cwd="$1"; shift
  CB_CWD="$cwd" HOOK="${CB_HOOK:-$HOOK}" python3 -c '
import json, os, subprocess, sys
ev = {"ai": "claude-code", "event": "PostToolUse", "session_id": "cb-run",
      "tool_name": "Bash", "tool_input": {"command": "x"},
      "tool_response": {"stdout": "Traceback (most recent call last): run_cb"}}
if os.environ["CB_CWD"] != "-":
    ev["cwd"] = os.environ["CB_CWD"]
env = {k: v for k, v in os.environ.items()
       if k not in ("AGENT_CIRCUIT_BREAKER_SINK", "AGENT_GATE_SINK_DIR", "CLAUDE_PROJECT_DIR")}
env.update(dict(a.split("=", 1) for a in sys.argv[1:]))
try:
    r = subprocess.run([sys.executable, os.environ["HOOK"]], input=json.dumps(ev).encode(),
                       env=env, capture_output=True, timeout=8)
    print("rc=%d out=%d" % (r.returncode, len(r.stdout)))
except subprocess.TimeoutExpired:
    print("rc=HANG out=0")
' "$@"
}
lines() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# Escaping override: a path that is WRITABLE but outside {<root>/.agent/logs, temp
# dir} must be ignored (root-only paths like /etc would pass vacuously for non-root).
CONF="$STATE_DIR/conf"; mkdir -p "$CONF/tmproot" "$CONF/outside" "$CONF/proj"
R=$(run_cb "$CONF/proj" "TMPDIR=$CONF/tmproot" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" \
  "AGENT_CIRCUIT_BREAKER_STATE=$CONF/st.json" "AGENT_CIRCUIT_BREAKER_SINK=$CONF/outside/x.jsonl")
if [[ ! -e "$CONF/outside/x.jsonl" && "$(lines "$CONF/proj/.agent/logs/circuit-breaker.jsonl")" -eq 1 ]]; then
  ok "override-confined" "outside path untouched, default sink got the line ($R)"
else
  bad "override-confined" "outside=$(ls "$CONF/outside") default=$(lines "$CONF/proj/.agent/logs/circuit-breaker.jsonl") $R"
fi

# Symlinked default sink must not be followed out of the project.
SL="$STATE_DIR/sl"; mkdir -p "$SL/proj/.agent/logs"; echo '{"victim":1}' > "$SL/victim.jsonl"
ln -s "$SL/victim.jsonl" "$SL/proj/.agent/logs/circuit-breaker.jsonl"
R=$(run_cb "$SL/proj" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$SL/st.json")
if [[ "$(lines "$SL/victim.jsonl")" -eq 1 && "$R" == "rc=0 out="[1-9]* ]]; then
  ok "symlink-sink-not-followed" "victim file still 1 line, hook ok ($R)"
else
  bad "symlink-sink-not-followed" "victim=$(lines "$SL/victim.jsonl") $R"
fi

# A missing project root is not created (only .agent/logs under an existing root).
GHOST="$STATE_DIR/ghost-root/zzz"
R=$(run_cb "$GHOST" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$STATE_DIR/gh.json")
if [[ ! -e "$STATE_DIR/ghost-root" && "$R" == rc=0* ]]; then
  ok "missing-root-not-created" "no tree made ($R)"
else
  bad "missing-root-not-created" "$(ls -d "$STATE_DIR/ghost-root" 2>&1) $R"
fi

# Deleted process cwd + no event cwd + no CLAUDE_PROJECT_DIR: exit code stays 0.
DEL="$STATE_DIR/deleted-cwd"; mkdir -p "$DEL"
R=$( cd "$DEL" && rmdir "$DEL" && run_cb - "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$STATE_DIR/del.json" )
if [[ "$R" == "rc=0 out="[1-9]* ]]; then ok "deleted-cwd-rc0" "$R"; else bad "deleted-cwd-rc0" "$R"; fi

# FIFO with no reader at the sink path: fail fast (O_NONBLOCK), never hang.
FF="$STATE_DIR/fifo"; mkdir -p "$FF/proj/.agent/logs"; mkfifo "$FF/proj/.agent/logs/circuit-breaker.jsonl"
R=$(run_cb "$FF/proj" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$FF/st.json")
if [[ "$R" == "rc=0 out="[1-9]* ]]; then ok "fifo-sink-no-hang" "$R"; else bad "fifo-sink-no-hang" "$R"; fi

# Regular-file guard: a directory squatting on the default path is skipped silently.
DD="$STATE_DIR/dd"; mkdir -p "$DD/proj/.agent/logs/circuit-breaker.jsonl"
R=$(run_cb "$DD/proj" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$DD/st.json")
if [[ "$R" == "rc=0 out="[1-9]* ]]; then ok "dir-at-default-sink-silent" "$R"; else bad "dir-at-default-sink-silent" "$R"; fi

# AGENT_GATE_SINK_DIR (X-5 seam) redirects the DEFAULT sink directory.
GS="$STATE_DIR/gs"; mkdir -p "$GS/proj" "$GS/diverted"
R=$(run_cb "$GS/proj" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$GS/st.json" \
  "AGENT_GATE_SINK_DIR=$GS/diverted")
if [[ "$(lines "$GS/diverted/circuit-breaker.jsonl")" -eq 1 && ! -e "$GS/proj/.agent" ]]; then
  ok "gate-sink-dir-seam" "diverted, project .agent untouched"
else
  bad "gate-sink-dir-seam" "diverted=$(lines "$GS/diverted/circuit-breaker.jsonl") proj=$(ls -A "$GS/proj") $R"
fi

# Probe used by the lock-order case below and by its mutation probe.
LOCK_PROBE_PY='
import fcntl, io, json, os, runpy, sys
st = os.path.join(os.environ["STATE_DIR"], "lockprobe.json")
os.environ.update(AGENT_CIRCUIT_BREAKER_STATE=st, AGENT_CIRCUIT_BREAKER_THRESHOLD="1")
proj = os.path.join(os.environ["STATE_DIR"], "lockprobe-proj"); os.makedirs(proj, exist_ok=True)
os.environ.pop("AGENT_CIRCUIT_BREAKER_SINK", None); os.environ.pop("AGENT_GATE_SINK_DIR", None)
held = []
real_open = os.open
def spy(path, *a, **k):
    if str(path).endswith("circuit-breaker.jsonl"):
        fh = open(st + ".lock", "a")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB); held.append(False)
        except OSError:
            held.append(True)
        finally:
            fh.close()
    return real_open(path, *a, **k)
import pathlib  # py3.9 pathlib binds os.open at import: do it BEFORE patching
os.open = spy
ev = {"event": "PostToolUse", "tool_name": "Bash", "cwd": proj, "session_id": "lk",
      "tool_response": {"stdout": "Traceback (most recent call last): lock probe"}}
real_out = sys.stdout
sys.stdin = io.StringIO(json.dumps(ev)); sys.stdout = io.StringIO()
runpy.run_path(os.environ["HOOK"], run_name="__main__")
sys.stdout = real_out
print("held" if any(held) else ("free" if held else "no-write"))
'

# Mutation probes for the sink protections: each reverts ONE guard in a COPY of the
# hook and the matching case above must then flip. An anchor miss is a hard FAIL.
sink_probe() {  # sink_probe <name> <find> <repl> <scenario>
  local name="$1" find="$2" repl="$3" scen="$4" m R flipped=0 d
  m=$(mutate "sink-$name" "$find" "$repl")
  if [[ -z "$m" ]]; then bad "mutation/$name-anchor" "anchor not found — probe is inert"; return; fi
  d="$STATE_DIR/mp-$name"; rm -rf "$d"; mkdir -p "$d/tmproot" "$d/outside" "$d/proj/.agent/logs" "$d/diverted"
  case "$scen" in
    override)
      CB_HOOK="$m" run_cb "$d/proj" "TMPDIR=$d/tmproot" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 \
        "AGENT_CIRCUIT_BREAKER_STATE=$d/st.json" "AGENT_CIRCUIT_BREAKER_SINK=$d/outside/x.jsonl" >/dev/null
      [[ -e "$d/outside/x.jsonl" ]] && flipped=1 ;;
    fifo)
      mkfifo "$d/proj/.agent/logs/circuit-breaker.jsonl"
      R=$(CB_HOOK="$m" run_cb "$d/proj" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 "AGENT_CIRCUIT_BREAKER_STATE=$d/st.json")
      [[ "$R" == rc=HANG* ]] && flipped=1 ;;
    seam)
      CB_HOOK="$m" run_cb "$d/proj" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 "AGENT_CIRCUIT_BREAKER_STATE=$d/st.json" \
        "AGENT_GATE_SINK_DIR=$d/diverted" >/dev/null
      [[ ! -e "$d/diverted/circuit-breaker.jsonl" ]] && flipped=1 ;;
    symlink)
      echo '{"victim":1}' > "$d/victim.jsonl"; rm -rf "$d/proj/.agent/logs"; mkdir -p "$d/proj/.agent/logs"
      ln -s "$d/victim.jsonl" "$d/proj/.agent/logs/circuit-breaker.jsonl"
      CB_HOOK="$m" run_cb "$d/proj" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 "AGENT_CIRCUIT_BREAKER_STATE=$d/st.json" >/dev/null
      [[ "$(lines "$d/victim.jsonl")" -gt 1 ]] && flipped=1 ;;
    reader-fifo)
      mkfifo "$d/proj/.agent/logs/circuit-breaker.jsonl"
      exec 4<>"$d/proj/.agent/logs/circuit-breaker.jsonl"
      CB_HOOK="$m" run_cb "$d/proj" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 "AGENT_CIRCUIT_BREAKER_STATE=$d/st.json" >/dev/null
      local got=""; read -r -t 1 -u 4 got || true; exec 4>&-
      [[ -n "$got" ]] && flipped=1 ;;
    parent-symlink)
      rm -rf "$d/proj/.agent"; mkdir -p "$d/outside/logs"; ln -s "$d/outside" "$d/proj/.agent"
      CB_HOOK="$m" run_cb "$d/proj" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 "AGENT_CIRCUIT_BREAKER_STATE=$d/st.json" >/dev/null
      [[ -e "$d/outside/logs/circuit-breaker.jsonl" ]] && flipped=1 ;;
    lock-held)
      local lk
      lk=$(HOOK="$m" STATE_DIR="$d" python3 -c "$LOCK_PROBE_PY" 2>&1 | tail -1)
      [[ "$lk" == held ]] && flipped=1 ;;
    ghost)
      CB_HOOK="$m" run_cb "$d/ghost/zzz" AGENT_CIRCUIT_BREAKER_THRESHOLD=1 "AGENT_CIRCUIT_BREAKER_STATE=$d/st.json" >/dev/null
      [[ -e "$d/ghost" ]] && flipped=1 ;;
  esac
  if [[ $flipped -eq 1 ]]; then ok "mutation/$name" "reverting it breaks the protection"; else bad "mutation/$name" "mutant behaves the same — case does not cover it"; fi
}
sink_probe confinement 'if candidate == base or candidate.startswith(base + os.sep):' 'if True:' override
sink_probe nonblock '| getattr(os, "O_NONBLOCK", 0)' '' fifo
sink_probe gate-sink-dir 'os.environ.get("AGENT_GATE_SINK_DIR") or ' '' seam
sink_probe nofollow '| getattr(os, "O_NOFOLLOW", 0)' '' symlink
sink_probe isreg 'if not stat.S_ISREG(os.fstat(fd).st_mode):' 'if False:' reader-fifo
sink_probe parent-symlink 'if os.path.lexists(p) and os.path.realpath(p) != want:' 'if False:' parent-symlink
sink_probe lock-order '        main()
    flush_pending()' '        main()
        flush_pending()' lock-held
sink_probe root-exists 'if not os.path.isdir(root):' 'if False:' ghost

# S_ISREG guard: an open that SUCCEEDS on a non-regular file. A FIFO with a reader
# attached opens fine, so only the fstat check keeps the record out of it.
RF="$STATE_DIR/reader-fifo"; mkdir -p "$RF/proj/.agent/logs"; mkfifo "$RF/proj/.agent/logs/circuit-breaker.jsonl"
exec 3<>"$RF/proj/.agent/logs/circuit-breaker.jsonl"
R=$(run_cb "$RF/proj" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$RF/st.json")
LINE=""; read -r -t 1 -u 3 LINE || true
exec 3>&-
if [[ -z "$LINE" && "$R" == "rc=0 out="[1-9]* ]]; then ok "nonregular-sink-not-written" "FIFO with reader got nothing ($R)"; else bad "nonregular-sink-not-written" "line=${LINE:0:60} $R"; fi

# Intermediate symlinks: <root>/.agent or <root>/.agent/logs pointing outside the root.
for variant in agent-dir logs-dir inroot-agent inroot-logs; do
  IS_CHECK=; IS="$STATE_DIR/is-$variant"; mkdir -p "$IS/proj" "$IS/outside/logs"
  case "$variant" in
    agent-dir)    ln -s "$IS/outside" "$IS/proj/.agent" ;;
    logs-dir)     mkdir -p "$IS/proj/.agent"; ln -s "$IS/outside/logs" "$IS/proj/.agent/logs" ;;
    # a link that stays INSIDE the root is skipped too: the check is "any symlink"
    inroot-agent) mkdir -p "$IS/proj/store/logs"; ln -s store "$IS/proj/.agent"; IS_CHECK="$IS/proj/store/logs" ;;
    inroot-logs)  mkdir -p "$IS/proj/.agent" "$IS/proj/shared"; ln -s ../shared "$IS/proj/.agent/logs"; IS_CHECK="$IS/proj/shared" ;;
  esac
  R=$(run_cb "$IS/proj" "AGENT_CIRCUIT_BREAKER_THRESHOLD=1" "AGENT_CIRCUIT_BREAKER_STATE=$IS/st.json")
  if [[ ! -e "$IS/outside/logs/circuit-breaker.jsonl" && ! -e "${IS_CHECK:-$IS/outside}/circuit-breaker.jsonl" \
        && "$R" == "rc=0 out="[1-9]* ]]; then
    ok "symlinked-parent-$variant" "nothing written through the link ($R)"
  else
    bad "symlinked-parent-$variant" "$(ls -R "$IS/outside" 2>&1 | head -3) $R"
  fi
done

# The sink write happens AFTER the machine-wide state lock is released: probe the
# lock from the moment the hook opens the sink.
LK=$(HOOK="$HOOK" STATE_DIR="$STATE_DIR" python3 -c "$LOCK_PROBE_PY" 2>&1 | tail -1)
if [[ "$LK" == free ]]; then ok "sink-written-outside-state-lock" "lock was free when the sink opened"; else bad "sink-written-outside-state-lock" "$LK"; fi

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
