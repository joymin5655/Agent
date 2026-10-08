#!/usr/bin/env bash
# codex-native-hooks-test.sh — W4 (XRH-02): Codex CLI native hook path.
#
# Codex (>= 0.157) runs command hooks from ~/.codex/hooks.json (or a plugin's
# hooks file) and feeds them Claude-shaped stdin: hook_event_name, tool_name,
# tool_input, tool_use_id, session_id, cwd, transcript_path. Two properties
# make a naive pass-through unsafe, and this battery pins both:
#
#   1. Fail-open runtime. Codex reports — then CONTINUES the tool call on — a
#      hook that exits non-zero (other than 2), times out, prints invalid JSON,
#      or returns an unsupported `permissionDecision: "ask"`. The adapter's
#      native mode therefore turns every PreToolUse failure and every canonical
#      `ask` into an explicit `deny` JSON on stdout (exit 0).
#   2. apply_patch carries the PATCH TEXT in tool_input.command (same field as
#      Bash). The adapter splits it into one canonical Write/Edit event per
#      file, runs the hook on each, and aggregates deny > ask > allow. A patch
#      with no recognizable file operation is denied (fail-closed).
#
# Also covers: MCP tool pass-through, non-PreToolUse events staying
# fail-open (observation hooks never block), and the shipped hooks.json
# template / plugin hooks file (valid events, existing hooks, identical wiring).
#
# Usage: bash core/tests/codex-native-hooks-test.sh
set -u
# X-5: keep this battery's gate records out of the live sink (caller-set seam wins)
export AGENT_GATE_SINK_DIR="${AGENT_GATE_SINK_DIR:-$(mktemp -d)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTER="$REPO_ROOT/adapters/codex/adapter.sh"
TRANSLATOR="$REPO_ROOT/adapters/codex/adapter.py"
TEMPLATE="$REPO_ROOT/adapters/codex/hooks.json.template"
PLUGIN_HOOKS="$REPO_ROOT/hooks/codex-hooks.json"

PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-native.XXXXXX")"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# Test-battery firings must not pollute live fire-rate logs (W1-4 origin tag).
export AGENT_REPRODUCE_TEST=1

# event <tool_name> <tool_input-json> [hook_event_name]
event() {
    _T="$1" _I="$2" _E="${3:-PreToolUse}" _CWD="$REPO_ROOT" python3 -c '
import json, os
print(json.dumps({
    "hook_event_name": os.environ["_E"], "session_id": "codex-test",
    "turn_id": "t1", "tool_use_id": "call_1", "cwd": os.environ["_CWD"],
    "transcript_path": None, "model": "gpt-6-sol", "permission_mode": "default",
    "tool_name": os.environ["_T"], "tool_input": json.loads(os.environ["_I"]),
}))'
}

# patch_input <patch-text> -> {"command": "<patch>"}
patch_input() { _P="$1" python3 -c 'import json,os; print(json.dumps({"command": os.environ["_P"]}))'; }

# decision <raw-stdout> -> allow|ask|deny|advisory|MALFORMED
decision() {
    printf '%s' "$1" | python3 -c '
import sys, json
d = sys.stdin.read().strip()
if not d:
    print("allow"); sys.exit()
try:
    h = json.loads(d).get("hookSpecificOutput", {})
except Exception:
    print("MALFORMED"); sys.exit()
print(h.get("permissionDecision") or ("advisory" if "additionalContext" in h else "MALFORMED"))'
}

# expect <label> <hook> <want> <stdin-json>
expect() {
    local label="$1" hook="$2" want="$3" input="$4" raw got
    raw=$(printf '%s' "$input" | bash "$ADAPTER" "$hook" 2>/dev/null)
    got=$(decision "$raw")
    if [[ "$got" == "$want" ]]; then ok "$label"; else bad "$label" "want $want, got $got :: ${raw:0:200}"; fi
}

# Runtime-assembled secret-read fixture (no literal pattern in this source).
Z=""
SECRET_LINE="x = op${Z}en(\"secr${Z}ets/api.key\").read()"

