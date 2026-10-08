#!/usr/bin/env bash
# antigravity-adapter-test.sh — W5-3: Antigravity CLI (agy) native hook adapter.
#
# agy (1.2.12, measured 2026-09-29, .agent/plans/runtime-currency-2026-09/w5-design.md)
# runs plugin hooks with a camelCase stdin that carries NO event name, so the event
# comes from argv. Three measured properties make a naive pass-through unsafe and
# this battery pins each:
#
#   1. PreToolUse stdout `{}` is a DENY; `allow` is never emitted (its grant semantics are
#      unmeasured). The only pass-through is `{"decision":"ask"}`, which agy resolves with its
#      own permission rules — so a core-hook `ask` (a guard demanding a human) is emitted as
#      `force_ask`, which agy documents as ignoring allow rules / Always-Allow caches.
#   2. A hook that crashes / times out / prints garbage is not known to be
#      fail-closed on agy's side, so the adapter turns every PreToolUse failure
#      into an explicit deny (PostToolUse/Stop stay fail-open).
#   3. multi_replace_file_content carries N edits in one call; each becomes its own
#      canonical Edit so a secret in ANY chunk is seen.
#
# Also: canonical translation (cwd from Cwd/workspacePaths, normalized paths),
# PostToolUseFailure routing, the Stop continue-once loop guard, worker mode, the
# API-key env scrub, and a drift guard against the Codex hook template.
#
# Never runs agy: agy-native stdin fixtures are piped into adapter.sh, external
# state lives in a scratch HOME / state dir.
#
# Usage: bash core/tests/antigravity-adapter-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_ADAPTER="$REPO_ROOT/adapters/antigravity/adapter.sh"
TEMPLATE="$REPO_ROOT/adapters/codex/hooks.json.template"

PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agy-adapter.XXXXXX")"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT
# X-5: keep this battery's gate records out of the live .agent/logs sink (caller-set seam wins)
export AGENT_GATE_SINK_DIR="${AGENT_GATE_SINK_DIR:-$WORK/gate-sink}"

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# Scratch world: nothing below may touch the real ~/.gemini, ~/.agent or brain.
export HOME="$WORK/home"
export AGENT_STATE_DIR="$WORK/state"
export AGENT_BRAIN_DIR="$WORK/brain"
export AGENT_REPRODUCE_TEST=1
export AGENT_CIRCUIT_BREAKER_STATE="$WORK/cb-state.json"
export AGENT_VERIFY_OBSERVED_SINK="$WORK/verify-observed.jsonl"
export AGENT_HARDCODING_SINK="$WORK/hardcoding.jsonl"
unset AGENT_ANTIGRAVITY_WORKER AGENT_ANTIGRAVITY_BUDGET_S GEMINI_API_KEY GOOGLE_API_KEY
PROJ="$WORK/proj"          # the user's workspace
PLUGIN="$WORK/plugin"      # agy starts hooks inside the plugin dir
mkdir -p "$HOME" "$PROJ" "$PLUGIN" "$PROJ/src"
: > "$WORK/transcript_full.jsonl"

# --- fixtures ---------------------------------------------------------------

# mk <tool-name> <args-json> [extra-json-merged-into-the-envelope]
# Shaped exactly like the measured payloads (M3): camelCase keys, toolCall{name,args},
# extra toolAction/toolSummary inside args.
mk() {
    _N="$1" _A="$2" _X="${3:-}" _P="$PROJ" _T="$WORK/transcript_full.jsonl" python3 -c '
import json, os
args = json.loads(os.environ["_A"])
args.setdefault("toolAction", "Running command")
args.setdefault("toolSummary", "test summary")
env = {"toolCall": {"name": os.environ["_N"], "args": args}, "stepIdx": 3,
       "conversationId": "conv-1234", "workspacePaths": [os.environ["_P"]],
       "transcriptPath": os.environ["_T"], "artifactDirectoryPath": "/tmp/art", "modelName": "test-model"}
env.update(json.loads(os.environ.get("_X") or "{}"))
print(json.dumps(env))'
}
# J key=value ... -> flat JSON object of strings
J() { python3 -c 'import json,sys; print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:])))' "$@"; }
# stop_in [extra-json] -> Stop stdin (executionNum/terminationReason/fullyIdle/error per M3)
stop_in() {
    _X="${1:-}" _P="$PROJ" _T="$WORK/transcript_full.jsonl" python3 -c '
import json, os
env = {"conversationId": "conv-1234", "workspacePaths": [os.environ["_P"]], "transcriptPath": os.environ["_T"],
       "executionNum": 0, "terminationReason": "NO_TOOL_CALL", "fullyIdle": True, "error": ""}
env.update(json.loads(os.environ.get("_X") or "{}"))
print(json.dumps(env))'
}

# Runtime-assembled secret-read fixture (no literal pattern in this source).
Z=""
SECRET_LINE="x = op${Z}en(\"secr${Z}ets/api.key\").read()"

