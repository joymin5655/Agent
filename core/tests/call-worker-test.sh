#!/usr/bin/env bash
# call-worker-test.sh — verify core/infra/call-worker.sh dispatch contract.
#
# Contract under test (all backends are PATH stubs — zero paid calls):
#   ok            <- approved dispatch captures stub reply; fallback NOT invoked
#   fallback/cli  <- primary CLI absent -> fallback runs, reason recorded
#   fallback/exit <- primary exits nonzero -> fallback runs, reason has the code
#   fallback/time <- primary hangs -> killed, fallback runs, reason says timeout
#   timeout       <- hung primary, no fallback -> 124
#   term-immune   <- primary traps TERM -> KILL escalation still enforces 124
#   raw-exit      <- failed backend's raw exit is normalized to 1 (contract)
#   no-cli        <- no backend CLI available -> 127 naming the missing tool
#   approval      <- AGENT_WORKER_YES unset -> exit 3 and NO backend invoked
#   bad-role      <- unknown role -> exit 2 naming known roles
#
# Registry is pinned via AGENT_BACKENDS_FILE and output via AGENT_WORKERS_DIR
# (test seams) so the battery never touches core/infra/backends.json routing
# assumptions or the repo's own .agent/ (hook-config-test lesson: a test that
# mutates the harness's live state blocks itself).
#
# Usage: bash core/tests/call-worker-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO_ROOT/core/infra/call-worker.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1 — $2"; }

# --- fixtures -----------------------------------------------------------

REGISTRY="$WORK/backends.json"
cat > "$REGISTRY" <<'JSON'
{
  "version": 1,
  "roles": {
    "review": { "backend": "codex", "fallback": "gemini" },
    "verify": { "backend": "codex", "fallback": null }
  },
  "backends": {
    "codex":  { "connection": "cli", "cmd": ["codex", "exec"], "timeout_s": 30 },
    "gemini": { "connection": "cli", "cmd": ["gemini", "-p", ""], "timeout_s": 30 }
  }
}
JSON

MARKERS="$WORK/markers"
mkdir -p "$MARKERS"

make_stub() {  # make_stub <dir> <name> <reply>
    local dir="$1" name="$2" reply="$3"
    mkdir -p "$dir"
    cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
touch "$MARKERS/$name.called"
cat >/dev/null
echo "$reply"
EOF
    chmod +x "$dir/$name"
}

run_dispatch() {  # run_dispatch <stub-dir> <role> <yes> [extra-env...]
    local stub_dir="$1" role="$2" yes="$3"; shift 3
    env PATH="$stub_dir:/usr/bin:/bin" \
        AGENT_BACKENDS_FILE="$REGISTRY" \
        AGENT_WORKERS_DIR="$WORK/workers" \
        AGENT_WORKER_YES="$yes" \
        "$@" \
        bash "$DISPATCHER" "$role" <<< "sample prompt"
}

# --- 1. ok: primary present, reply captured -----------------------------

BOTH="$WORK/bin-both"
make_stub "$BOTH" "codex" "CODEX-STUB-REPLY"
make_stub "$BOTH" "gemini" "GEMINI-STUB-REPLY"

out="$(run_dispatch "$BOTH" review 1 2>"$WORK/err1")"; rc=$?
if [[ $rc -eq 0 && -f "$out" && ! -f "$MARKERS/gemini.called" ]] \
   && grep -q "CODEX-STUB-REPLY" "$out" \
   && grep -q "^backend: codex$" "$out"; then
    ok "ok path — codex reply captured, fallback not invoked"
else
    bad "ok path" "rc=$rc out=$out $(cat "$WORK/err1" 2>/dev/null | head -2)"
fi

# --- 2. fallback: primary CLI absent -> gemini + reason ------------------

GEMONLY="$WORK/bin-gemini-only"
make_stub "$GEMONLY" "gemini" "GEMINI-STUB-REPLY"

out="$(run_dispatch "$GEMONLY" review 1 2>"$WORK/err2")"; rc=$?
if [[ $rc -eq 0 && -f "$out" ]] && grep -q "GEMINI-STUB-REPLY" "$out" \
   && grep -q "fallback_reason: primary 'codex' CLI not found" "$out"; then
    ok "fallback — reason preserved in capture header"
else
    bad "fallback" "rc=$rc out=$out $(cat "$WORK/err2" 2>/dev/null | head -2)"
fi

# --- 2b. fallback on nonzero exit: reason carries the raw code ----------

FAILEX="$WORK/bin-failing-codex"
make_stub "$FAILEX" "gemini" "GEMINI-STUB-REPLY"
mkdir -p "$FAILEX"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "codex blew up" >&2\nexit 7\n' > "$FAILEX/codex"
chmod +x "$FAILEX/codex"

out="$(run_dispatch "$FAILEX" review 1 2>"$WORK/err2b")"; rc=$?
if [[ $rc -eq 0 && -f "$out" ]] && grep -q "GEMINI-STUB-REPLY" "$out" \
   && grep -q "fallback_reason: primary 'codex' exited 7" "$out"; then
    ok "fallback on nonzero exit — raw code preserved in reason"
else
    bad "fallback on nonzero exit" "rc=$rc out=$out $(head -2 "$WORK/err2b" 2>/dev/null)"