echo "=== 1. Bash via native stdin ==="
expect "bash-secret-read-deny"  pre-tool-guard.sh deny  "$(event Bash '{"command":"cat secrets/foo.env"}')"
expect "bash-harmless-allow"    pre-tool-guard.sh allow "$(event Bash '{"command":"ls -la"}')"
# pre-tool-guard returns canonical `ask` for --no-verify. Codex would treat an
# `ask` as a hook error and RUN the command, so the adapter must send deny.
expect "bash-ask-becomes-deny"  pre-tool-guard.sh deny  "$(event Bash '{"command":"git commit --no-verify -m x"}')"
raw=$(printf '%s' "$(event Bash '{"command":"git commit --no-verify -m x"}')" | bash "$ADAPTER" pre-tool-guard.sh 2>/dev/null)
if printf '%s' "$raw" | grep -q 'approval'; then ok "ask-deny-reason-explains-retry"; else bad "ask-deny-reason-explains-retry" "${raw:0:200}"; fi
if printf '%s' "$raw" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="PreToolUse"' 2>/dev/null; then
    ok "ask-deny-is-single-valid-json"; else bad "ask-deny-is-single-valid-json" "${raw:0:200}"; fi

echo "=== 2. apply_patch split into per-file canonical events ==="
P_ADD_SECRET=$'*** Begin Patch\n*** Add File: app.py\n+'"$SECRET_LINE"$'\n*** End Patch'
P_ADD_CLEAN=$'*** Begin Patch\n*** Add File: app.py\n+print("hello")\n*** End Patch'
P_MULTI=$'*** Begin Patch\n*** Add File: ok.py\n+print(1)\n*** Update File: lib/util.py\n@@ def f():\n-    return 1\n+    '"$SECRET_LINE"$'\n*** End Patch'
P_UPDATE_REMOVES=$'*** Begin Patch\n*** Update File: app.py\n@@\n-'"$SECRET_LINE"$'\n+x = None\n*** End Patch'
P_DANGEROUS_TEXT=$'*** Begin Patch\n*** Add File: notes.md\n+never run rm -rf / or cat secrets/foo.env\n*** End Patch'
P_DELETE=$'*** Begin Patch\n*** Delete File: old.py\n*** End Patch'
P_EMPTY=$'*** Begin Patch\n*** End Patch'
P_GARBAGE='not a patch at all'

expect "patch-add-secret-deny"        secret-content-scan.py deny  "$(event apply_patch "$(patch_input "$P_ADD_SECRET")")"
expect "patch-add-clean-allow"        secret-content-scan.py allow "$(event apply_patch "$(patch_input "$P_ADD_CLEAN")")"
expect "patch-multi-file-deny-wins"   secret-content-scan.py deny  "$(event apply_patch "$(patch_input "$P_MULTI")")"
expect "patch-removed-line-not-new"   secret-content-scan.py allow "$(event apply_patch "$(patch_input "$P_UPDATE_REMOVES")")"
# The patch body is file CONTENT, not a shell command: pre-tool-guard (which
# reads tool_input.command) must not see it.
expect "patch-text-not-shell-command" pre-tool-guard.sh      allow "$(event apply_patch "$(patch_input "$P_DANGEROUS_TEXT")")"
expect "patch-delete-allow"           secret-content-scan.py allow "$(event apply_patch "$(patch_input "$P_DELETE")")"
expect "patch-no-ops-fail-closed"     secret-content-scan.py deny  "$(event apply_patch "$(patch_input "$P_EMPTY")")"
expect "patch-garbage-fail-closed"    secret-content-scan.py deny  "$(event apply_patch "$(patch_input "$P_GARBAGE")")"

echo "=== 3. MCP tool reaches the same core policy ==="
MCP_IN=$(_Q="select 1; -- $SECRET_LINE" python3 -c 'import json,os; print(json.dumps({"query": os.environ["_Q"]}))')
expect "mcp-secret-deny"  secret-content-scan.py deny  "$(event mcp__supabase__execute_sql "$MCP_IN")"
expect "mcp-clean-allow"  secret-content-scan.py allow "$(event mcp__supabase__execute_sql '{"query":"select 1"}')"