AD="$REAL_ADAPTER"
# agy <Event> <stdin> -> stdout in $OUT, stderr in $ERR_FILE, exit in $RC.
# Runs from the plugin dir, like agy does (the adapter must not use that as cwd).
ERR_FILE="$WORK/stderr.txt"
OUT="" RC=0
agy() {
    OUT=$(printf '%s' "$2" | (cd "$PLUGIN" && bash "$AD" "$1" 2>"$ERR_FILE")); RC=$?
}
dec()    { printf '%s' "$1" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("MALFORMED"); sys.exit()
print(d.get("decision", "MALFORMED") if isinstance(d, dict) else "MALFORMED")'; }
reason() { printf '%s' "$1" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("reason", ""))' 2>/dev/null; }

# pre_expect <label> <want> <stdin> [reason-substring]
# Also asserts the PreToolUse invariants on EVERY run: exit 0, one JSON object with
# a decision that is deny, ask or force_ask (`{}` is DENY-by-accident on agy, `allow` is never emitted).
pre_expect() {
    local label="$1" want="$2" input="$3" needle="${4:-}" got
    agy PreToolUse "$input"
    got=$(dec "$OUT")
    if [[ "$got" == "$want" && $RC -eq 0 ]]; then ok "$label"; else bad "$label" "want $want rc=0, got $got rc=$RC :: ${OUT:0:200}"; fi
    if [[ "$got" != deny && "$got" != ask && "$got" != force_ask ]]; then bad "$label/never-empty-or-allow" "decision=$got :: ${OUT:0:120}"; fi
    # here-string, not a pipe: `grep -q` exiting early under pipefail made this check flaky (EPIPE)
    if [[ -n "$needle" ]] && ! grep -qi -- "$needle" <<<"$(reason "$OUT")"; then
        bad "$label/reason" "reason lacks '$needle' :: ${OUT:0:240}"
    fi
}

# --- fake framework: stub core hooks that record what they receive ---------------
FW="$WORK/fw"
STUBS="core/hooks"
UNION="pre-tool-guard.sh loop-write-guard.py r4-mutex-check.sh check-hardcoding.py secret-content-scan.py
r4-file-mutex-check.sh tdd-guard.py spec-gate.py circuit-breaker.py verify-observer.py
r4-file-mutex-register.sh session-quality-gate.py brain-capture.py session-close.sh"
fake_fw() {
    rm -rf "$FW"
    mkdir -p "$FW/adapters/antigravity" "$FW/$STUBS/.mode"
    cp "$REPO_ROOT/adapters/antigravity/adapter.py" "$REPO_ROOT/adapters/antigravity/adapter.sh" "$FW/adapters/antigravity/"
    cat > "$FW/stub.sh" <<'SH'
#!/usr/bin/env bash
name="$(basename "$0")"
mode="$(cat "$(dirname "$0")/.mode/$name" 2>/dev/null || echo silent)"
input="$(cat)"
printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$PWD" "${GEMINI_API_KEY-UNSET}" "${GOOGLE_API_KEY-UNSET}" \
    "$(printf '%s' "$input" | tr -d '\n')" >> "${DUMP_FILE:-/dev/null}"
case "$mode" in
    silent)   ;;
    deny)     printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub says no (café)"}}' ;;
    ask)      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"stub wants approval"}}' ;;
    allow)    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"stub ok"}}' ;;
    advisory) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"stub advisory note"}}' ;;
    crash)    exit 1 ;;
    exit2)    echo "blocked by stub" >&2; exit 2 ;;
    junk)     echo "not json" ;;
    odd)      printf '%s\n' '{"hookSpecificOutput":{"permissionDecision":"defer"}}' ;;
    block)    printf '%s\n' '{"decision":"block","reason":"finish the tests first"}' ;;
    noisy)    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"leak me not"}}' ;;
    slow)     sleep 3 ;;
    hang)     exec sleep 30 ;;
esac
exit 0
SH
    chmod +x "$FW/stub.sh"
    local h
    for h in $UNION; do cp "$FW/stub.sh" "$FW/$STUBS/$h"; done
    AD="$FW/adapters/antigravity/adapter.sh"
    export DUMP_FILE="$WORK/dump.tsv"; : > "$DUMP_FILE"
}
setmode() { printf '%s' "$2" > "$FW/$STUBS/.mode/$1"; }
# dump_check <label> <python-assertions over rows[(hook,pwd,gemini,google,event-dict)]>
dump_check() {
    local label="$1" code="$2"
    if _C="$code" python3 - "$DUMP_FILE" <<'PY'
import json, os, sys
rows = []
for line in open(sys.argv[1]):
    if line.strip():
        h, pwd, gem, goo, ev = line.rstrip("\n").split("\t", 4)
        rows.append({"hook": h, "pwd": pwd, "gemini": gem, "google": goo, "ev": json.loads(ev) if ev else {}})
exec(os.environ["_C"])
PY
    then ok "$label"; else bad "$label" "$(head -c 500 "$DUMP_FILE")"; fi
}

echo "=== 1. Real core hooks: PreToolUse decisions ==="
pre_expect "bash-rm-rf-root-deny" deny "$(mk run_command "$(J CommandLine="rm -rf /" Cwd="$PROJ" WaitMsBeforeAsync=500)")"
pre_expect "bash-secret-read-deny" deny "$(mk run_command "$(J CommandLine="cat secrets/foo.env" Cwd="$PROJ")")"
# `ask` from a core hook becomes force_ask: bare `ask` would let a permissions.allow rule
# (e.g. command(git commit)) satisfy the guard without a prompt. Codex, which cannot prompt, denies it.
pre_expect "bash-no-verify-force-ask" force_ask "$(mk run_command "$(J CommandLine="git commit --no-verify -m x" Cwd="$PROJ")")" "no-verify"
agy PreToolUse "$(mk run_command "$(J CommandLine="ls -la" Cwd="$PROJ")")"
if [[ "$OUT" == '{"decision":"ask"}' || "$(printf '%s' "$OUT" | python3 -c 'import sys,json; print(sorted(json.load(sys.stdin)))')" == "['decision']" ]] \
   && [[ "$(dec "$OUT")" == ask ]]; then ok "bash-benign-passthrough-is-bare-ask"; else bad "bash-benign-passthrough-is-bare-ask" "${OUT:0:200}"; fi
pre_expect "write-secret-deny" deny "$(mk write_to_file "$(J TargetFile="$PROJ/app.py" CodeContent="$SECRET_LINE
" Overwrite=true Description=d)")"
pre_expect "write-clean-not-deny" ask "$(mk write_to_file "$(J TargetFile="$PROJ/notes.md" CodeContent="# hello
" Overwrite=true Description=d)")"
pre_expect "edit-secret-deny" deny "$(mk replace_file_content "$(J TargetFile="$PROJ/src/a.py" TargetContent="x = 1" ReplacementContent="$SECRET_LINE" StartLine=1 EndLine=1 AllowMultiple=false Instruction=i Description=d)")"
pre_expect "edit-clean-not-deny" ask "$(mk replace_file_content "$(J TargetFile="$PROJ/src/a.md" TargetContent="x" ReplacementContent="y" Instruction=i Description=d)")"

