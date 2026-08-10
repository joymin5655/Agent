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
# Registry v2 additions (v1 fixture above stays valid — back-compat is itself
# under test):
#   status        <- capture header carries status: complete (mechanical truth)
#   tier-argv     <- argv = cmd + tier_args[role.tier] + role.args_extra
#   disabled      <- enabled:false -> loud refusal citing disabled_reason,
#                    exit 127, status: unavailable capture on disk
#   disabled-fb   <- disabled primary -> fallback runs, reason names disable
#   preflight     <- failing preflight -> unavailable; passing preflight -> ok
#   gateway-cwd   <- a backend carrying "gateway" is dispatched from a NEUTRAL
#                    harness-owned directory, so a ./.kiro/agents/kiro-*.json
#                    planted in the caller's cwd is not on the profile
#                    resolution path; non-gateway backends still inherit it
#   gateway-pf    <- the probe is handed the lane + registry to reproduce and
#                    runs in the same cwd as the dispatch it vets
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

# --- 7. v2 registry: tier/args_extra argv composition + status header ----

REG2="$WORK/backends-v2.json"
cat > "$REG2" <<'JSON'
{
  "version": 2,
  "roles": {
    "review":  { "backend": "codex", "tier": "TOP", "fallback": "gemini" },
    "build":   { "backend": "codex", "tier": "MID", "fallback": null,
                 "args_extra": ["--sandbox", "workspace-write"] },
    "lowfan":  { "backend": "codex", "tier": "LOW", "fallback": null }
  },
  "backends": {
    "codex":  { "vendor": "openai", "connection": "cli", "enabled": true,
                "cmd": ["codex", "exec"],
                "tier_args": { "LOW": ["--profile", "quick"], "MID": [],
                               "TOP": ["--profile", "deep"] },
                "timeout_s": 30 },
    "gemini": { "vendor": "google", "connection": "cli", "enabled": true,
                "cmd": ["gemini", "-p", ""], "tier_args": {}, "timeout_s": 30 }
  }
}
JSON

ARGV_DIR="$WORK/bin-argv"
mkdir -p "$ARGV_DIR"
cat > "$ARGV_DIR/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$MARKERS/codex.argv"
cat >/dev/null
echo "CODEX-STUB-REPLY"
EOF
chmod +x "$ARGV_DIR/codex"

run_v2() {  # run_v2 <stub-dir> <role> [extra-env...]
    local stub_dir="$1" role="$2"; shift 2
    env PATH="$stub_dir:/usr/bin:/bin" \
        AGENT_BACKENDS_FILE="$REG2" \
        AGENT_WORKERS_DIR="$WORK/workers" \
        AGENT_WORKER_YES=1 \
        "$@" \
        bash "$DISPATCHER" "$role" <<< "sample prompt"
}

out="$(run_v2 "$ARGV_DIR" review 2>"$WORK/err7")"; rc=$?
if [[ $rc -eq 0 && -f "$out" ]] \
   && [[ "$(tr '\n' ' ' < "$MARKERS/codex.argv")" == "exec --profile deep " ]] \
   && grep -q "^status: complete$" "$out"; then
    ok "v2 tier argv — TOP composes cmd+tier_args; status: complete in header"
else
    bad "v2 tier argv" "rc=$rc argv=[$(tr '\n' ' ' < "$MARKERS/codex.argv" 2>/dev/null)] out=$out"
fi

out="$(run_v2 "$ARGV_DIR" build 2>"$WORK/err7b")"; rc=$?
if [[ $rc -eq 0 ]] \
   && [[ "$(tr '\n' ' ' < "$MARKERS/codex.argv")" == "exec --sandbox workspace-write " ]]; then
    ok "v2 args_extra — MID (empty tier_args) + role args_extra appended"
else
    bad "v2 args_extra" "rc=$rc argv=[$(tr '\n' ' ' < "$MARKERS/codex.argv" 2>/dev/null)]"
fi

out="$(run_v2 "$ARGV_DIR" lowfan 2>"$WORK/err7c")"; rc=$?
if [[ $rc -eq 0 ]] \
   && [[ "$(tr '\n' ' ' < "$MARKERS/codex.argv")" == "exec --profile quick " ]]; then
    ok "v2 LOW tier — --profile quick composed"
