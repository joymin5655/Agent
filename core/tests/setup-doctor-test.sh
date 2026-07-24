#!/usr/bin/env bash
# setup-doctor-test.sh — verify `setup.sh --doctor` environment diagnosis.
#
# Covers: (a) exit 0 + summary-line format on the current repo (pure
# read-only — no side effects), (b) gitleaks WARN when PATH excludes it,
# (c) exit 1 + a named FAIL line when a hook script loses its executable
# bit (exercised against a throwaway copy in mktemp — the real repo tree
# is never touched).
#
# Usage: bash core/tests/setup-doctor-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then
    echo "  ok   [$name]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name]"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== (a) --doctor on the current repo: exit 0 + summary line ==="
OUT_A="$(bash "$SETUP" --doctor 2>&1)"
RC_A=$?
[[ $RC_A -eq 0 ]]
check "exit-0-on-clean-repo" $?
[[ "$OUT_A" == *"doctor: "*" pass, "*" warn, "*" fail"* ]]
check "summary-line-format" $?
if [[ $RC_A -ne 0 ]]; then
  echo "  --- doctor output (for diagnosis) ---"
  echo "$OUT_A" | sed 's/^/  | /'
fi

echo
echo "=== (b) gitleaks WARN when PATH excludes it ==="
OUT_B="$(PATH=/usr/bin:/bin bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_B" == *"[WARN"*"gitleaks"* ]]
check "gitleaks-warn-without-path" $?

echo
echo "=== (c) missing hook executable bit -> exit 1 + FAIL line naming it ==="
TMP_COPY="$(mktemp -d)"
cp -R "$REPO_ROOT"/. "$TMP_COPY"/
chmod -x "$TMP_COPY/core/hooks/pre-tool-guard.sh"
OUT_C="$(bash "$TMP_COPY/setup.sh" --doctor 2>&1)"
RC_C=$?
rm -rf "$TMP_COPY"
[[ $RC_C -eq 1 ]]
check "exit-1-on-missing-exec-bit" $?
[[ "$OUT_C" == *"[FAIL"*"pre-tool-guard.sh"* ]]
check "fail-line-names-file" $?

echo
echo "=== (d) plugin cache: two cached versions of this harness -> WARN naming both ==="
CACHE_FIX="$(mktemp -d)"
mkdir -p "$CACHE_FIX/somemarket/agent-harness/0.1.0" "$CACHE_FIX/somemarket/agent-harness/0.2.0"
OUT_D="$(AGENT_PLUGIN_CACHE_ROOT="$CACHE_FIX" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_D" == *"[WARN"*"somemarket/agent-harness: 2 versions (0.1.0,0.2.0)"* ]]
check "dual-cache-warn" $?

echo
echo "=== (e) plugin cache: single version -> PASS ==="
rm -rf "$CACHE_FIX/somemarket/agent-harness/0.1.0"
OUT_E="$(AGENT_PLUGIN_CACHE_ROOT="$CACHE_FIX" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_E" == *"[PASS"*"all 1 cached plugin(s) single-version"* ]]
check "single-cache-pass" $?

echo
echo "=== (d2) plugin cache: THIRD-PARTY plugin dual version -> WARN naming that plugin ==="
mkdir -p "$CACHE_FIX/othermarket/some-plugin/1.0.0" "$CACHE_FIX/othermarket/some-plugin/1.1.0"
OUT_D2="$(AGENT_PLUGIN_CACHE_ROOT="$CACHE_FIX" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_D2" == *"[WARN"*"othermarket/some-plugin: 2 versions (1.0.0,1.1.0)"* ]]
check "thirdparty-dual-cache-warn" $?

echo
echo "=== (e2) plugin cache: multiple plugins, each single-version -> PASS with count ==="
rm -rf "$CACHE_FIX/othermarket/some-plugin/1.0.0"
OUT_E2="$(AGENT_PLUGIN_CACHE_ROOT="$CACHE_FIX" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_E2" == *"[PASS"*"all 2 cached plugin(s) single-version"* ]]
check "multi-plugin-single-pass" $?