echo "=== 2. multi_replace_file_content split per chunk ==="
multi() { # multi <chunk-json-list> -> stdin
    _CH="$1" _F="$PROJ/src/m.py" python3 -c '
import json, os
print(json.dumps({"TargetFile": os.environ["_F"], "ReplacementChunks": json.loads(os.environ["_CH"]),
                  "toolAction": "Editing", "toolSummary": "s", "Instruction": "i"}))'
}
CLEAN_CHUNKS='[{"StartLine":1,"EndLine":1,"TargetContent":"a","ReplacementContent":"b"},{"StartLine":5,"EndLine":5,"TargetContent":"c","ReplacementContent":"d"}]'
BAD_CHUNKS=$(_S="$SECRET_LINE" python3 -c 'import json,os; print(json.dumps([
  {"StartLine":1,"EndLine":1,"TargetContent":"a","ReplacementContent":"b"},
  {"StartLine":5,"EndLine":5,"TargetContent":"c","ReplacementContent":os.environ["_S"]}]))')
pre_expect "multi-clean-not-deny"        ask  "$(mk multi_replace_file_content "$(multi "$CLEAN_CHUNKS")")"
pre_expect "multi-one-bad-chunk-deny"    deny "$(mk multi_replace_file_content "$(multi "$BAD_CHUNKS")")"
pre_expect "multi-unknown-chunk-shape-deny" deny \
    "$(mk multi_replace_file_content "$(multi '[{"StartLine":1,"TargetContent":7,"ReplacementContent":"b"}]')")" "unverified"
pre_expect "multi-chunk-not-object-deny" deny "$(mk multi_replace_file_content "$(multi '["oops"]')")" "chunk"
pre_expect "multi-empty-chunks-deny"     deny "$(mk multi_replace_file_content "$(multi '[]')")"
MANY=$(python3 -c 'import json; print(json.dumps([{"StartLine":i,"EndLine":i,"TargetContent":"a","ReplacementContent":"b"} for i in range(101)]))')
pre_expect "multi-101-chunks-deny"       deny "$(mk multi_replace_file_content "$(multi "$MANY")")" "limit"
pre_expect "multi-chunks-not-list-deny"  deny "$(mk multi_replace_file_content "$(J TargetFile="$PROJ/src/m.py" ReplacementChunks="nope")")"

echo "=== 3. Fail-closed on PreToolUse (stub core hooks) ==="
fake_fw
BASH_IN="$(mk run_command "$(J CommandLine="ls" Cwd="$PROJ")")"
for m in crash junk odd; do
    setmode pre-tool-guard.sh "$m"; pre_expect "hook-$m-deny" deny "$BASH_IN"; setmode pre-tool-guard.sh silent
done
setmode pre-tool-guard.sh exit2; pre_expect "hook-exit2-deny-with-stderr" deny "$BASH_IN" "blocked by stub"; setmode pre-tool-guard.sh silent
setmode pre-tool-guard.sh deny;  pre_expect "hook-deny-reason-kept" deny "$BASH_IN" "stub says no"; setmode pre-tool-guard.sh silent
setmode pre-tool-guard.sh ask;   pre_expect "hook-ask-becomes-force-ask" force_ask "$BASH_IN" "stub wants approval"; setmode pre-tool-guard.sh silent
setmode pre-tool-guard.sh advisory; pre_expect "hook-advisory-becomes-ask" ask "$BASH_IN" "stub advisory note"; setmode pre-tool-guard.sh silent
setmode pre-tool-guard.sh allow; pre_expect "hook-allow-still-not-allow" ask "$BASH_IN"; setmode pre-tool-guard.sh silent
# deny beats ask regardless of chain order (ask first, deny last).
setmode pre-tool-guard.sh ask; setmode r4-mutex-check.sh deny
pre_expect "deny-beats-ask" deny "$BASH_IN" "stub says no"; setmode pre-tool-guard.sh silent; setmode r4-mutex-check.sh silent
# A missing / non-executable guard: PreToolUse denies, PostToolUse answers {}.
rm -f "$FW/$STUBS/loop-write-guard.py"
pre_expect "missing-hook-pre-deny" deny "$BASH_IN" "loop-write-guard"
agy PostToolUse "$(mk run_command "$(J CommandLine=ls Cwd="$PROJ")" '{"error":""}')"
if [[ "$OUT" == '{}' && $RC -eq 0 ]]; then ok "missing-hook-post-empty-object"; else bad "missing-hook-post-empty-object" "rc=$RC ${OUT:0:100}"; fi
cp "$FW/stub.sh" "$FW/$STUBS/loop-write-guard.py"; chmod -x "$FW/$STUBS/loop-write-guard.py"
pre_expect "non-executable-hook-pre-deny" deny "$BASH_IN" "not executable"
chmod +x "$FW/$STUBS/loop-write-guard.py"
# Stdin garbage / empty / non-object / wrong types: deny, never an exit-code failure.
for label_input in 'garbage:not json at all' 'empty:' 'array:[1,2]' 'truncated:{"toolCall":' 'notoolcall:{"conversationId":"c"}'; do
    label="${label_input%%:*}"; input="${label_input#*:}"
    pre_expect "stdin-$label-deny" deny "$input"