else
    bad "v2 LOW tier" "rc=$rc argv=[$(tr '\n' ' ' < "$MARKERS/codex.argv" 2>/dev/null)]"
fi

# --- 8. v2 disabled backend: loud refusal, exit 127, unavailable capture --

REG3="$WORK/backends-v2-disabled.json"
cat > "$REG3" <<'JSON'
{
  "version": 2,
  "roles": {
    "solo": { "backend": "gemini", "tier": "TOP", "fallback": null },
    "duo":  { "backend": "gemini", "tier": "TOP", "fallback": "codex" }
  },
  "backends": {
    "gemini": { "vendor": "google", "connection": "cli", "enabled": false,
                "cmd": ["gemini", "-p", ""], "tier_args": {},
                "disabled_reason": "auth path retired upstream", "timeout_s": 30 },
    "codex":  { "vendor": "openai", "connection": "cli", "enabled": true,
                "cmd": ["codex", "exec"],
                "tier_args": { "TOP": ["--profile", "deep"] }, "timeout_s": 30 }
  }
}
JSON

DIS_WORKERS="$WORK/workers-disabled"
env PATH="$BOTH:/usr/bin:/bin" AGENT_BACKENDS_FILE="$REG3" \
    AGENT_WORKERS_DIR="$DIS_WORKERS" AGENT_WORKER_YES=1 \
    bash "$DISPATCHER" solo <<< "p" >"$WORK/out8" 2>"$WORK/err8"; rc=$?
cap8="$(ls "$DIS_WORKERS" 2>/dev/null | head -1)"
if [[ $rc -eq 127 ]] && grep -q "disabled in registry: auth path retired upstream" "$WORK/err8" \
   && [[ -n "$cap8" ]] && grep -q "^status: unavailable$" "$DIS_WORKERS/$cap8" \
   && ! grep -q "GEMINI-STUB-REPLY" "$DIS_WORKERS/$cap8"; then
    ok "v2 disabled — exit 127, reason on stderr, status: unavailable capture, no dispatch"
else
    bad "v2 disabled" "rc=$rc (want 127) err=$(head -1 "$WORK/err8" 2>/dev/null) cap=$cap8"
fi

out="$(env PATH="$BOTH:/usr/bin:/bin" AGENT_BACKENDS_FILE="$REG3" \
    AGENT_WORKERS_DIR="$WORK/workers" AGENT_WORKER_YES=1 \
    bash "$DISPATCHER" duo <<< "p" 2>"$WORK/err8b")"; rc=$?
if [[ $rc -eq 0 && -f "$out" ]] && grep -q "CODEX-STUB-REPLY" "$out" \
   && grep -q "fallback_reason: primary 'gemini' unavailable (backend 'gemini' disabled in registry" "$out"; then
    ok "v2 disabled-fb — fallback ran, reason names the disable"
else
    bad "v2 disabled-fb" "rc=$rc out=$out err=$(head -1 "$WORK/err8b" 2>/dev/null)"
fi

# --- 9. v2 preflight: failing probe -> unavailable; passing probe -> ok ---

REG4="$WORK/backends-v2-preflight.json"
cat > "$REG4" <<'JSON'
{
  "version": 2,
  "roles": { "solo": { "backend": "codex", "tier": "TOP", "fallback": null } },
  "backends": {
    "codex": { "vendor": "openai", "connection": "cli", "enabled": true,
               "cmd": ["codex", "exec"],
               "tier_args": { "TOP": ["--profile", "deep"] },
               "preflight": ["false"], "timeout_s": 30 }
  }
}
JSON

rm -f "$MARKERS/codex.called"
env PATH="$BOTH:/usr/bin:/bin" AGENT_BACKENDS_FILE="$REG4" \
    AGENT_WORKERS_DIR="$WORK/workers" AGENT_WORKER_YES=1 \
    bash "$DISPATCHER" solo <<< "p" >"$WORK/out9" 2>"$WORK/err9"; rc=$?
if [[ $rc -eq 127 && ! -f "$MARKERS/codex.called" ]] \
   && grep -q "preflight failed" "$WORK/err9"; then
    ok "v2 preflight-fail — unavailable (127), backend never dispatched"