fi

# --- 2c. fallback on timeout: hung primary, healthy fallback ------------

HUNGFB="$WORK/bin-hung-codex-live-gemini"
make_stub "$HUNGFB" "gemini" "GEMINI-STUB-REPLY"
mkdir -p "$HUNGFB"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$HUNGFB/codex"
chmod +x "$HUNGFB/codex"

out="$(run_dispatch "$HUNGFB" review 1 AGENT_WORKER_TIMEOUT_S=1 AGENT_WORKER_KILL_GRACE_S=1 2>"$WORK/err2c")"; rc=$?
if [[ $rc -eq 0 && -f "$out" ]] && grep -q "GEMINI-STUB-REPLY" "$out" \
   && grep -q "fallback_reason: primary 'codex' timed out" "$out"; then
    ok "fallback on timeout — reason says timed out"
else
    bad "fallback on timeout" "rc=$rc out=$out $(head -2 "$WORK/err2c" 2>/dev/null)"
fi

# --- 3. timeout: hung primary, no fallback -> 124 ------------------------

HUNG="$WORK/bin-hung"
mkdir -p "$HUNG"
cat > "$HUNG/codex" <<EOF
#!/usr/bin/env bash
touch "$MARKERS/hung.called"
sleep 30
EOF
chmod +x "$HUNG/codex"

run_dispatch "$HUNG" verify 1 AGENT_WORKER_TIMEOUT_S=1 AGENT_WORKER_KILL_GRACE_S=1 >"$WORK/out3" 2>"$WORK/err3"; rc=$?
if [[ $rc -eq 124 && -f "$MARKERS/hung.called" ]]; then
    ok "timeout — hung worker killed, exit 124"
else
    bad "timeout" "rc=$rc (want 124) called=$(ls "$MARKERS" | tr '\n' ' ')"
fi

# --- 3b. TERM-immune worker: KILL escalation still lands 124 -------------

IMMUNE="$WORK/bin-term-immune"
mkdir -p "$IMMUNE"
printf '#!/usr/bin/env bash\ntrap "" TERM\nfor i in $(seq 1 300); do sleep 0.1; done\n' > "$IMMUNE/codex"
chmod +x "$IMMUNE/codex"

run_dispatch "$IMMUNE" verify 1 AGENT_WORKER_TIMEOUT_S=1 AGENT_WORKER_KILL_GRACE_S=1 >"$WORK/out3b" 2>"$WORK/err3b"; rc=$?
if [[ $rc -eq 124 ]]; then
    ok "term-immune — SIGKILL escalation enforced timeout (124)"
else
    bad "term-immune" "rc=$rc (want 124)"
fi

# --- 3c. no fallback + failing backend -> normalized exit 1 --------------

FAILONLY="$WORK/bin-fail-verify"
mkdir -p "$FAILONLY"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "codex blew up" >&2\nexit 7\n' > "$FAILONLY/codex"
chmod +x "$FAILONLY/codex"

run_dispatch "$FAILONLY" verify 1 >"$WORK/out3c" 2>"$WORK/err3c"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "exit 7" "$WORK/err3c"; then
    ok "raw-exit normalization — backend exit 7 reported, dispatcher exits 1"
else
    bad "raw-exit normalization" "rc=$rc (want 1) err=$(head -1 "$WORK/err3c" 2>/dev/null)"
fi

# --- 4. no CLI anywhere -> 127 naming the tool ---------------------------

EMPTY="$WORK/bin-empty"
mkdir -p "$EMPTY"
run_dispatch "$EMPTY" verify 1 >"$WORK/out4" 2>"$WORK/err4"; rc=$?
if [[ $rc -eq 127 ]] && grep -q "codex" "$WORK/err4"; then
    ok "no-cli guard — exit 127, missing tool named"
else
    bad "no-cli guard" "rc=$rc (want 127) err=$(head -1 "$WORK/err4" 2>/dev/null)"
fi

# --- 5. approval gate: no AGENT_WORKER_YES -> 3, nothing invoked ---------

rm -f "$MARKERS"/*.called
run_dispatch "$BOTH" review "" >"$WORK/out5" 2>"$WORK/err5"; rc=$?
if [[ $rc -eq 3 && ! -f "$MARKERS/codex.called" && ! -f "$MARKERS/gemini.called" ]] \
   && grep -q "AGENT_WORKER_YES=1" "$WORK/err5"; then
    ok "approval gate — refused (3), zero backend invocations, remedy named"
else
    bad "approval gate" "rc=$rc (want 3) markers=$(ls "$MARKERS" 2>/dev/null | tr '\n' ' ')"
fi

# --- 6. unknown role -> 2 naming known roles -----------------------------

run_dispatch "$BOTH" nonsense 1 >"$WORK/out6" 2>"$WORK/err6"; rc=$?
if [[ $rc -eq 2 ]] && grep -q "review" "$WORK/err6"; then
    ok "bad-role — exit 2, known roles listed"
else
    bad "bad-role" "rc=$rc (want 2) err=$(head -1 "$WORK/err6" 2>/dev/null)"
fi

# --- tally ---------------------------------------------------------------

echo
echo "call-worker-test: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