done
pre_expect "commandline-not-string-deny" deny "$(mk run_command '{"CommandLine":["ls"],"Cwd":"/tmp"}')" "unverified"
pre_expect "write-content-missing-deny"  deny "$(mk write_to_file "$(J TargetFile="$PROJ/x.py")")" "CodeContent"
out=$(printf '%s' "${BASH_IN%\}}"; printf ',"x":"\xff\xfe"}'); pre_expect "non-utf8-stdin-no-crash" ask "$out"
# One budget for the whole chain: a slow guard is denied by the adapter, not by agy.
setmode pre-tool-guard.sh slow
out=$(printf '%s' "$BASH_IN" | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_BUDGET_S=1 bash "$AD" PreToolUse 2>/dev/null))
if [[ "$(dec "$out")" == deny ]] && grep -qE 'timed out|budget' <<<"$out"; then ok "shared-time-budget-deny"; else bad "shared-time-budget-deny" "${out:0:200}"; fi
setmode pre-tool-guard.sh silent
# Unknown tool (a widened matcher): passed through as ask, no guard run.
: > "$DUMP_FILE"
pre_expect "unknown-tool-passthrough-ask" ask "$(mk view_file '{"AbsolutePath":"/tmp/x"}')"
dump_check "unknown-tool-runs-no-hook" 'assert rows == [], rows'
if grep -q "no guard chain" "$ERR_FILE"; then ok "unknown-tool-stderr-note"; else bad "unknown-tool-stderr-note" "$(cat "$ERR_FILE")"; fi

echo "=== 4. Canonical translation (what the core hooks receive) ==="
fake_fw
agy PreToolUse "$(mk run_command "$(J CommandLine="echo hi" Cwd="$PROJ/src")")"
dump_check "bash-canonical-shape-and-chain" '
names = [r["hook"] for r in rows]
assert names == ["pre-tool-guard.sh", "loop-write-guard.py", "r4-mutex-check.sh"], names
ev = rows[0]["ev"]
assert ev["ai"] == "antigravity" and ev["event"] == "PreToolUse" and ev["hook_event_name"] == "PreToolUse", ev
assert ev["tool_name"] == "Bash" and ev["tool_input"] == {"command": "echo hi"}, ev
assert ev["session_id"] == "conv-1234" and ev["transcript_path"].endswith("transcript_full.jsonl"), ev
assert ev["tool_use_id"] == "conv-1234:3", ev
'
# cwd = the tool call Cwd (then workspacePaths[0]); never the plugin dir agy starts hooks in.
if PROJ_SRC="$PROJ/src" PLUGIN_DIR="$PLUGIN" python3 - "$DUMP_FILE" <<'PY'
import json, os, sys
rows = [l.rstrip("\n").split("\t", 4) for l in open(sys.argv[1]) if l.strip()]
proj = os.environ["PROJ_SRC"]
for hook, pwd, _g, _o, ev in rows:
    ev = json.loads(ev)
    assert ev["cwd"] == proj, ev["cwd"]
    assert os.path.realpath(pwd) == os.path.realpath(proj), pwd
    assert os.path.realpath(pwd) != os.path.realpath(os.environ["PLUGIN_DIR"]), pwd
PY
then ok "cwd-from-Cwd-not-hook-cwd"; else bad "cwd-from-Cwd-not-hook-cwd" "$(head -c 400 "$DUMP_FILE")"; fi
: > "$DUMP_FILE"
agy PreToolUse "$(mk run_command "$(J CommandLine="echo hi")")"
if PROJ_DIR="$PROJ" python3 - "$DUMP_FILE" <<'PY'
import json, os, sys
rows = [l.rstrip("\n").split("\t", 4) for l in open(sys.argv[1]) if l.strip()]
assert rows and all(json.loads(r[4])["cwd"] == os.environ["PROJ_DIR"] for r in rows)
assert all(os.path.realpath(r[1]) == os.path.realpath(os.environ["PROJ_DIR"]) for r in rows)
PY
then ok "cwd-falls-back-to-workspacePaths"; else bad "cwd-falls-back-to-workspacePaths" "$(head -c 300 "$DUMP_FILE")"; fi
: > "$DUMP_FILE"
agy PreToolUse "$(mk write_to_file "$(J TargetFile="tests/../src/k.py" CodeContent="print(1)
")")"
if PROJ="$PROJ" python3 - "$DUMP_FILE" <<'PY'
import json, os, sys
rows = [l.rstrip("\n").split("\t", 4) for l in open(sys.argv[1]) if l.strip()]
names = [r[0] for r in rows]
assert names == ["check-hardcoding.py", "secret-content-scan.py", "r4-file-mutex-check.sh", "tdd-guard.py",
                 "spec-gate.py", "loop-write-guard.py", "r4-mutex-check.sh"], names