echo "=== 4. Translation shape (what the core hook actually receives) ==="
cat > "$WORK/dump.sh" <<'SH'
#!/usr/bin/env bash
cat >> "$DUMP_FILE"
printf '\n' >> "$DUMP_FILE"
SH
chmod +x "$WORK/dump.sh"
export DUMP_FILE="$WORK/dump.jsonl"
event apply_patch "$(patch_input "$P_MULTI")" | python3 "$TRANSLATOR" --run "$WORK/dump.sh" >/dev/null 2>&1
if _R="$REPO_ROOT" python3 - "$DUMP_FILE" <<'PY'
import json, os, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
root = os.environ["_R"]
assert len(rows) == 2, rows
a, b = rows
assert a["ai"] == "codex" and a["event"] == "PreToolUse" and a["hook_event_name"] == "PreToolUse"
assert a["tool_name"] == "Write" and a["tool_input"]["file_path"] == os.path.join(root, "ok.py")
assert a["tool_input"]["content"] == "print(1)\n"
assert b["tool_name"] == "Edit" and b["tool_input"]["file_path"] == os.path.join(root, "lib/util.py")
assert "return 1" in b["tool_input"]["old_string"] and "secr" in b["tool_input"]["new_string"]
assert a["tool_use_id"] == "call_1" and a["codex_tool_name"] == "apply_patch"
PY
then ok "apply-patch-canonical-shape"; else bad "apply-patch-canonical-shape" "$(cat "$DUMP_FILE" 2>/dev/null | head -c 400)"; fi

: > "$DUMP_FILE"
event Bash '{"command":"ls"}' | python3 "$TRANSLATOR" --run "$WORK/dump.sh" >/dev/null 2>&1
if python3 - "$DUMP_FILE" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 1 and rows[0]["tool_name"] == "Bash" and rows[0]["tool_input"] == {"command": "ls"}
assert rows[0]["ai"] == "codex" and rows[0]["event"] == "PreToolUse"
PY
then ok "bash-canonical-shape"; else bad "bash-canonical-shape" "$(head -c 300 "$DUMP_FILE")"; fi