echo
echo "=== (d3) plugin cache: stray file at version depth ignored, no crash ==="
touch "$CACHE_FIX/othermarket/some-plugin/README.md"
OUT_D3="$(AGENT_PLUGIN_CACHE_ROOT="$CACHE_FIX" bash "$SETUP" --doctor 2>&1)"
RC_D3=$?
[[ $RC_D3 -eq 0 && "$OUT_D3" == *"all 2 cached plugin(s) single-version"* ]]
check "stray-file-ignored" $?
rm -rf "$CACHE_FIX"

echo
echo "=== (f) hook manifest: declared == live -> reconciled PASS ==="
MF_FIX="$(mktemp -d)"
cat > "$MF_FIX/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"node \"/home/u/.claude/hooks/alpha-guard.js\""},
  {"type":"command","command":"bash \"/home/u/.claude/hooks/beta-state.sh\""}]}]}}
JSON
printf '# declared hooks\nalpha-guard.js\nbeta-state.sh\n' > "$MF_FIX/manifest"
OUT_F="$(AGENT_HOOK_MANIFEST="$MF_FIX/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_F" == *"[PASS"*"2 declared / 2 live hooks all reconciled"* ]]
check "manifest-reconciled-pass" $?

echo
echo "=== (g) hook manifest: drift both directions -> WARN with details ==="
printf 'alpha-guard.js\ngamma-missing.sh\n' > "$MF_FIX/manifest"
OUT_G="$(AGENT_HOOK_MANIFEST="$MF_FIX/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_G" == *"[WARN"*"drift"*"declared-but-not-live: gamma-missing.sh"* ]]
check "manifest-drift-warn-missing" $?
[[ "$OUT_G" == *"live-but-undeclared: beta-state.sh"* ]]
check "manifest-drift-warn-undeclared" $?
RC_G_OUT="$(AGENT_HOOK_MANIFEST="$MF_FIX/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX/settings.json" bash "$SETUP" --doctor >/dev/null 2>&1; echo $?)"
[[ "$RC_G_OUT" -eq 0 ]]
check "manifest-drift-is-warn-not-fail" $?
rm -rf "$MF_FIX"

echo
echo "=== (g2) hook manifest: structurally malformed settings -> clean WARN, no traceback ==="
MF_FIX2="$(mktemp -d)"
printf 'alpha-guard.js\n' > "$MF_FIX2/manifest"
printf '{"hooks":{"PreToolUse":"not-a-list"}}' > "$MF_FIX2/settings.json"
OUT_G2="$(AGENT_HOOK_MANIFEST="$MF_FIX2/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX2/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_G2" == *"[WARN"*"malformed hooks structure"* ]]
check "manifest-malformed-structure-warn" $?
[[ "$OUT_G2" != *"Traceback"* ]]
check "manifest-malformed-no-traceback" $?

echo
echo "=== (g3) hook manifest: UTF-8 BOM in manifest -> still reconciles ==="
printf '\xef\xbb\xbfalpha-guard.js\n' > "$MF_FIX2/manifest"
cat > "$MF_FIX2/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"node \"/home/u/.claude/hooks/alpha-guard.js\""}]}]}}
JSON
OUT_G3="$(AGENT_HOOK_MANIFEST="$MF_FIX2/manifest" AGENT_GLOBAL_SETTINGS="$MF_FIX2/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_G3" == *"[PASS"*"1 declared / 1 live hooks all reconciled"* ]]
check "manifest-bom-reconciles" $?
rm -rf "$MF_FIX2"

echo
echo "=== (h) hook manifest: absent -> check skipped, exit unaffected ==="
OUT_H="$(AGENT_HOOK_MANIFEST=/nonexistent/no-manifest bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_H" == *"hook manifest — none at /nonexistent/no-manifest (check skipped)"* ]]
check "manifest-absent-skip" $?