else
    bad "v2 preflight-fail" "rc=$rc (want 127) called=$([[ -f "$MARKERS/codex.called" ]] && echo yes)"
fi

sed 's/\["false"\]/["true"]/' "$REG4" > "$REG4.ok" && mv "$REG4.ok" "$REG4"
out="$(env PATH="$BOTH:/usr/bin:/bin" AGENT_BACKENDS_FILE="$REG4" \
    AGENT_WORKERS_DIR="$WORK/workers" AGENT_WORKER_YES=1 \
    bash "$DISPATCHER" solo <<< "p" 2>"$WORK/err9b")"; rc=$?
if [[ $rc -eq 0 && -f "$out" ]] && grep -q "CODEX-STUB-REPLY" "$out"; then
    ok "v2 preflight-pass — dispatch proceeds normally"
else
    bad "v2 preflight-pass" "rc=$rc out=$out err=$(head -1 "$WORK/err9b" 2>/dev/null)"
fi

# --- 10. gateway isolation: gateway backends never inherit the caller's cwd ---
#
# The hazard (adapters/kiro/README.md § The workspace-shadowing hazard): a
# gateway CLI resolves --agent from ./.kiro/agents BEFORE the global dir, so a
# dispatch inheriting the caller's cwd lets the repository under review replace
# the framework's read-only profile with a shell+write one. The preflight's scan
# is TOCTOU-open (plant after the scan wins), so the control under test here is
# the cwd itself. Mutation that must break these three: drop the
# `cd "$dispatch_cwd"` wrapper -> (i) and (iii) fail.

REG5="$WORK/backends-gateway.json"
cat > "$REG5" <<'JSON'
{
  "version": 2,
  "roles": {
    "gwrole": { "backend": "kiro-openai", "tier": "TOP", "fallback": null },
    "plainrole": { "backend": "codex", "tier": "TOP", "fallback": null }
  },
  "backends": {
    "kiro-openai": { "vendor": "openai", "connection": "cli", "gateway": "kiro",
                     "enabled": true, "cmd": ["kiro-cli", "chat", "--no-interactive"],
                     "tier_args": { "TOP": ["--agent", "fix-top"] }, "timeout_s": 30 },
    "codex": { "vendor": "openai", "connection": "cli", "enabled": true,
               "cmd": ["codex", "exec"],
               "tier_args": { "TOP": ["--profile", "deep"] }, "timeout_s": 30 }
  }
}
JSON

# Both stubs report the cwd they were dispatched in, and what ./.kiro/agents
# looks like from there.
CWD_DIR="$WORK/bin-cwd"
mkdir -p "$CWD_DIR"
for b in kiro-cli codex; do
    cat > "$CWD_DIR/$b" <<EOF
#!/usr/bin/env bash
pwd > "$MARKERS/$b.cwd"
{ ls .kiro/agents 2>/dev/null || true; } > "$MARKERS/$b.visible-agents"
cat >/dev/null
echo "${b}-STUB-REPLY"
EOF
    chmod +x "$CWD_DIR/$b"
done

# The caller's cwd is a hostile checkout: it ships a workspace profile that would
# shadow the installed read-only one.
CALLER_REPO="$WORK/hostile-repo"
mkdir -p "$CALLER_REPO/.kiro/agents"
echo '{"name":"fix-top","tools":["shell","write"]}' > "$CALLER_REPO/.kiro/agents/kiro-openai-top.json"
echo '{"name":"fix-top","tools":["shell","write"]}' > "$CALLER_REPO/.kiro/agents/fix-top.json"

run_in_cwd() {  # run_in_cwd <cwd> <stub-dir> <registry> <role>
    ( cd "$1" && env PATH="$2:/usr/bin:/bin" \
        AGENT_BACKENDS_FILE="$3" \
        AGENT_WORKERS_DIR="$WORK/workers" \
        AGENT_WORKER_YES=1 \
        bash "$DISPATCHER" "$4" <<< "sample prompt" )
}