echo "=== 5. Fail-closed on PreToolUse, fail-open on observation events ==="
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' > "$WORK/crash.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "blocked by test" >&2\nexit 2\n' > "$WORK/exit2.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "not json"\n' > "$WORK/junk.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$WORK/silent.sh"
chmod +x "$WORK"/*.sh
run_direct() { printf '%s' "$2" | python3 "$TRANSLATOR" --run "$1" 2>/dev/null; }
PRE_BASH="$(event Bash '{"command":"ls"}')"
POST_BASH="$(event Bash '{"command":"ls"}' PostToolUse)"
if [[ "$(decision "$(run_direct "$WORK/crash.sh" "$PRE_BASH")")" == deny ]]; then ok "crash-pre-deny"; else bad "crash-pre-deny" "hook exit 1 must fail closed"; fi
out=$(run_direct "$WORK/exit2.sh" "$PRE_BASH")
if [[ "$(decision "$out")" == deny ]] && printf '%s' "$out" | grep -q 'blocked by test'; then ok "exit2-pre-deny-with-stderr-reason"; else bad "exit2-pre-deny-with-stderr-reason" "${out:0:200}"; fi
if [[ "$(decision "$(run_direct "$WORK/junk.sh" "$PRE_BASH")")" == deny ]]; then ok "invalid-json-pre-deny"; else bad "invalid-json-pre-deny" "unparseable stdout must fail closed"; fi
if [[ "$(decision "$(run_direct "$WORK/silent.sh" "$PRE_BASH")")" == allow ]]; then ok "silent-pre-allow"; else bad "silent-pre-allow" "empty stdout = pass"; fi
out=$(run_direct "$WORK/crash.sh" "$POST_BASH"); rc=$?
if [[ -z "$out" && $rc -eq 0 ]]; then ok "crash-post-stays-open"; else bad "crash-post-stays-open" "rc=$rc out=${out:0:100}"; fi
# A guard missing from the checkout: Codex would run the tool if nothing answered.
out=$(printf '%s' "$PRE_BASH" | bash "$ADAPTER" no-such-hook.sh 2>/dev/null); rc=$?
if [[ "$(decision "$out")" == deny && $rc -eq 0 ]]; then ok "missing-hook-pre-deny"; else bad "missing-hook-pre-deny" "rc=$rc ${out:0:120}"; fi
out=$(printf '%s' "$POST_BASH" | bash "$ADAPTER" no-such-hook.sh 2>/dev/null); rc=$?
if [[ -z "$out" && $rc -eq 0 ]]; then ok "missing-hook-post-silent"; else bad "missing-hook-post-silent" "rc=$rc"; fi
# No python3 on PATH: static deny for a native PreToolUse.
mkdir -p "$WORK/nopy"
for b in bash cat dirname; do ln -sf "$(command -v "$b")" "$WORK/nopy/$b"; done
out=$(printf '%s' "$PRE_BASH" | PATH="$WORK/nopy" "$WORK/nopy/bash" "$ADAPTER" pre-tool-guard.sh 2>/dev/null)
if [[ "$(decision "$out")" == deny ]]; then ok "no-python-pre-deny"; else bad "no-python-pre-deny" "${out:0:120}"; fi
# Non-UTF-8 bytes in stdin must not crash the adapter into a fail-open exit.
out=$({ printf '%s' "${PRE_BASH%\}}"; printf ',"x":"\xff\xfe"}'; } | bash "$ADAPTER" pre-tool-guard.sh 2>/dev/null); rc=$?
if [[ $rc -eq 0 && "$(decision "$out")" != MALFORMED ]]; then ok "non-utf8-stdin-no-crash"; else bad "non-utf8-stdin-no-crash" "rc=$rc ${out:0:120}"; fi
# One time budget across all files of a patch (not per file): a slow guard on a
# multi-file patch is denied once the budget is spent, never left to Codex's timeout.
printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 1\n' > "$WORK/slow.sh"; chmod +x "$WORK/slow.sh"
P_THREE=$'*** Begin Patch\n*** Add File: a.py\n+1\n*** Add File: b.py\n+2\n*** Add File: c.py\n+3\n*** End Patch'
out=$(event apply_patch "$(patch_input "$P_THREE")" | AGENT_CODEX_PRE_BUDGET_S=1.5 python3 "$TRANSLATOR" --run "$WORK/slow.sh" 2>/dev/null)
if [[ "$(decision "$out")" == deny ]] && printf '%s' "$out" | grep -qE 'budget|timed out'; then ok "shared-time-budget-deny"; else bad "shared-time-budget-deny" "${out:0:160}"; fi
out=$(printf '%s' '{"hook_event_name":' | python3 "$TRANSLATOR" --run "$WORK/silent.sh" 2>/dev/null)
if [[ "$(decision "$out")" == deny ]]; then ok "malformed-stdin-pre-deny"; else bad "malformed-stdin-pre-deny" "${out:0:120}"; fi
# A deny carrying a field Codex does not support (continue/suppressOutput) would
# make Codex skip the decision; the adapter re-emits only the documented keys,
# ASCII-escaped so no locale can break the write.
cat > "$WORK/fancy-deny.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"continue": true, "suppressOutput": true, "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "nope — café"}}'
SH
chmod +x "$WORK/fancy-deny.sh"
out=$(run_direct "$WORK/fancy-deny.sh" "$PRE_BASH")
if printf '%s' "$out" | LC_ALL=C python3 -c '
import json, sys
raw = sys.stdin.buffer.read()
raw.decode("ascii")
d = json.loads(raw)
assert set(d) == {"hookSpecificOutput"}, d
h = d["hookSpecificOutput"]
assert set(h) == {"hookEventName", "permissionDecision", "permissionDecisionReason"}, h
assert h["permissionDecision"] == "deny" and "café" in h["permissionDecisionReason"]' 2>/dev/null
then ok "deny-reemitted-minimal-ascii"; else bad "deny-reemitted-minimal-ascii" "${out:0:200}"; fi
# An indented marker is ambiguous (hunk context line vs lenient header): the
# lines after it could be credited to the wrong file, so the patch is denied.
P_INDENTED=$'*** Begin Patch\n  *** Add File: app.py\n+'"$SECRET_LINE"$'\n*** End Patch'
expect "patch-indented-marker-deny" secret-content-scan.py deny "$(event apply_patch "$(patch_input "$P_INDENTED")")"
P_CTX_SMUGGLE=$'*** Begin Patch\n*** Update File: src/config.py\n@@\n *** Add File: tests/x.py\n+x = 1\n*** End Patch'
expect "patch-context-marker-smuggle-deny" pre-tool-guard.sh deny "$(event apply_patch "$(patch_input "$P_CTX_SMUGGLE")")"
# Paths are normalized before hooks see them (tests/../ must not look like tests/).
: > "$DUMP_FILE"
P_DOTDOT=$'*** Begin Patch\n*** Add File: tests/../src/k.py\n+1\n*** End Patch'
event apply_patch "$(patch_input "$P_DOTDOT")" | python3 "$TRANSLATOR" --run "$WORK/dump.sh" >/dev/null 2>&1
if grep -q "\"$REPO_ROOT/src/k.py\"" "$DUMP_FILE"; then ok "patch-path-normalized"; else bad "patch-path-normalized" "$(head -c 300 "$DUMP_FILE")"; fi
# Move to: the destination is checked with the SOURCE file's content too.
mkdir -p "$WORK/mv"; printf '%s\n' "$SECRET_LINE" > "$WORK/mv/fixture.py"
MV_EVENT=$(_P=$'*** Begin Patch\n*** Update File: fixture.py\n*** Move to: app.py\n@@\n+# moved\n*** End Patch' _W="$WORK/mv" python3 -c '
import json, os
print(json.dumps({"hook_event_name": "PreToolUse", "cwd": os.environ["_W"], "tool_name": "apply_patch",
                  "tool_input": {"command": os.environ["_P"]}}))')
out=$(printf '%s' "$MV_EVENT" | bash "$ADAPTER" secret-content-scan.py 2>/dev/null)
if [[ "$(decision "$out")" == deny ]]; then ok "patch-move-checks-source-content"; else bad "patch-move-checks-source-content" "${out:0:160}"; fi
# File-count cap: denied up front rather than racing the time budget.
P_MANY=$(python3 -c 'print("*** Begin Patch\n" + "".join(f"*** Add File: f{i}.py\n+{i}\n" for i in range(101)) + "*** End Patch")')
expect "patch-file-cap-deny" secret-content-scan.py deny "$(event apply_patch "$(patch_input "$P_MANY")")"

echo "=== 6. Shipped wiring: hooks.json template + plugin hooks file ==="
if python3 - "$TEMPLATE" "$PLUGIN_HOOKS" "$REPO_ROOT" <<'PY'
import json, os, re, sys
tpl_path, plug_path, root = sys.argv[1:4]
tpl_raw, plug_raw = open(tpl_path).read(), open(plug_path).read()
tpl, plug = json.loads(tpl_raw), json.loads(plug_raw)
codex_events = {"SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreToolUse",
                "PostToolUse", "PermissionRequest", "PreCompact", "PostCompact",
                "UserPromptSubmit", "Stop", "Interrupt"}
assert set(tpl["hooks"]) <= codex_events, set(tpl["hooks"]) - codex_events
for ev in ("PreToolUse", "PostToolUse", "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"):
    assert ev in tpl["hooks"], ev
matchers, cmd_re = {}, re.compile(r'^"\{\{FRAMEWORK_ROOT\}\}/adapters/codex/adapter\.sh" (\S+)$')
for ev, groups in tpl["hooks"].items():
    for g in groups:
        for h in g["hooks"]:
            assert h["type"] == "command", h
            if ev == "PreToolUse":  # must exceed adapter.py PRE_TOOL_TIMEOUT_S (25)
                assert isinstance(h.get("timeout"), int) and h["timeout"] > 25, h
            m = cmd_re.match(h["command"]); assert m, h["command"]
            hook = os.path.join(root, "core/hooks", m.group(1))
            assert os.access(hook, os.X_OK), hook
            matchers.setdefault(ev, {}).setdefault(g.get("matcher", "*"), []).append(m.group(1))
pre = matchers["PreToolUse"]
assert "pre-tool-guard.sh" in pre["^Bash$"]
assert "secret-content-scan.py" in pre["^apply_patch$"]
assert any("secret-content-scan.py" in v for k, v in pre.items() if k.startswith("^mcp__"))
assert "session-close.sh" in matchers["SessionEnd"]["*"]
# A Bash-only guard must never match apply_patch (its tool_input.command is patch text).
for k, v in pre.items():
    if "pre-tool-guard.sh" in v:
        assert not re.search(k, "apply_patch"), k
# Plugin hooks file = template with the install root swapped for $PLUGIN_ROOT.
assert plug_raw == tpl_raw.replace("{{FRAMEWORK_ROOT}}", "${PLUGIN_ROOT}"), "plugin hooks drifted from template"
PY
then ok "template-and-plugin-wiring"; else bad "template-and-plugin-wiring" "see traceback above"; fi

# Council findings (2026-09-27): unknown decision verbs, PostToolUse fan-out, FIFO move source.
printf '#!/usr/bin/env bash\ncat >/dev/null\necho %s\n' "'{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"defer\"}}'" > "$WORK/odd.sh"
chmod +x "$WORK/odd.sh"
if [[ "$(decision "$(run_direct "$WORK/odd.sh" "$PRE_BASH")")" == deny ]]; then ok "unknown-decision-deny"; else bad "unknown-decision-deny" "unknown verb must fail closed"; fi
: > "$DUMP_FILE"
event apply_patch "$(patch_input "$P_MULTI")" PostToolUse | python3 "$TRANSLATOR" --run "$WORK/dump.sh" >/dev/null 2>&1
if [[ "$(grep -c . "$DUMP_FILE")" -eq 2 ]]; then ok "post-tool-use-runs-every-file"; else bad "post-tool-use-runs-every-file" "$(grep -c . "$DUMP_FILE") events"; fi
mkfifo "$WORK/mv/pipe.py"
FIFO_EVENT=$(_P=$'*** Begin Patch\n*** Update File: pipe.py\n*** Move to: out.py\n@@\n+x\n*** End Patch' _W="$WORK/mv" python3 -c '
import json, os
print(json.dumps({"hook_event_name": "PreToolUse", "cwd": os.environ["_W"], "tool_name": "apply_patch",
                  "tool_input": {"command": os.environ["_P"]}}))')
out=$(printf '%s' "$FIFO_EVENT" | AGENT_CODEX_PRE_BUDGET_S=5 bash "$ADAPTER" secret-content-scan.py 2>/dev/null)
if [[ "$(decision "$out")" == deny ]]; then ok "move-fifo-source-deny"; else bad "move-fifo-source-deny" "${out:0:160}"; fi

echo "=== 7. merge-hooks.py: other tools' hooks survive, idempotent, safe root only ==="
MERGE="$REPO_ROOT/adapters/codex/merge-hooks.py"
MH="$WORK/merge"; mkdir -p "$MH"
printf '{"x":1,"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"other-tool session"}]}],"PreToolUse":[{"matcher":"^Bash$","hooks":[{"type":"command","command":"\\"/old/checkout/adapters/codex/adapter.sh\\" pre-tool-guard.sh"}]}]}}' > "$MH/hooks.json"
python3 "$MERGE" "$TEMPLATE" "$REPO_ROOT" "$MH/hooks.json" >/dev/null
second=$(python3 "$MERGE" "$TEMPLATE" "$REPO_ROOT" "$MH/hooks.json")
if _R="$REPO_ROOT" python3 - "$MH/hooks.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for gs in d["hooks"].values() for g in gs for h in g["hooks"]]
assert d["x"] == 1 and "other-tool session" in cmds, "foreign entries must survive"
assert not any("/old/checkout/" in c for c in cmds), "stale Agent entries must be replaced"
assert sum("pre-tool-guard.sh" in c for c in cmds) == 1, "no duplicate Agent entries"
assert all(os.environ["_R"] in c for c in cmds if "adapter.sh" in c)
PY
then ok "merge-preserves-foreign-replaces-stale"; else bad "merge-preserves-foreign-replaces-stale" "see traceback"; fi
if [[ "$second" == *up-to-date* ]]; then ok "merge-idempotent"; else bad "merge-idempotent" "$second"; fi
cp "$MH/hooks.json" "$MH/before.json"
if ! python3 "$MERGE" "$TEMPLATE" '/tmp/a"b' "$MH/hooks.json" 2>/dev/null && cmp -s "$MH/hooks.json" "$MH/before.json"; then
    ok "merge-refuses-shell-active-root"; else bad "merge-refuses-shell-active-root" "unsafe root accepted or file changed"; fi

echo
echo "=== codex-native-hooks: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