echo
echo "=== (i) commands scan: phantom script ref -> WARN naming file and ref, exit unaffected ==="
CMD_FIX="$(mktemp -d)"
mkdir -p "$CMD_FIX/commands"
printf 'Run the audit engine:\n\nnode scripts/phantom-engine.js repo --format json\n' > "$CMD_FIX/commands/ghost-cmd.md"
OUT_I="$(AGENT_COMMANDS_DIR="$CMD_FIX/commands" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_I" == *"[WARN"*"ghost-cmd.md -> scripts/phantom-engine.js"* ]]
check "phantom-ref-warn" $?
RC_I_OUT="$(AGENT_COMMANDS_DIR="$CMD_FIX/commands" bash "$SETUP" --doctor >/dev/null 2>&1; echo $?)"
[[ "$RC_I_OUT" -eq 0 ]]
check "phantom-ref-is-warn-not-fail" $?

echo
echo "=== (i2) commands scan: ref resolvable from runtime root -> PASS ==="
mkdir -p "$CMD_FIX/scripts"
touch "$CMD_FIX/scripts/phantom-engine.js"
OUT_I2="$(AGENT_COMMANDS_DIR="$CMD_FIX/commands" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_I2" == *"[PASS"*"commands scan — 1 command file(s), all script refs resolve"* ]]
check "resolvable-ref-pass" $?

echo
echo "=== (i3) commands scan: unexpanded \$VAR ref skipped -> still PASS ==="
printf 'bash ${CLAUDE_PLUGIN_ROOT}/tools/run.sh to start\n' > "$CMD_FIX/commands/var-cmd.md"
OUT_I3="$(AGENT_COMMANDS_DIR="$CMD_FIX/commands" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_I3" == *"[PASS"*"commands scan — 2 command file(s), all script refs resolve"* ]]
check "unexpanded-var-skipped" $?
rm -rf "$CMD_FIX"

echo
echo "=== (i5) commands scan: control chars in a phantom ref sanitized in output ==="
ESC_FIX="$(mktemp -d)"
mkdir -p "$ESC_FIX/commands"
printf 'node \x1b[2Jscripts/ghost.js run\n' > "$ESC_FIX/commands/esc-cmd.md"
OUT_I5="$(AGENT_COMMANDS_DIR="$ESC_FIX/commands" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_I5" == *"[WARN"*"esc-cmd.md"* ]]
check "control-char-ref-still-warns" $?
case "$OUT_I5" in
  *$'\x1b'*) check "control-char-stripped-from-output" 1 ;;
  *)         check "control-char-stripped-from-output" 0 ;;
esac
rm -rf "$ESC_FIX"

echo
echo "=== (i4) commands scan: commands dir absent -> check skipped ==="
OUT_I4="$(AGENT_COMMANDS_DIR=/nonexistent/cmds bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_I4" == *"commands scan — no commands dir at /nonexistent/cmds (check skipped)"* ]]
check "commands-dir-absent-skip" $?

echo
echo "=== (j) codex tier profiles: both present beside config -> PASS ==="
CODEX_FIX="$(mktemp -d)"
touch "$CODEX_FIX/config.toml" "$CODEX_FIX/quick.config.toml" "$CODEX_FIX/deep.config.toml"
OUT_J="$(CODEX_CONFIG="$CODEX_FIX/config.toml" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_J" == *"[PASS"*"codex tier profiles — quick/deep profiles present"* ]]
check "codex-profiles-present-pass" $?

echo
echo "=== (j2) codex tier profiles: one missing -> WARN naming it, warn != fail ==="
rm -f "$CODEX_FIX/deep.config.toml"
OUT_J2="$(CODEX_CONFIG="$CODEX_FIX/config.toml" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_J2" == *"[WARN"*"codex tier profiles — missing deep.config.toml"* ]]
check "codex-profile-missing-warn" $?
RC_J2="$(CODEX_CONFIG="$CODEX_FIX/config.toml" bash "$SETUP" --doctor >/dev/null 2>&1; echo $?)"
[[ "$RC_J2" -eq 0 ]]
check "codex-profile-missing-is-warn-not-fail" $?
rm -rf "$CODEX_FIX"