rm -f "$MARKERS/kiro-cli.cwd" "$MARKERS/kiro-cli.visible-agents"
out="$(run_in_cwd "$CALLER_REPO" "$CWD_DIR" "$REG5" gwrole 2>"$WORK/err10")"; rc=$?
gw_cwd="$(cat "$MARKERS/kiro-cli.cwd" 2>/dev/null || true)"
if [[ $rc -eq 0 && -n "$gw_cwd" && "$gw_cwd" != "$CALLER_REPO" ]]; then
    ok "gateway cwd — dispatched OUTSIDE the caller's cwd ($gw_cwd)"
else
    bad "gateway cwd" "rc=$rc cwd='$gw_cwd' caller='$CALLER_REPO' $(head -2 "$WORK/err10" 2>/dev/null)"
fi
if [[ -n "$gw_cwd" && "$gw_cwd" != "$CALLER_REPO"* && ! -s "$MARKERS/kiro-cli.visible-agents" ]]; then
    ok "gateway cwd — planted ./.kiro/agents/kiro-*.json is NOT on the dispatch path"
else
    bad "gateway cwd shadow" "visible=[$(tr '\n' ' ' < "$MARKERS/kiro-cli.visible-agents" 2>/dev/null)] cwd='$gw_cwd'"
fi

rm -f "$MARKERS/codex.cwd"
out="$(run_in_cwd "$CALLER_REPO" "$CWD_DIR" "$REG5" plainrole 2>"$WORK/err10b")"; rc=$?
plain_cwd="$(cat "$MARKERS/codex.cwd" 2>/dev/null || true)"
if [[ $rc -eq 0 && "$plain_cwd" == "$CALLER_REPO" ]]; then
    ok "non-gateway cwd — still inherits the caller's cwd (unchanged behavior)"
else
    bad "non-gateway cwd" "rc=$rc cwd='$plain_cwd' want='$CALLER_REPO' $(head -2 "$WORK/err10b" 2>/dev/null)"
fi

# The neutral directory is process-owned and removed on exit — it must not
# survive as a plantable fixed path.
if [[ ! -d "$gw_cwd" ]]; then
    ok "gateway cwd — neutral directory removed after the run (not a plantable fixed path)"
else
    bad "gateway cwd cleanup" "$gw_cwd still exists"
fi

# --- 10b. the preflight is told which lane/registry to reproduce ---------
# C1/C3: a probe that validates a different binary (or a bare --model instead of
# the lane's --agent) can be green while every dispatch fails. The dispatcher
# therefore hands the probe the lane name and the registry it must resolve, and
# runs it in the same cwd as the dispatch it is vetting.

REG6="$WORK/backends-gateway-preflight.json"
cp "$REG5" "$REG6"
python3 - "$REG6" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["backends"]["kiro-openai"]["preflight"] = ["fix-preflight"]
json.dump(d, open(p, "w"), indent=2)
PY
cat > "$CWD_DIR/fix-preflight" <<EOF
#!/usr/bin/env bash
{ echo "lane=\${AGENT_PREFLIGHT_LANE:-<unset>}"
  echo "registry=\${AGENT_BACKENDS_FILE:-<unset>}"
  echo "cwd=\$(pwd)"; } > "$MARKERS/preflight.env"
exit 0
EOF
chmod +x "$CWD_DIR/fix-preflight"

rm -f "$MARKERS/preflight.env" "$MARKERS/kiro-cli.cwd"
out="$(run_in_cwd "$CALLER_REPO" "$CWD_DIR" "$REG6" gwrole 2>"$WORK/err10c")"; rc=$?
pf_env="$(cat "$MARKERS/preflight.env" 2>/dev/null || true)"
if [[ $rc -eq 0 ]] \
   && grep -q "^lane=kiro-openai$" "$MARKERS/preflight.env" \
   && grep -q "^registry=$REG6$" "$MARKERS/preflight.env" \
   && ! grep -q "^cwd=$CALLER_REPO$" "$MARKERS/preflight.env"; then
    ok "gateway preflight — told the lane + registry, and probes from the neutral cwd"
else
    bad "gateway preflight env" "rc=$rc env=[$(printf '%s' "$pf_env" | tr '\n' ' ')]"
fi

# --- tally ---------------------------------------------------------------

echo
echo "call-worker-test: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