ev = json.loads(rows[0][4])
assert ev["tool_name"] == "Write" and ev["tool_input"]["content"] == "print(1)\n", ev
assert ev["tool_input"]["file_path"] == os.path.normpath(os.environ["PROJ"] + "/src/k.py"), ev["tool_input"]
PY
then ok "write-shape-and-normalized-path"; else bad "write-shape-and-normalized-path" "$(head -c 400 "$DUMP_FILE")"; fi
: > "$DUMP_FILE"
agy PreToolUse "$(mk replace_file_content "$(J TargetFile="$PROJ/src/a.py" TargetContent="old" ReplacementContent="new" Instruction=i)")"
if python3 - "$DUMP_FILE" <<'PY'
import json, sys
ev = json.loads(open(sys.argv[1]).readline().split("\t", 4)[4])
assert ev["tool_name"] == "Edit" and ev["tool_input"]["old_string"] == "old" and ev["tool_input"]["new_string"] == "new", ev
PY
then ok "edit-shape"; else bad "edit-shape" "$(head -c 300 "$DUMP_FILE")"; fi
: > "$DUMP_FILE"
agy PreToolUse "$(mk multi_replace_file_content "$(multi "$CLEAN_CHUNKS")")"
if python3 - "$DUMP_FILE" <<'PY'
import json, sys
rows = [l.rstrip("\n").split("\t", 4) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 14, len(rows)  # 2 chunks x 7 file-guard hooks
edits = [json.loads(r[4]) for r in rows if r[0] == "secret-content-scan.py"]
assert [(e["tool_name"], e["tool_input"]["old_string"], e["tool_input"]["new_string"]) for e in edits] == \
       [("Edit", "a", "b"), ("Edit", "c", "d")], edits
assert edits[0]["tool_input"]["file_path"] == edits[1]["tool_input"]["file_path"]
PY
then ok "multi-replace-one-edit-per-chunk"; else bad "multi-replace-one-edit-per-chunk" "$(cut -c1-200 "$DUMP_FILE" | head -5)"; fi

echo "=== 5. Environment scrub ==="
: > "$DUMP_FILE"
out=$(printf '%s' "$BASH_IN" | (cd "$PLUGIN" && GEMINI_API_KEY=FAKE-GEMINI-KEY-FOR-TEST GOOGLE_API_KEY=FAKE-GOOGLE-KEY-FOR-TEST bash "$AD" PreToolUse 2>/dev/null))
dump_check "api-keys-scrubbed-from-core-hook-env" 'assert rows and all(r["gemini"] == "UNSET" and r["google"] == "UNSET" for r in rows), rows'
if printf '%s' "$out" | grep -q 'FAKE-'; then bad "api-keys-not-in-output" "${out:0:120}"; else ok "api-keys-not-in-output"; fi

echo "=== 6. PostToolUse: always {}, error -> PostToolUseFailure ==="
: > "$DUMP_FILE"
agy PostToolUse "$(mk run_command "$(J CommandLine="make" Cwd="$PROJ")" '{"error":"exit status 2: make failed"}')"
if [[ "$OUT" == '{}' && $RC -eq 0 ]]; then ok "post-error-outputs-empty-object"; else bad "post-error-outputs-empty-object" "rc=$RC ${OUT:0:100}"; fi
dump_check "post-error-routes-PostToolUseFailure-to-chain" '
assert [r["hook"] for r in rows] == ["circuit-breaker.py", "verify-observer.py"], [r["hook"] for r in rows]
ev = rows[0]["ev"]
assert ev["event"] == "PostToolUseFailure" and ev["hook_event_name"] == "PostToolUseFailure", ev
assert ev["error"] == "exit status 2: make failed" and ev["tool_name"] == "Bash", ev
'
: > "$DUMP_FILE"
agy PostToolUse "$(mk run_command "$(J CommandLine="make" Cwd="$PROJ")" '{"error":""}')"
dump_check "post-success-is-plain-PostToolUse" 'assert rows and all(r["ev"]["event"] == "PostToolUse" and "error" not in r["ev"] for r in rows), rows'
: > "$DUMP_FILE"
agy PostToolUse "$(mk write_to_file "$(J TargetFile="$PROJ/src/w.py" CodeContent="1
")" '{"error":""}')"
dump_check "post-write-runs-mutex-register" 'assert [r["hook"] for r in rows] == ["r4-file-mutex-register.sh"], rows'
: > "$DUMP_FILE"
agy PostToolUse "$(mk multi_replace_file_content "$(multi "$CLEAN_CHUNKS")" '{"error":""}')"
dump_check "post-multi-runs-every-chunk" 'assert [r["hook"] for r in rows] == ["r4-file-mutex-register.sh"] * 2, rows'
# Hook output is never relayed (core hooks print plain additionalContext JSON), a crash never surfaces.
setmode circuit-breaker.py noisy; setmode verify-observer.py crash
agy PostToolUse "$(mk run_command "$(J CommandLine=ls Cwd="$PROJ")" '{"error":""}')"
if [[ "$OUT" == '{}' && $RC -eq 0 ]] && ! printf '%s' "$OUT" | grep -q leak; then ok "post-hook-output-not-relayed-crash-ignored"; else bad "post-hook-output-not-relayed-crash-ignored" "rc=$RC $OUT"; fi
setmode circuit-breaker.py silent; setmode verify-observer.py silent
agy PostToolUse 'not json'
if [[ "$OUT" == '{}' && $RC -eq 0 ]]; then ok "post-garbage-stdin-empty-object"; else bad "post-garbage-stdin-empty-object" "rc=$RC $OUT"; fi
# Real circuit-breaker: an agy tool error is counted through the PostToolUseFailure branch.
AD="$REAL_ADAPTER"
rm -f "$AGENT_CIRCUIT_BREAKER_STATE"
out=$(printf '%s' "$(mk run_command "$(J CommandLine=make Cwd="$PROJ")" '{"error":"boom: the build exploded here","stepIdx":41}')" \
    | (cd "$PLUGIN" && AGENT_CIRCUIT_BREAKER_THRESHOLD=5 bash "$AD" PostToolUse 2>/dev/null))
if [[ "$out" == '{}' ]] && python3 - "$AGENT_CIRCUIT_BREAKER_STATE" <<'PY'
import json, sys
recs = json.load(open(sys.argv[1]))
assert len(recs) == 1 and "boom" in recs[0]["sig"] and recs[0]["tool_use_id"] == "conv-1234:41", recs
PY
then ok "real-circuit-breaker-sees-PostToolUseFailure"; else bad "real-circuit-breaker-sees-PostToolUseFailure" "out=$out state=$(cat "$AGENT_CIRCUIT_BREAKER_STATE" 2>/dev/null)"; fi
# Threshold hit: the breaker prints its own JSON, the adapter still answers a bare {}.
out=$(printf '%s' "$(mk run_command "$(J CommandLine=make Cwd="$PROJ")" '{"error":"boom: the build exploded here","stepIdx":42}')" \
    | (cd "$PLUGIN" && AGENT_CIRCUIT_BREAKER_THRESHOLD=1 bash "$AD" PostToolUse 2>/dev/null))
if [[ "$out" == '{}' ]]; then ok "real-circuit-breaker-output-not-relayed"; else bad "real-circuit-breaker-output-not-relayed" "$out"; fi

echo "=== 7. Stop: continue once, then stop; validated conversationId marker ==="
fake_fw
rm -rf "$AGENT_STATE_DIR"
MARK="$AGENT_STATE_DIR/antigravity-stop/conv-1234"
agy Stop "$(stop_in)"
if [[ "$OUT" == '{"decision": "stop"}' || "$(dec "$OUT")" == stop ]] && [[ $RC -eq 0 && ! -e "$MARK" ]]; then ok "stop-clean-stops-no-marker"; else bad "stop-clean-stops-no-marker" "rc=$RC $OUT"; fi
dump_check "stop-runs-whole-chain" 'assert [r["hook"] for r in rows] == ["session-quality-gate.py", "brain-capture.py", "session-close.sh"], rows'
setmode session-quality-gate.py block
: > "$DUMP_FILE"
agy Stop "$(stop_in)"
if [[ "$(dec "$OUT")" == continue && "$(reason "$OUT")" == "finish the tests first" && -e "$MARK" ]]; then ok "stop-block-continues-once-and-marks"; else bad "stop-block-continues-once-and-marks" "$OUT marker=$([[ -e $MARK ]] && echo yes || echo no)"; fi
dump_check "stop-hook-active-false-first" 'assert all(r["ev"]["stop_hook_active"] is False and r["ev"]["event"] == "Stop" and r["ev"]["ai"] == "antigravity" for r in rows), rows'
: > "$DUMP_FILE"
agy Stop "$(stop_in '{"executionNum":1}')"
if [[ "$(dec "$OUT")" == stop && ! -e "$MARK" ]]; then ok "stop-second-stops-and-clears-marker"; else bad "stop-second-stops-and-clears-marker" "$OUT marker=$([[ -e $MARK ]] && echo yes || echo no)"; fi
dump_check "stop-hook-active-true-second" 'assert rows and all(r["ev"]["stop_hook_active"] is True for r in rows), rows'
agy Stop "$(stop_in)"
if [[ "$(dec "$OUT")" == continue ]]; then ok "stop-third-blocks-again-after-reset"; else bad "stop-third-blocks-again-after-reset" "$OUT"; fi
rm -f "$MARK"
# Marker from a dead conversation older than the TTL must not silence the gate.
mkdir -p "$(dirname "$MARK")"; : > "$MARK"; touch -t 200001010000 "$MARK"
agy Stop "$(stop_in)"
if [[ "$(dec "$OUT")" == continue ]]; then ok "stop-stale-marker-ignored"; else bad "stop-stale-marker-ignored" "$OUT"; fi
rm -f "$MARK"
# Failing / unparseable Stop hooks never block or crash: fail-open to stop.
setmode session-quality-gate.py crash; agy Stop "$(stop_in)"
if [[ "$(dec "$OUT")" == stop && $RC -eq 0 ]]; then ok "stop-hook-crash-stops"; else bad "stop-hook-crash-stops" "rc=$RC $OUT"; fi
setmode session-quality-gate.py junk; agy Stop "$(stop_in)"
if [[ "$(dec "$OUT")" == stop && $RC -eq 0 ]]; then ok "stop-hook-junk-stops"; else bad "stop-hook-junk-stops" "rc=$RC $OUT"; fi
agy Stop 'not json'
if [[ "$(dec "$OUT")" == stop && $RC -eq 0 ]]; then ok "stop-garbage-stdin-stops"; else bad "stop-garbage-stdin-stops" "rc=$RC $OUT"; fi
# Raw hook stdout is never relayed: a Stop hook printing a non-block decision cannot leak through.
setmode session-quality-gate.py noisy; agy Stop "$(stop_in)"
if [[ "$(dec "$OUT")" == stop ]] && ! printf '%s' "$OUT" | grep -q leak; then ok "stop-raw-hook-output-not-relayed"; else bad "stop-raw-hook-output-not-relayed" "$OUT"; fi
setmode session-quality-gate.py block
# conversationId validation: nothing is run and nothing is written outside the state dir.
: > "$DUMP_FILE"; rm -rf "$AGENT_STATE_DIR" "$WORK/x" "$WORK/state/x"
for cid in '../x' '../../x' 'a/b' '' 'has space' "$(python3 -c 'print("a"*65)')"; do
    agy Stop "$(stop_in "$(_C="$cid" python3 -c 'import json,os; print(json.dumps({"conversationId": os.environ["_C"]}))')")"
    if [[ "$(dec "$OUT")" == stop && $RC -eq 0 ]]; then ok "stop-invalid-id-stops[${cid:0:12}]"; else bad "stop-invalid-id-stops[${cid:0:12}]" "rc=$RC $OUT"; fi
done
agy Stop "$(stop_in '{"conversationId":123}')"
if [[ "$(dec "$OUT")" == stop ]]; then ok "stop-non-string-id-stops"; else bad "stop-non-string-id-stops" "$OUT"; fi
dump_check "stop-invalid-id-runs-no-hook" 'assert rows == [], rows'
if [[ ! -e "$AGENT_STATE_DIR" && ! -e "$WORK/x" && ! -e "$WORK/state/x" ]]; then ok "stop-invalid-id-touches-no-filesystem"; else bad "stop-invalid-id-touches-no-filesystem" "$(find "$WORK/state" 2>/dev/null | head)"; fi
# The marker cannot be created: stop instead of looping forever.
printf 'file' > "$WORK/statefile"
out=$(printf '%s' "$(stop_in)" | (cd "$PLUGIN" && AGENT_STATE_DIR="$WORK/statefile" bash "$AD" Stop 2>/dev/null))
if [[ "$(dec "$out")" == stop ]]; then ok "stop-marker-unwritable-stops"; else bad "stop-marker-unwritable-stops" "$out"; fi

echo "=== 8. Worker mode (AGENT_ANTIGRAVITY_WORKER=1) ==="
: > "$DUMP_FILE"
for tool in run_command write_to_file; do
    args=$(J CommandLine="ls" Cwd="$PROJ" TargetFile="$PROJ/a" CodeContent="x")
    out=$(printf '%s' "$(mk "$tool" "$args")" | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_WORKER=1 bash "$AD" PreToolUse 2>/dev/null))
    if [[ "$(dec "$out")" == deny ]] && grep -q 'review worker' <<<"$(reason "$out")"; then ok "worker-pre-deny[$tool]"; else bad "worker-pre-deny[$tool]" "$out"; fi