echo
echo "=== (j3) codex tier profiles: no codex config -> check skipped ==="
OUT_J3="$(CODEX_CONFIG=/nonexistent/codex/config.toml bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_J3" == *"codex tier profiles — no codex config at /nonexistent/codex/config.toml (check skipped)"* ]]
check "codex-config-absent-skip" $?

echo
echo "=== (k) codex wiring: brain MCP + wrapper wired to real files -> PASS ==="
CXW_FIX="$(mktemp -d)"
touch "$CXW_FIX/brain-mcp.py" "$CXW_FIX/codex-shell-wrap.sh"
cat > "$CXW_FIX/config.toml" <<EOF
[tools.shell]
command = "$CXW_FIX/codex-shell-wrap.sh"
[mcp_servers.brain]
command = "python3"
args = ["$CXW_FIX/brain-mcp.py"]
EOF
OUT_K="$(CODEX_CONFIG="$CXW_FIX/config.toml" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_K" == *"[PASS"*"codex wiring — brain MCP + shell wrapper wired"* ]]
check "codex-wired-pass" $?

echo
echo "=== (k2) codex wiring: brain MCP section absent -> WARN naming it, warn != fail ==="
cat > "$CXW_FIX/config.toml" <<EOF
[tools.shell]
command = "$CXW_FIX/codex-shell-wrap.sh"
EOF
OUT_K2="$(CODEX_CONFIG="$CXW_FIX/config.toml" bash "$SETUP" --doctor 2>&1)"
RC_K2=$?
[[ $RC_K2 -eq 0 && "$OUT_K2" == *"[WARN"*"codex wiring — not wired: brain MCP"* ]]
check "codex-unwired-warn" $?

echo
echo "=== (k3) codex wiring: wired path missing on disk -> FAIL + exit 1 ==="
cat > "$CXW_FIX/config.toml" <<EOF
[tools.shell]
command = "$CXW_FIX/codex-shell-wrap.sh"
[mcp_servers.brain]
command = "python3"
args = ["/nonexistent/brain-mcp.py"]
EOF
OUT_K3="$(CODEX_CONFIG="$CXW_FIX/config.toml" bash "$SETUP" --doctor 2>&1)"
RC_K3=$?
[[ $RC_K3 -eq 1 && "$OUT_K3" == *"[FAIL"*"codex wiring — wired path missing on disk: brain-mcp.py -> /nonexistent/brain-mcp.py"* ]]
check "codex-broken-wiring-fail" $?
rm -rf "$CXW_FIX"

echo
echo "=== (k5) codex wiring: header present but atypical path shape -> WARN not-wired, NO crash ==="
CXA_FIX="$(mktemp -d)"
touch "$CXA_FIX/codex-shell-wrap.sh"
cat > "$CXA_FIX/config.toml" <<EOF
[tools.shell]
command = "$CXA_FIX/codex-shell-wrap.sh"
[mcp_servers.brain]
command = "python3"
args = ["-m", "brain_mcp"]
EOF
OUT_K5="$(CODEX_CONFIG="$CXA_FIX/config.toml" bash "$SETUP" --doctor 2>&1)"
RC_K5=$?
[[ $RC_K5 -eq 0 && "$OUT_K5" == *"doctor: "*" pass,"* ]]
check "codex-atypical-no-crash" $?
[[ "$OUT_K5" == *"[WARN"*"codex wiring — not wired: brain MCP ([mcp_servers.brain] present but no quoted brain-mcp.py path"* ]]
check "codex-atypical-warns-not-wired" $?
rm -rf "$CXA_FIX"

