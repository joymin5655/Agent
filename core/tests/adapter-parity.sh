#!/usr/bin/env bash
# adapter-parity.sh — cross-AI parity gate.
#
# The "same core hook, same decision under all 3 AIs" promise (README §Cross-AI
# parity; docs/ai-adapters.md §Cross-AI parity guarantee) is only real if it is
# tested. For each logically-identical event this feeds all three adapters —
# claude-code (native = canonical JSON on stdin), codex and gemini (native =
# --tool/--command/--file flags, translated to canonical) — through the SAME core
# hook and asserts, per scenario:
#   (a) parity  — the three adapters return the SAME normalized decision
#                 (allow/ask/deny). A drift where one adapter alone diverges fails.
#   (b) decision — that agreed decision matches the expected one (correctness).
#   (c) strict  — the FULL decision JSON (incl. reason) is byte-identical across
#                 the three, so a reason/field drift is caught, not just the verb.
# Unlike the prior version (which only checked a "deny" substring per adapter,
# independently — two adapters could both contain "deny" yet disagree on the rest),
# this compares the decisions to each other. Exit 1 on any mismatch.
#
# The matrix drives BOTH tool_input shapes through a hook that ACTS on that shape,
# so a mistranslated field actually changes the decision (a shape whose field no
# hook reads would make its parity check vacuous):
#   - command shape  -> pre-tool-guard.sh (reads tool_input.command): deny/allow/ask.
#   - file/content   -> check-hardcoding.py (reads tool_input.file_path + .content):
#                       deny on hardcoded content, allow on clean — so a dropped or
#                       mistranslated content field flips the decision and is caught.
# The quoted scenarios are also regression guards for the adapter injection fix (a
# command/content with a quote must not break canonical-JSON construction or bypass
# the gate).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_ADAPTER="$REPO_ROOT/adapters/claude-code/adapter.sh"
CODEX_ADAPTER="$REPO_ROOT/adapters/codex/adapter.sh"
GEMINI_ADAPTER="$REPO_ROOT/adapters/gemini/adapter.sh"

PASS=0
FAIL=0
_ok() { echo "    ok   $1"; PASS=$((PASS + 1)); }
_no() { echo "    FAIL $1"; FAIL=$((FAIL + 1)); }

# norm — reduce an adapter's raw stdout to a single decision verb.
#   empty stdout            -> "allow" (silent pass)
#   {...permissionDecision} -> that value (allow|ask|deny)
#   {...additionalContext}  -> "advisory" (dryrun-mode gates emit context, no decision)
#   anything unparseable    -> "MALFORMED" (so a drift fails loudly, never silently)
norm() {
    python3 -c '
import sys, json
d = sys.stdin.read().strip()
if not d:
    print("allow")
else:
    try:
        h = json.loads(d).get("hookSpecificOutput", {})
        if "permissionDecision" in h:
            print(h["permissionDecision"])
        elif "additionalContext" in h:
            print("advisory")
        else:
            print("MALFORMED")
    except Exception:
        print("MALFORMED")'
}

# njson — normalize the FULL decision JSON for strict cross-adapter comparison.
#   empty -> "" ; valid JSON -> sorted-key compaction ; invalid -> "MALFORMED".
njson() {
    python3 -c '
import sys, json
d = sys.stdin.read().strip()
if not d:
    print("")
else:
    try:
        print(json.dumps(json.loads(d), sort_keys=True))
    except Exception:
        print("MALFORMED")'
}

