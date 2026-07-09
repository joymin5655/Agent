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
#   anything unparseable    -> "MALFORMED" (so a drift fails loudly, never silently)
norm() {
    python3 -c '
import sys, json
d = sys.stdin.read().strip()
if not d:
    print("allow")
else:
    try:
        print(json.loads(d).get("hookSpecificOutput", {}).get("permissionDecision", "MALFORMED"))
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
parity_case "deny-hardcoded-content" check-hardcoding.py deny    Write  ""  "app.js"  "const seg = [5, [255, 0, 0]]"
parity_case "allow-quoted-content"   check-hardcoding.py allow   Write  ""  "app.js"  "const s = \"it's 100% fine\""

echo
echo "=== Parity: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