done
out=$(printf '%s' "$(mk run_command "$(J CommandLine=ls Cwd="$PROJ")" '{"error":""}')" | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_WORKER=1 bash "$AD" PostToolUse 2>/dev/null))
if [[ "$out" == '{}' ]]; then ok "worker-post-empty-object"; else bad "worker-post-empty-object" "$out"; fi
out=$(printf '%s' "$(stop_in)" | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_WORKER=1 bash "$AD" Stop 2>/dev/null))
if [[ "$(dec "$out")" == stop && ! -e "$MARK" ]]; then ok "worker-stop-stops"; else bad "worker-stop-stops" "$out"; fi
dump_check "worker-runs-no-hook" 'assert rows == [], rows'
# Worker denies even garbage stdin (nothing to parse, nothing to run).
out=$(printf 'garbage' | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_WORKER=1 bash "$AD" PreToolUse 2>/dev/null))
if [[ "$(dec "$out")" == deny ]]; then ok "worker-garbage-pre-deny"; else bad "worker-garbage-pre-deny" "$out"; fi
# Only the exact value 1 switches the mode on.
out=$(printf '%s' "$BASH_IN" | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_WORKER=0 bash "$AD" PreToolUse 2>/dev/null))
if [[ "$(dec "$out")" == ask ]]; then ok "worker-flag-zero-is-normal-mode"; else bad "worker-flag-zero-is-normal-mode" "$out"; fi