echo
echo "=== (k4) codex wiring: control chars in a wired-but-missing path sanitized in output ==="
CXE_FIX="$(mktemp -d)"
touch "$CXE_FIX/codex-shell-wrap.sh"
printf '[tools.shell]\ncommand = "%s/codex-shell-wrap.sh"\n[mcp_servers.brain]\nargs = ["/nonexistent/\x1b[2Jx/brain-mcp.py"]\n' "$CXE_FIX" > "$CXE_FIX/config.toml"
OUT_K4="$(CODEX_CONFIG="$CXE_FIX/config.toml" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_K4" == *"[FAIL"*"codex wiring"* ]]
check "codex-escape-path-still-fails" $?
case "$OUT_K4" in
  *$'\x1b'"[2J"*) check "codex-escape-stripped-from-output" 1 ;;
  *)              check "codex-escape-stripped-from-output" 0 ;;
esac
rm -rf "$CXE_FIX"

echo
echo "=== (l) gemini wiring: brain MCP + wrapper wired to real files -> PASS ==="
GMW_FIX="$(mktemp -d)"
touch "$GMW_FIX/brain-mcp.py" "$GMW_FIX/gemini-shell-wrap.sh"
cat > "$GMW_FIX/settings.json" <<EOF
{"tools":{"shell":{"command":"$GMW_FIX/gemini-shell-wrap.sh"}},
 "mcpServers":{"brain":{"command":"python3","args":["$GMW_FIX/brain-mcp.py"]}}}
EOF
OUT_L="$(GEMINI_SETTINGS="$GMW_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_L" == *"[PASS"*"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-wired-pass" $?

echo
echo "=== (l2) gemini wiring: nothing wired -> WARN naming both, warn != fail ==="
printf '{"model":{"name":"g"}}' > "$GMW_FIX/settings.json"
OUT_L2="$(GEMINI_SETTINGS="$GMW_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_L2=$?
[[ $RC_L2 -eq 0 && "$OUT_L2" == *"[WARN"*"gemini wiring — not wired: brain MCP"*"shell wrapper"* ]]
check "gemini-unwired-warn" $?

echo
echo "=== (l3) gemini wiring: wired path missing on disk -> FAIL + exit 1; bad JSON -> WARN ==="
printf '{"mcpServers":{"brain":{"args":["/nonexistent/brain-mcp.py"]}},"tools":{"shell":{"command":"/nonexistent/gemini-shell-wrap.sh"}}}' > "$GMW_FIX/settings.json"
OUT_L3="$(GEMINI_SETTINGS="$GMW_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_L3=$?
[[ $RC_L3 -eq 1 && "$OUT_L3" == *"[FAIL"*"gemini wiring — wired path missing on disk"* ]]
check "gemini-broken-wiring-fail" $?
printf '{ not json' > "$GMW_FIX/settings.json"
OUT_L4="$(GEMINI_SETTINGS="$GMW_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_L4=$?
[[ $RC_L4 -eq 0 && "$OUT_L4" == *"[WARN"*"gemini wiring — settings parse failed"* ]]
check "gemini-bad-json-warn" $?

echo
echo "=== (l5) gemini wiring: \\u-escaped control chars in a wired path sanitized in output ==="
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["/nonexistent/\\u001b[2Jx/brain-mcp.py"]}}}' "$GMW_FIX" > "$GMW_FIX/settings.json"
touch "$GMW_FIX/gemini-shell-wrap.sh"
OUT_L5="$(GEMINI_SETTINGS="$GMW_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_L5" == *"[FAIL"*"gemini wiring"* ]]
check "gemini-escape-path-still-fails" $?
case "$OUT_L5" in
  *$'\x1b'"[2J"*) check "gemini-escape-stripped-from-output" 1 ;;
  *)              check "gemini-escape-stripped-from-output" 0 ;;
esac
rm -rf "$GMW_FIX"