# parity_case <label> <hook> <expected> <tool> <command> <file> <content>
# Builds each adapter's NATIVE input from one logical (tool, command, file, content)
# tuple — claude gets canonical JSON (constructed safely, via env, not string
# interpolation), codex/gemini get their native flags — then runs <hook> and
# compares decisions. Hook stderr is discarded; only the decision JSON on stdout is
# compared.
parity_case() {
    local label="$1" hook="$2" expected="$3" tool="$4" cmd="$5" file="$6" content="$7"

    local cjson
    cjson=$(_T="$tool" _C="$cmd" _F="$file" _CT="$content" python3 -c '
import json, os
ti = {}
if os.environ.get("_C"):  ti["command"]   = os.environ["_C"]
if os.environ.get("_F"):  ti["file_path"] = os.environ["_F"]
if os.environ.get("_CT"): ti["content"]   = os.environ["_CT"]
print(json.dumps({"event": "PreToolUse", "tool_name": os.environ["_T"], "tool_input": ti}))')

    local flags=(--tool "$tool")
    [[ -n "$cmd" ]]     && flags+=(--command "$cmd")
    [[ -n "$file" ]]    && flags+=(--file "$file")
    [[ -n "$content" ]] && flags+=(--content "$content")

    local c_raw co_raw g_raw c_dec co_dec g_dec
    c_raw=$(printf '%s' "$cjson" | bash "$CLAUDE_ADAPTER" "$hook" 2>/dev/null)
    co_raw=$(bash "$CODEX_ADAPTER" "$hook" "${flags[@]}" 2>/dev/null)
    g_raw=$(bash "$GEMINI_ADAPTER" "$hook" "${flags[@]}" 2>/dev/null)
    c_dec=$(printf '%s' "$c_raw" | norm)
    co_dec=$(printf '%s' "$co_raw" | norm)
    g_dec=$(printf '%s' "$g_raw" | norm)

    printf '  %-22s claude=%-9s codex=%-9s gemini=%-9s (want %s)\n' \
        "$label" "$c_dec" "$co_dec" "$g_dec" "$expected"

    if [[ "$c_dec" == "$co_dec" && "$co_dec" == "$g_dec" && "$c_dec" != "MALFORMED" ]]; then
        _ok "parity:$label"
    else
        _no "parity:$label — adapters disagree or malformed (claude=$c_dec codex=$co_dec gemini=$g_dec)"
    fi

    if [[ "$c_dec" == "$expected" ]]; then
        _ok "decision:$label"
    else
        _no "decision:$label — got '$c_dec', want '$expected'"
    fi

    local c_n co_n g_n
    c_n=$(printf '%s' "$c_raw" | njson)
    co_n=$(printf '%s' "$co_raw" | njson)
    g_n=$(printf '%s' "$g_raw" | njson)
    if [[ "$c_n" == "$co_n" && "$co_n" == "$g_n" ]]; then
        _ok "strict:$label"
    else
        _no "strict:$label — full decision JSON differs across adapters"
    fi
}

echo "=== Cross-AI parity: same event -> same decision across claude-code / codex / gemini ==="
echo "--- command shape (pre-tool-guard.sh reads tool_input.command) ---"
#            label                  hook                 expect  tool   command                         file  content
parity_case "deny-secrets-bash"     pre-tool-guard.sh    deny    Bash   "cat secrets/foo.env"           ""    ""
parity_case "allow-harmless-bash"   pre-tool-guard.sh    allow   Bash   "ls -la"                        ""    ""
parity_case "ask-no-verify-bash"    pre-tool-guard.sh    ask     Bash   "git commit --no-verify -m x"   ""    ""
parity_case "deny-destructive-bash" pre-tool-guard.sh    deny    Bash   "rm -rf /"                      ""    ""
parity_case "allow-quoted-bash"     pre-tool-guard.sh    allow   Bash   "echo it's fine"                ""    ""
parity_case "deny-quoted-secrets"   pre-tool-guard.sh    deny    Bash   "cat secrets/a.env # it's mine" ""    ""
echo "--- file/content shape (check-hardcoding.py reads tool_input.file_path + .content) ---"
# 2026-07-27 guard-trim: check-hardcoding defaults to dryrun (advisory); the
# deny path is opt-in via AGENT_HARDCODING_MODE=block. Cover both across all
# three adapters. Firings are sunk to a scratch file + marked reproduce_test
# so parity runs never pollute the live fire-rate log. Fixture content is
# runtime-assembled via an empty ${Z} splice so no literal hardcoding pattern
# appears in this source (same precedent as check-hardcoding-test.sh).
Z=""
HC_FIXTURE="const seg = [5,${Z} [255, 0, 0]]"
_HC_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/parity-hc.XXXXXX")" || { echo "FATAL: mktemp failed"; exit 1; }
export AGENT_HARDCODING_SINK="$_HC_SCRATCH/hardcoding.jsonl"
export AGENT_REPRODUCE_TEST=1
export AGENT_HARDCODING_MODE=block
parity_case "deny-hardcoded-content" check-hardcoding.py deny    Write  ""  "app.js"  "$HC_FIXTURE"
unset AGENT_HARDCODING_MODE   # unset = the shipped default (dryrun/advisory)
parity_case "advisory-hardcoded-default" check-hardcoding.py advisory Write "" "app.js" "$HC_FIXTURE"
parity_case "allow-quoted-content"   check-hardcoding.py allow   Write  ""  "app.js"  "const s = \"it's 100% fine\""
unset AGENT_HARDCODING_SINK
rm -rf "$_HC_SCRATCH"

# native_case <label> <hook> <expected> <claude-canonical-json> <codex-native-json>
# Codex >= 0.157 native hooks (W4): the codex adapter receives Codex's OWN stdin
# (hook_event_name, apply_patch patch text in tool_input.command, mcp__ names),
# not the synthetic flags above. The logically-identical Claude event must reach
# the same decision. Deliberate asymmetry: Codex cannot `ask` (it errors and runs
# the tool), so a canonical ask is expected as deny on the codex side only.
native_case() {
    local label="$1" hook="$2" expected="$3" cjson="$4" xjson="$5" c_dec x_dec x_want="$3"
    [[ "$expected" == "ask" ]] && x_want="deny"
    c_dec=$(printf '%s' "$cjson" | bash "$CLAUDE_ADAPTER" "$hook" 2>/dev/null | norm)
    x_dec=$(printf '%s' "$xjson" | bash "$CODEX_ADAPTER" "$hook" 2>/dev/null | norm)
    printf '  %-22s claude=%-9s codex-native=%-9s (want %s / %s)\n' "$label" "$c_dec" "$x_dec" "$expected" "$x_want"
    if [[ "$c_dec" == "$expected" && "$x_dec" == "$x_want" ]]; then
        _ok "native:$label"
    else
        _no "native:$label — claude=$c_dec codex-native=$x_dec"
    fi
}

echo "--- codex native stdin (Bash / apply_patch / mcp) vs claude canonical ---"
Z=""
NATIVE_SECRET="x = op${Z}en(\"secr${Z}ets/api.key\").read()"
nx() { _T="$1" _I="$2" python3 -c 'import json,os; print(json.dumps({"hook_event_name":"PreToolUse","session_id":"parity","cwd":os.getcwd(),"tool_use_id":"c1","tool_name":os.environ["_T"],"tool_input":json.loads(os.environ["_I"])}))'; }
nc() { _T="$1" _I="$2" python3 -c 'import json,os; print(json.dumps({"event":"PreToolUse","tool_name":os.environ["_T"],"tool_input":json.loads(os.environ["_I"])}))'; }
jin() { _S="$1" python3 -c 'import json,os,sys; print(json.dumps({sys.argv[1]: os.environ["_S"]}))' "$2"; }
PATCH=$'*** Begin Patch\n*** Add File: app.py\n+'"$NATIVE_SECRET"$'\n*** End Patch'
native_case "native-bash-deny" pre-tool-guard.sh deny \
    "$(nc Bash '{"command":"cat secrets/foo.env"}')" "$(nx Bash '{"command":"cat secrets/foo.env"}')"
native_case "native-bash-ask"  pre-tool-guard.sh ask \
    "$(nc Bash '{"command":"git commit --no-verify -m x"}')" "$(nx Bash '{"command":"git commit --no-verify -m x"}')"
native_case "native-patch-deny" secret-content-scan.py deny \
    "$(nc Write "$(_C="$NATIVE_SECRET" python3 -c 'import json,os; print(json.dumps({"file_path":"app.py","content":os.environ["_C"]+"\n"}))')")" \
    "$(nx apply_patch "$(jin "$PATCH" command)")"
native_case "native-mcp-deny" secret-content-scan.py deny \
    "$(nc mcp__supabase__execute_sql "$(jin "$NATIVE_SECRET" query)")" \
    "$(nx mcp__supabase__execute_sql "$(jin "$NATIVE_SECRET" query)")"
unset AGENT_REPRODUCE_TEST

echo
echo "=== Parity: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