echo "=== 9. Launcher (adapter.sh) ==="
AD="$REAL_ADAPTER"
if [[ -x "$REAL_ADAPTER" && -f "$REPO_ROOT/adapters/antigravity/adapter.py" ]]; then ok "launcher-and-translator-present"; else bad "launcher-and-translator-present" "missing or not executable"; fi
for bad_arg in "" "Bogus" "pretooluse" "SessionStart"; do
    bash "$REAL_ADAPTER" $bad_arg </dev/null >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 2 ]]; then ok "launcher-usage-exit-2[${bad_arg:-empty}]"; else bad "launcher-usage-exit-2[${bad_arg:-empty}]" "rc=$rc"; fi
done
mkdir -p "$WORK/nopy"
for b in bash cat dirname; do ln -sf "$(command -v "$b")" "$WORK/nopy/$b"; done
out=$(printf '%s' "$BASH_IN" | PATH="$WORK/nopy" "$WORK/nopy/bash" "$REAL_ADAPTER" PreToolUse 2>/dev/null)
if [[ "$(dec "$out")" == deny ]]; then ok "no-python-pre-deny"; else bad "no-python-pre-deny" "$out"; fi
out=$(printf '%s' "$BASH_IN" | PATH="$WORK/nopy" "$WORK/nopy/bash" "$REAL_ADAPTER" PostToolUse 2>/dev/null)
if [[ "$out" == '{}' ]]; then ok "no-python-post-empty-object"; else bad "no-python-post-empty-object" "$out"; fi
out=$(printf '%s' "$BASH_IN" | PATH="$WORK/nopy" "$WORK/nopy/bash" "$REAL_ADAPTER" Stop 2>/dev/null)
if [[ "$(dec "$out")" == stop ]]; then ok "no-python-stop-stops"; else bad "no-python-stop-stops" "$out"; fi

echo "=== 11. Review fixes: budget parse, send_command_input, Stop slices, agy transcript ==="
fake_fw
BASH_IN="$(mk run_command "$(J CommandLine="ls" Cwd="$PROJ")")"
# A junk budget env var must not crash the import (empty stdout + rc 1 is not a known deny on agy).
for bv in abc nan inf 0 -3 ''; do
    out=$(printf '%s' "$BASH_IN" | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_BUDGET_S="$bv" bash "$AD" PreToolUse 2>/dev/null)); rc=$?
    if [[ $rc -eq 0 && "$(dec "$out")" == ask ]]; then ok "bad-budget-env-falls-back[${bv:-empty}]"; else bad "bad-budget-env-falls-back[${bv:-empty}]" "rc=$rc ${out:0:120}"; fi
done
# send_command_input types text into a live shell: guarded like run_command, fail-closed on a shape mismatch.
: > "$DUMP_FILE"
pre_expect "send-input-benign-passthrough" ask "$(mk send_command_input "$(J CommandId=c1 Input="ls -la")")"
dump_check "send-input-runs-bash-chain" '
assert [r["hook"] for r in rows] == ["pre-tool-guard.sh", "loop-write-guard.py", "r4-mutex-check.sh"], rows
ev = rows[0]["ev"]
assert ev["tool_name"] == "Bash" and ev["tool_input"] == {"command": "ls -la"}, ev
'
setmode pre-tool-guard.sh deny
pre_expect "send-input-guard-deny" deny "$(mk send_command_input "$(J CommandId=c1 Input="git push --force origin main")")" "stub says no"
setmode pre-tool-guard.sh silent
pre_expect "send-input-missing-input-deny" deny "$(mk send_command_input "$(J CommandId=c1)")" "Input"
: > "$DUMP_FILE"
pre_expect "send-input-terminate-only-passthrough" ask "$(mk send_command_input '{"CommandId":"c1","Terminate":true}')"
dump_check "send-input-terminate-runs-no-hook" 'assert rows == [], rows'
# The real chain denies a destructive command typed through send_command_input, as through run_command.
AD="$REAL_ADAPTER"
pre_expect "real-send-input-destructive-deny" deny "$(mk send_command_input "$(J CommandId=c1 Input="rm -rf /")")"
# Matcher drift: every tool the adapter maps must be inside the plugin's PreToolUse matcher.
if python3 - "$REPO_ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
src = open(os.path.join(root, "adapters/antigravity/adapter.py")).read()
tools = set(re.findall(r'name == "(\w+)"', src))
tpl = json.load(open(os.path.join(root, "adapters/antigravity/hooks.json.template")))["agent-harness"]
matcher = set(tpl["PreToolUse"][0]["matcher"].split("|"))
assert tools and tools <= matcher, (sorted(tools), sorted(matcher))
PY
then ok "pre-matcher-covers-every-translated-tool"; else bad "pre-matcher-covers-every-translated-tool" "adapter.py translates a tool the PreToolUse matcher does not send"; fi