echo
echo "=== (m) claude install path: plugin-only / shell-only -> PASS naming the path ==="
CIP_FIX="$(mktemp -d)"
mkdir -p "$CIP_FIX/cache/market/agent-harness/0.5.4"
OUT_M="$(AGENT_PLUGIN_CACHE_ROOT="$CIP_FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_M" == *"[PASS"*"claude install path — plugin"* ]]
check "claude-path-plugin-pass" $?
cat > "$CIP_FIX/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"/home/u/agent/adapters/claude-code/adapter.sh pre-tool-guard.sh"}]}]}}
JSON
OUT_M2="$(AGENT_PLUGIN_CACHE_ROOT="$CIP_FIX/empty-cache" AGENT_GLOBAL_SETTINGS="$CIP_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_M2" == *"[PASS"*"claude install path — shell install"* ]]
check "claude-path-shell-pass" $?

echo
echo "=== (m2) claude install path: both -> WARN double-run; neither -> WARN not wired ==="
OUT_M3="$(AGENT_PLUGIN_CACHE_ROOT="$CIP_FIX/cache" AGENT_GLOBAL_SETTINGS="$CIP_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_M3=$?
[[ $RC_M3 -eq 0 && "$OUT_M3" == *"[WARN"*"claude install path — BOTH"* ]]
check "claude-path-both-warn" $?
OUT_M4="$(AGENT_PLUGIN_CACHE_ROOT="$CIP_FIX/empty-cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json bash "$SETUP" --doctor 2>&1)"
RC_M4=$?
[[ $RC_M4 -eq 0 && "$OUT_M4" == *"[WARN"*"claude install path — neither"* ]]
check "claude-path-neither-warn" $?
rm -rf "$CIP_FIX"

echo
echo "=== (n) brain lint: strict-clean fixture store -> PASS; dangling edge -> WARN, warn != fail ==="
BRN_FIX="$(mktemp -d)"
REPO_ROOT="$REPO_ROOT" AGENT_BRAIN_DIR="$BRN_FIX" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/core/brain")
import store
for nid, ntype, edges in [("concept-a", "concept", {"topic-tag": ["topic-b"]}),
                          ("topic-b", "topic", {"topic-tag": ["concept-a"]})]:
    store.write_note(node_id=nid, note_type=ntype, title="t", body="b", edges=edges,
                     provenance={"ai": "claude", "session": "s", "generated_by": "brain-ingest",
                                 "source": "raw:x", "kind": "generated"})
PY
OUT_N="$(AGENT_BRAIN_DIR="$BRN_FIX" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_N" == *"[PASS"*"brain lint —"*"clean"* ]]
check "brain-strict-clean-pass" $?
cat > "$BRN_FIX/notes/concept/concept-dangle.md" <<'EOF'
---
id: concept-dangle
type: concept
title: "dangle"
status: growing
edges:
  supports: [[concept-ghost]]
provenance:
  ai: "claude"
  session: "s"
  generated_by: "brain-ingest"
  source: "raw:x"
  kind: "generated"
---

body
EOF
OUT_N2="$(AGENT_BRAIN_DIR="$BRN_FIX" bash "$SETUP" --doctor 2>&1)"
RC_N2=$?
[[ $RC_N2 -eq 0 && "$OUT_N2" == *"[WARN"*"brain lint —"*"promotion is blocked"* ]]
check "brain-dirty-warn-not-fail" $?
rm -rf "$BRN_FIX"

echo
echo "=== (n2) brain lint: no store -> check skipped ==="
OUT_N3="$(AGENT_BRAIN_DIR=/nonexistent/brain bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_N3" == *"brain lint — no store at /nonexistent/brain/notes (check skipped)"* ]]
check "brain-absent-skip" $?

echo
echo "=== (o) gh CLI: on PATH -> PASS with version; absent from PATH -> WARN, warn != fail ==="
OUT_O="$(bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_O" == *"[PASS"*"gh — gh version"* ]]
check "gh-present-pass" $?
OUT_O2="$(PATH=/usr/bin:/bin bash "$SETUP" --doctor 2>&1)"
RC_O2=$?
[[ $RC_O2 -eq 0 && "$OUT_O2" == *"[WARN"*"gh — not found"*"brew install gh"* ]]
check "gh-absent-warn-not-fail" $?

echo
echo "=== (p) brain MCP (plugin path): not a plugin-only install -> PASS skip ==="
BMP_FIX="$(mktemp -d)"
OUT_P="$(AGENT_PLUGIN_CACHE_ROOT="$BMP_FIX/empty-cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_P" == *"[PASS"*"brain MCP (plugin path) — not a plugin-only install"* ]]
check "brain-mcp-not-plugin-path-skip" $?

echo
echo "=== (p2) brain MCP (plugin path): plugin-only, no user config -> WARN with opt-in command ==="
mkdir -p "$BMP_FIX/cache/market/agent-harness/0.5.4"
OUT_P2="$(AGENT_PLUGIN_CACHE_ROOT="$BMP_FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json AGENT_CLAUDE_USER_CONFIG=/nonexistent/.claude.json bash "$SETUP" --doctor 2>&1)"
RC_P2=$?
[[ $RC_P2 -eq 0 && "$OUT_P2" == *"[WARN"*"brain MCP (plugin path) — no user config at"*"claude mcp add brain --scope user"* ]]
check "brain-mcp-plugin-no-user-config-warn" $?

echo
echo "=== (p3) brain MCP (plugin path): plugin-only, user config present but brain absent -> WARN, exit 0, file untouched ==="
printf '{"mcpServers":{"codegraph":{"command":"codegraph"}}}' > "$BMP_FIX/claude.json"
BEFORE_P3="$(cat "$BMP_FIX/claude.json")"
OUT_P3="$(AGENT_PLUGIN_CACHE_ROOT="$BMP_FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json AGENT_CLAUDE_USER_CONFIG="$BMP_FIX/claude.json" bash "$SETUP" --doctor 2>&1)"
RC_P3=$?
[[ $RC_P3 -eq 0 && "$OUT_P3" == *"[WARN"*"brain MCP (plugin path) — not registered; opt in with: claude mcp add brain --scope user"* ]]
check "brain-mcp-plugin-unregistered-warn" $?
AFTER_P3="$(cat "$BMP_FIX/claude.json")"
[[ "$BEFORE_P3" == "$AFTER_P3" ]]
check "brain-mcp-plugin-doctor-never-writes-user-config" $?

echo
echo "=== (p4) brain MCP (plugin path): registered but wrong target -> WARN naming the mismatch ==="
printf '{"mcpServers":{"brain":{"command":"python3","args":["/some/other/tool.py"]}}}' > "$BMP_FIX/claude.json"
OUT_P4="$(AGENT_PLUGIN_CACHE_ROOT="$BMP_FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json AGENT_CLAUDE_USER_CONFIG="$BMP_FIX/claude.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_P4" == *"[WARN"*"brain MCP (plugin path) — registered but does not point at brain-mcp.py"* ]]
check "brain-mcp-plugin-wrong-target-warn" $?

echo
echo "=== (p5) brain MCP (plugin path): registered correctly -> PASS naming the config ==="
printf '{"mcpServers":{"brain":{"command":"python3","args":["/opt/agent/core/brain/brain-mcp.py"]}}}' > "$BMP_FIX/claude.json"
OUT_P5="$(AGENT_PLUGIN_CACHE_ROOT="$BMP_FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json AGENT_CLAUDE_USER_CONFIG="$BMP_FIX/claude.json" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_P5" == *"[PASS"*"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-plugin-registered-pass" $?

echo
echo "=== (p6) brain MCP (plugin path): shell install (not plugin-only) -> PASS skip even with a cache present ==="
cat > "$BMP_FIX/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"/home/u/agent/adapters/claude-code/adapter.sh pre-tool-guard.sh"}]}]}}
JSON
OUT_P6="$(AGENT_PLUGIN_CACHE_ROOT="$BMP_FIX/empty-cache" AGENT_GLOBAL_SETTINGS="$BMP_FIX/settings.json" AGENT_CLAUDE_USER_CONFIG=/nonexistent/.claude.json bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_P6" == *"[PASS"*"brain MCP (plugin path) — not a plugin-only install"* ]]
check "brain-mcp-shell-install-skip" $?
rm -rf "$BMP_FIX"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