# Stop: a slow completion gate cannot starve brain-capture / session-close (reserved slices).
fake_fw
rm -rf "$AGENT_STATE_DIR"
setmode session-quality-gate.py hang   # would use the whole budget
: > "$DUMP_FILE"
out=$(printf '%s' "$(stop_in)" | (cd "$PLUGIN" && AGENT_ANTIGRAVITY_BUDGET_S=3 bash "$AD" Stop 2>"$ERR_FILE")); rc=$?
if [[ $rc -eq 0 && "$(dec "$out")" == stop ]]; then ok "stop-slow-gate-still-stops"; else bad "stop-slow-gate-still-stops" "rc=$rc $out"; fi
dump_check "stop-slow-gate-does-not-starve-closing-hooks" 'assert [r["hook"] for r in rows] == ["session-quality-gate.py", "brain-capture.py", "session-close.sh"], rows'
# A gate that overran its slice is reported, never silently treated as a pass.
if grep -q "session-quality-gate.py did not finish" "$ERR_FILE"; then ok "stop-gate-timeout-reported"; else bad "stop-gate-timeout-reported" "$(cat "$ERR_FILE")"; fi
setmode session-quality-gate.py silent

# session-quality-gate layer 3 reads agy's transcript shape ({step_index, tool_calls:[{name,args}]}).
if python3 - "$REPO_ROOT" "$WORK" <<'PY'
import importlib.util, json, os, sys
root, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("sqg", os.path.join(root, "core/hooks/session-quality-gate.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
t = os.path.join(work, "agy-transcript.jsonl")
with open(t, "w") as f:
    f.write(json.dumps({"step_index": 1, "tool_calls": [{"name": "list_dir", "args": {"DirectoryPath": "/x"}}]}) + "\n")
    f.write(json.dumps({"step_index": 2, "tool_calls": [{"name": "write_to_file", "args": {"TargetFile": "/tmp/agy-a.py", "CodeContent": "1"}}]}) + "\n")
    f.write(json.dumps({"step_index": 3, "tool_calls": [{"name": "replace_file_content", "args": {"TargetFile": "/tmp/agy-b.py"}},
                                                          {"name": "multi_replace_file_content", "args": {"TargetFile": "/tmp/agy-c.py"}},
                                                          {"name": "run_command", "args": {"TargetFile": "/tmp/agy-not.py"}}]}) + "\n")
got = mod.session_edited_files(t)
want = {os.path.realpath(p) for p in ("/tmp/agy-a.py", "/tmp/agy-b.py", "/tmp/agy-c.py")}
assert got == want, (got, want)
PY
then ok "quality-gate-reads-agy-transcript-edits"; else bad "quality-gate-reads-agy-transcript-edits" "session_edited_files ignored the agy transcript shape"; fi

echo "=== 10. Drift guard: chains == Codex hooks.json.template ==="
if python3 - "$TEMPLATE" "$REPO_ROOT/adapters/antigravity/adapter.py" <<'PY'
import importlib.util, json, re, sys
tpl = json.load(open(sys.argv[1]))["hooks"]
spec = importlib.util.spec_from_file_location("agy_adapter", sys.argv[2])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
cmd = re.compile(r'adapter\.sh" (\S+)$')

def hooks_for(event, codex_tool):
    """Hooks the Codex template runs for one tool name (matcher regex semantics)."""
    names = []
    for group in tpl[event]:
        if re.search(group.get("matcher", "*") if group.get("matcher", "*") != "*" else ".*", codex_tool):
            names += [cmd.search(h["command"]).group(1) for h in group["hooks"]]
    return names

# Codex `apply_patch` is the analogue of agy's write/edit tools; Codex `Bash` of run_command.
want = {
    ("PreToolUse", "Bash"): hooks_for("PreToolUse", "Bash"),
    ("PreToolUse", "Write"): hooks_for("PreToolUse", "apply_patch"),
    ("PreToolUse", "Edit"): hooks_for("PreToolUse", "apply_patch"),
    ("PostToolUse", "Bash"): hooks_for("PostToolUse", "Bash"),
    ("PostToolUse", "Write"): hooks_for("PostToolUse", "apply_patch"),
    ("PostToolUse", "Edit"): hooks_for("PostToolUse", "apply_patch"),
    ("Stop", ""): [cmd.search(h["command"]).group(1) for g in tpl["Stop"] for h in g["hooks"]],
}
got = {(ev, tool): chain for ev, tools in mod.CHAINS.items() for tool, chain in tools.items()}
assert set(got) == set(want), (sorted(got), sorted(want))
for key in want:
    assert want[key] and set(got[key]) == set(want[key]) and len(got[key]) == len(set(got[key])), (key, got[key], want[key])
PY
then ok "chain-table-equals-codex-template"; else bad "chain-table-equals-codex-template" "adapter.py CHAINS drifted from adapters/codex/hooks.json.template"; fi
if python3 - "$REPO_ROOT" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("agy_adapter", os.path.join(sys.argv[1], "adapters/antigravity/adapter.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
for tools in mod.CHAINS.values():
    for chain in tools.values():
        for hook in chain:
            assert os.access(os.path.join(sys.argv[1], "core/hooks", hook), os.X_OK), hook
PY
then ok "every-chained-core-hook-exists"; else bad "every-chained-core-hook-exists" "a chained hook is missing from core/hooks"; fi

echo
echo "=== antigravity-adapter: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
