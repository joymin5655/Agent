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

# safe_mktemp_d — `mktemp -d` guarded against a nonzero exit AND a captured
# empty/non-directory result (same shape as core/tests/plugin-path-install-test.sh).
# An unguarded FIX="$(mktemp -d)" that silently produced an empty string would turn
# every later `rm -rf "$FIX"` / `mkdir -p "$FIX/..."` in this file into an operation
# on cwd or on a literal relative path — exactly the mistake a temp-dir fixture must
# not make. Section (q) proves each guard arm rejects.
safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  printf '%s\n' "$d"
}

# Cleanup trap — SIGINT/SIGTERM (or an early `exit 1`) in the middle of any
# section used to leave whole fixture trees behind. track_fixture records ONLY
# directories this script actually got back from safe_mktemp_d, and the trap
# removes only those recorded entries, so it can never delete a path it did not
# create: an empty/unset value is refused at record time and re-checked at
# removal time. The per-section `rm -rf` calls stay (fixtures are freed as early
# as possible); the trap is the backstop for the abnormal exits.
FIXTURE_DIRS=()
track_fixture() {
  local d="${1:-}"
  [[ -n "$d" && "$d" != "/" && -d "$d" ]] || return 0
  FIXTURE_DIRS+=("$d")
}
cleanup_fixtures() {
  local d
  # bash 3.2 + set -u: "${arr[@]}" on an empty array is an unbound-variable error
  [[ ${#FIXTURE_DIRS[@]} -gt 0 ]] || return 0
  for d in "${FIXTURE_DIRS[@]}"; do
    [[ -n "$d" && "$d" != "/" && -d "$d" ]] || continue
    rm -rf "$d"
  done
}
trap cleanup_fixtures EXIT
# INT/TERM must also STOP: a handler that only cleaned up and returned would resume
# the interrupted section with its fixture tree already deleted.
trap 'cleanup_fixtures; exit 130' INT
trap 'cleanup_fixtures; exit 143' TERM

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
TMP_COPY="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (repo copy fixture)"; exit 1; }
track_fixture "$TMP_COPY"
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
CACHE_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (plugin cache fixture)"; exit 1; }
track_fixture "$CACHE_FIX"
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
MF_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (hook manifest fixture)"; exit 1; }
track_fixture "$MF_FIX"
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
MF_FIX2="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (hook manifest 2 fixture)"; exit 1; }
track_fixture "$MF_FIX2"
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
CMD_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (commands scan fixture)"; exit 1; }
track_fixture "$CMD_FIX"
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
ESC_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (commands escape fixture)"; exit 1; }
track_fixture "$ESC_FIX"
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
CODEX_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (codex tier profiles fixture)"; exit 1; }
track_fixture "$CODEX_FIX"
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
CXW_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (codex wiring fixture)"; exit 1; }
track_fixture "$CXW_FIX"
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
CXA_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (codex wiring anchor fixture)"; exit 1; }
track_fixture "$CXA_FIX"
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
CXE_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (codex escape fixture)"; exit 1; }
track_fixture "$CXE_FIX"
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
GMW_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (gemini fixture)"; exit 1; }
track_fixture "$GMW_FIX"
# the wired brain-mcp.py must RESOLVE to this framework's own core/brain/brain-mcp.py
# (check 16 compares canonical paths, not filename suffixes) — a bare `touch` of a
# same-named file in the fixture dir is a foreign server, not this one.
ln -sf "$REPO_ROOT/core/brain/brain-mcp.py" "$GMW_FIX/brain-mcp.py"
touch "$GMW_FIX/gemini-shell-wrap.sh"
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
echo "=== (l6) gemini wiring: brain-mcp.py identity is a RESOLVED-PATH match, not a filename suffix ==="
# REGRESSION: check 16 used `a.endswith("brain-mcp.py")`, so any arg merely ENDING in
# the filename ("--payload=brain-mcp.py", /tmp/attacker/brain-mcp.py) was accepted as
# THIS framework's brain MCP server. It now selects by basename and then requires the
# canonical resolved path to equal $FRAMEWORK_ROOT/core/brain/brain-mcp.py.
GMX_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (gemini identity fixture)"; exit 1; }
track_fixture "$GMX_FIX"
mkdir -p "$GMX_FIX/attacker"
touch "$GMX_FIX/gemini-shell-wrap.sh" "$GMX_FIX/attacker/brain-mcp.py" "$GMX_FIX/evil-brain-mcp.py"

# (l6.1) a bare suffix-only arg is not a path to the framework server -> not wired
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["--payload=brain-mcp.py"]}}}' "$GMX_FIX" > "$GMX_FIX/settings.json"
OUT_L6="$(GEMINI_SETTINGS="$GMX_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_L6=$?
[[ $RC_L6 -eq 0 && "$OUT_L6" == *"[WARN"*"gemini wiring — not wired: brain MCP"* && "$OUT_L6" != *"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-suffix-only-arg-not-accepted" $?

# (l6.2) an EXISTING file whose name merely ends in brain-mcp.py -> not wired
#         (pre-fix this passed both the endswith and the isfile test = accepted)
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["%s/evil-brain-mcp.py"]}}}' "$GMX_FIX" "$GMX_FIX" > "$GMX_FIX/settings.json"
OUT_L6B="$(GEMINI_SETTINGS="$GMX_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_L6B=$?
[[ $RC_L6B -eq 0 && "$OUT_L6B" == *"[WARN"*"gemini wiring — not wired: brain MCP"* && "$OUT_L6B" != *"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-suffix-named-real-file-not-accepted" $?

# (l6.3) a real, existing brain-mcp.py OUTSIDE this framework -> FAIL, never PASS
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["%s/attacker/brain-mcp.py"]}}}' "$GMX_FIX" "$GMX_FIX" > "$GMX_FIX/settings.json"
OUT_L6C="$(GEMINI_SETTINGS="$GMX_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_L6C=$?
[[ $RC_L6C -eq 1 && "$OUT_L6C" == *"[FAIL"*"gemini wiring — wired to a brain-mcp.py outside this framework"*"attacker/brain-mcp.py"* ]]
check "gemini-foreign-brain-mcp-fails" $?
[[ "$OUT_L6C" != *"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-foreign-brain-mcp-not-accepted" $?

# (l6.4) POSITIVE CONTROL — a symlink whose RESOLVED target IS this framework's
#         core/brain/brain-mcp.py is accepted. Without this the three checks above
#         would stay green even if check 16 rejected every path unconditionally.
ln -sf "$REPO_ROOT/core/brain/brain-mcp.py" "$GMX_FIX/linked-brain-mcp.py"
mkdir -p "$GMX_FIX/link"
ln -sf "$REPO_ROOT/core/brain/brain-mcp.py" "$GMX_FIX/link/brain-mcp.py"
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["%s/link/brain-mcp.py"]}}}' "$GMX_FIX" "$GMX_FIX" > "$GMX_FIX/settings.json"
OUT_L6D="$(GEMINI_SETTINGS="$GMX_FIX/settings.json" bash "$SETUP" --doctor 2>&1)"
RC_L6D=$?
[[ $RC_L6D -eq 0 && "$OUT_L6D" == *"[PASS"*"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-resolved-framework-symlink-accepted" $?
rm -rf "$GMX_FIX"

echo
echo "=== (l7) gemini wiring: a NON-ABSOLUTE brain-mcp.py arg is never a valid registration ==="
# REGRESSION: resolved() resolves a relative arg against the directory DOCTOR
# happens to run in, which is not the runtime CWD of the MCP client. Doctor could
# therefore bless args:["core/brain/brain-mcp.py"] (or "x/../core/brain/...") while
# the client, launched anywhere else, would execute a different file or none.
# Every fixture below runs the doctor from $REPO_ROOT, so the relative paths DO
# resolve to this framework file — the pre-fix code reported PASS for exactly that.
GMR_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (gemini relative-path fixture)"; exit 1; }
track_fixture "$GMR_FIX"
touch "$GMR_FIX/gemini-shell-wrap.sh"
gmr_doctor() { ( cd "$REPO_ROOT" && GEMINI_SETTINGS="$GMR_FIX/settings.json" bash "$SETUP" --doctor 2>&1 ); }

# (l7.1) plain relative path
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["core/brain/brain-mcp.py"]}}}' "$GMR_FIX" > "$GMR_FIX/settings.json"
OUT_L7="$(gmr_doctor)"
RC_L7=$?
[[ $RC_L7 -eq 1 && "$OUT_L7" == *"[FAIL"*"gemini wiring — wired to a non-absolute path"* ]]
check "gemini-relative-path-fails" $?
[[ "$OUT_L7" != *"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-relative-path-not-accepted" $?

# (l7.2) relative path with a .. segment that still lands on the framework file
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["x/../core/brain/brain-mcp.py"]}}}' "$GMR_FIX" > "$GMR_FIX/settings.json"
OUT_L7B="$(gmr_doctor)"
[[ "$OUT_L7B" == *"[FAIL"*"gemini wiring — wired to a non-absolute path"* && "$OUT_L7B" != *"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-relative-dotdot-path-not-accepted" $?

# (l7.3) POSITIVE CONTROL — the ABSOLUTE form of the same file, from the same CWD,
#         is still accepted. Without this, (l7.1)/(l7.2) would stay green even if
#         check 16 rejected every path.
printf '{"tools":{"shell":{"command":"%s/gemini-shell-wrap.sh"}},"mcpServers":{"brain":{"args":["%s/core/brain/brain-mcp.py"]}}}' "$GMR_FIX" "$REPO_ROOT" > "$GMR_FIX/settings.json"
OUT_L7C="$(gmr_doctor)"
RC_L7C=$?
[[ $RC_L7C -eq 0 && "$OUT_L7C" == *"[PASS"*"gemini wiring — brain MCP + shell wrapper wired"* ]]
check "gemini-absolute-path-still-accepted" $?
rm -rf "$GMR_FIX"

echo
echo "=== (m) claude install path: plugin-only / shell-only -> PASS naming the path ==="
CIP_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (claude install path fixture)"; exit 1; }
track_fixture "$CIP_FIX"
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
BRN_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (brain lint fixture)"; exit 1; }
track_fixture "$BRN_FIX"
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
echo "=== (o) gh CLI: on PATH -> PASS naming its path (presence-only, never invoked); absent from PATH -> WARN, warn != fail ==="
OUT_O="$(bash "$SETUP" --doctor 2>&1)"
GH_PATH="$(command -v gh)"
[[ "$OUT_O" == *"[PASS"*"gh — $GH_PATH"* ]]
check "gh-present-pass" $?
# PATH=/usr/bin:/bin alone is not a reliable "gh absent" simulation: GitHub-hosted
# ubuntu runners ship gh preinstalled at /usr/bin/gh (unlike a Homebrew-installed
# gh on macOS, which lives outside /usr/bin and /bin). Build an explicit sandbox
# PATH that mirrors every other /usr/bin and /bin binary via symlink but omits gh,
# so the "absent" case holds regardless of where the host happens to put gh.
GH_LESS_PATH="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (gh-less PATH fixture)"; exit 1; }
track_fixture "$GH_LESS_PATH"
for bin in /usr/bin/* /bin/*; do
    name="$(basename "$bin")"
    [[ "$name" == "gh" ]] && continue
    ln -sf "$bin" "$GH_LESS_PATH/$name" 2>/dev/null
done
OUT_O2="$(PATH="$GH_LESS_PATH" bash "$SETUP" --doctor 2>&1)"
RC_O2=$?
rm -rf "$GH_LESS_PATH"
[[ $RC_O2 -eq 0 && "$OUT_O2" == *"[WARN"*"gh — not found"*"brew install gh"* ]]
check "gh-absent-warn-not-fail" $?

echo
echo "=== (p) brain MCP (plugin path): not a plugin-only install -> PASS skip ==="
BMP_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (brain-mcp plugin-path fixture)"; exit 1; }
track_fixture "$BMP_FIX"
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
# the registered args entry must RESOLVE to this framework's core/brain/brain-mcp.py
# (check 18 compares canonical paths, not filename suffixes) — hence a symlink into
# the real repo file rather than a plausible-looking absolute string.
ln -sf "$REPO_ROOT/core/brain/brain-mcp.py" "$BMP_FIX/brain-mcp.py"
printf '{"mcpServers":{"brain":{"command":"python3","args":["%s/brain-mcp.py"]}}}' "$BMP_FIX" > "$BMP_FIX/claude.json"
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
echo "=== (p7) brain MCP (plugin path): registration identity is a RESOLVED-PATH match, not a filename suffix ==="
# REGRESSION: check 18 used `a.endswith("brain-mcp.py")`, so ANY args entry ending in
# the filename counted as "registered" — a foreign server (or a non-path string) was
# reported as this framework's brain MCP. It now compares the canonical resolved path
# against $FRAMEWORK_ROOT/core/brain/brain-mcp.py.
BMX_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (brain-mcp identity fixture)"; exit 1; }
track_fixture "$BMX_FIX"
mkdir -p "$BMX_FIX/cache/market/agent-harness/0.5.4" "$BMX_FIX/attacker" "$BMX_FIX/link"
touch "$BMX_FIX/attacker/brain-mcp.py" "$BMX_FIX/evil-brain-mcp.py"
bmx_doctor() {
  AGENT_PLUGIN_CACHE_ROOT="$BMX_FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json \
    AGENT_CLAUDE_USER_CONFIG="$BMX_FIX/claude.json" bash "$SETUP" --doctor 2>&1
}

# (p7.1) a bare suffix-only arg is not a registration of this framework's server
printf '{"mcpServers":{"brain":{"command":"python3","args":["--payload=brain-mcp.py"]}}}' > "$BMX_FIX/claude.json"
OUT_P7="$(bmx_doctor)"
RC_P7=$?
[[ $RC_P7 -eq 0 && "$OUT_P7" == *"[WARN"*"brain MCP (plugin path) — registered but does not point at brain-mcp.py"* ]]
check "brain-mcp-suffix-only-arg-not-accepted" $?
[[ "$OUT_P7" != *"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-suffix-only-arg-not-reported-registered" $?

# (p7.2) an EXISTING file whose name merely ends in brain-mcp.py -> not registered
printf '{"mcpServers":{"brain":{"command":"python3","args":["%s/evil-brain-mcp.py"]}}}' "$BMX_FIX" > "$BMX_FIX/claude.json"
OUT_P7B="$(bmx_doctor)"
[[ "$OUT_P7B" == *"[WARN"*"brain MCP (plugin path) — registered but does not point at brain-mcp.py"* && "$OUT_P7B" != *"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-suffix-named-real-file-not-accepted" $?

# (p7.3) a real, existing brain-mcp.py OUTSIDE this framework -> not registered
printf '{"mcpServers":{"brain":{"command":"python3","args":["%s/attacker/brain-mcp.py"]}}}' "$BMX_FIX" > "$BMX_FIX/claude.json"
OUT_P7C="$(bmx_doctor)"
[[ "$OUT_P7C" == *"[WARN"*"brain MCP (plugin path) — registered but does not point at brain-mcp.py"* && "$OUT_P7C" != *"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-foreign-path-not-accepted" $?

# (p7.4) POSITIVE CONTROL — a symlink resolving to THIS framework's core/brain/
#         brain-mcp.py IS accepted. Mandatory: without it (p7.1)-(p7.3) would stay
#         green even if check 18 rejected every registration unconditionally.
ln -sf "$REPO_ROOT/core/brain/brain-mcp.py" "$BMX_FIX/link/brain-mcp.py"
printf '{"mcpServers":{"brain":{"command":"python3","args":["%s/link/brain-mcp.py"]}}}' "$BMX_FIX" > "$BMX_FIX/claude.json"
OUT_P7D="$(bmx_doctor)"
RC_P7D=$?
[[ $RC_P7D -eq 0 && "$OUT_P7D" == *"[PASS"*"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-resolved-framework-symlink-accepted" $?

echo
echo "=== (p8) brain MCP (plugin path): hostile bytes that REACH the row cannot spoof or split it ==="
# REGRESSION (two of them):
#  1. $bm_out is python output derived from a user-controlled ~/.claude.json and was
#     interpolated raw into a doctor row: an ESC sequence could repaint the terminal
#     and a raw newline could split one row into several unlabelled lines at the
#     left margin — the primitive for forging a row.
#  2. The FIRST version of this test was VACUOUS. Its fixture was a top-level JSON
#     array, which makes d.get() raise AttributeError, so the row carried only
#     python traceback text ("AttributeError: list object has no attribute get").
#     The array CONTENTS never reached the output, so the no-ESC and no-forged-row
#     assertions could not fail no matter what the sanitizer did.
# The payload now travels a route that provably reaches the row: a NON-ABSOLUTE
# registration path, which check 20 echoes verbatim. It is shaped so realpath()
# pops the hostile component (the two "..") and lands on this framework real
# core/brain/brain-mcp.py — hence the doctor takes the "registered with a
# non-absolute path (...)" branch and prints the payload. The doctor therefore has
# to run with CWD=$REPO_ROOT. P8_REACH below is the anti-vacuity control: the
# sanitizer-surviving ASCII of the payload ("spoofed") MUST appear in the row.
bmx_doctor_at_repo_root() { ( cd "$REPO_ROOT" && bmx_doctor ); }
python3 - "$BMX_FIX/claude.json" <<'PY'
import json, sys
payload = ("\u001b[2Jspoofed\u000a  [PASS] brain MCP (plugin path) — "
           "registered in ~/.claude.json/../../core/brain/brain-mcp.py")
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"mcpServers": {"brain": {"command": "python3", "args": [payload]}}}, f)
PY
OUT_P8="$(bmx_doctor_at_repo_root)"
RC_P8=$?
[[ $RC_P8 -eq 0 ]]
check "brain-mcp-control-char-config-no-crash" $?
# ANTI-VACUITY: the payload really is in the row (only its control chars are gone)
[[ "$OUT_P8" == *"brain MCP (plugin path) — registered with a non-absolute path"*"spoofed"* ]]
check "brain-mcp-control-char-payload-reaches-row" $?
# every line from the brain MCP row to the summary must still be a well-formed row,
# AND the row must occupy exactly ONE line. The stray-line count alone is too weak
# here: the payload begins with "  [PASS]", so a split row would produce a second
# line that still looks well-formed — hence the label-occurrence count.
P8_TAIL="$(printf '%s\n' "$OUT_P8" | sed -n '/brain MCP (plugin path)/,$p')"
P8_STRAY="$(printf '%s\n' "$P8_TAIL" | grep -c -v -e '^  \[' -e '^doctor: ' -e '^$' || true)"
P8_ROWS="$(printf '%s\n' "$OUT_P8" | grep -c 'brain MCP (plugin path)' || true)"
[[ "$P8_STRAY" -eq 0 && "$P8_ROWS" -eq 1 ]]
check "brain-mcp-control-char-no-row-splitting" $?
case "$OUT_P8" in
  *$'\x1b'*) check "brain-mcp-control-char-no-escape-in-output" 1 ;;
  *)         check "brain-mcp-control-char-no-escape-in-output" 0 ;;
esac
# and the payload must not have become a separate, forged output line
P8_FAKE="$(printf '%s\n' "$OUT_P8" | grep -c '^  \[PASS\] brain MCP (plugin path) — registered in ~/\.claude\.json' || true)"
[[ "$P8_FAKE" -eq 0 ]]
check "brain-mcp-control-char-no-spoofed-pass-row" $?

echo
echo "=== (p8b) brain MCP (plugin path): a non-object config leaks a multi-line traceback -> still one row ==="
# The old (p8) fixture, kept for what it DOES exercise: a top-level JSON array makes
# d.get() raise, so $bm_out is a genuine multi-LINE traceback. Row integrity only.
printf '["not an object"]' > "$BMX_FIX/claude.json"
OUT_P8C="$(bmx_doctor)"
RC_P8C=$?
[[ $RC_P8C -eq 0 && "$OUT_P8C" == *"[WARN"*"brain MCP (plugin path) —"* ]]
check "brain-mcp-nonobject-config-no-crash" $?
P8C_TAIL="$(printf '%s\n' "$OUT_P8C" | sed -n '/brain MCP (plugin path)/,$p')"
P8C_STRAY="$(printf '%s\n' "$P8C_TAIL" | grep -c -v -e '^  \[' -e '^doctor: ' -e '^$' || true)"
[[ "$P8C_STRAY" -eq 0 ]]
check "brain-mcp-traceback-collapsed-into-one-row" $?

echo
echo "=== (p9) brain MCP (plugin path): a NON-ABSOLUTE registration is never reported registered ==="
# REGRESSION: resolved() resolved a relative arg against the directory doctor
# happens to run in — not the runtime CWD of the MCP client, which is launched
# elsewhere and would execute a different file or none. Doctor ran from $REPO_ROOT
# here, so pre-fix both fixtures below were reported "registered in ...".
printf '{"mcpServers":{"brain":{"command":"python3","args":["core/brain/brain-mcp.py"]}}}' > "$BMX_FIX/claude.json"
OUT_P9="$(bmx_doctor_at_repo_root)"
RC_P9=$?
[[ $RC_P9 -eq 0 && "$OUT_P9" == *"[WARN"*"brain MCP (plugin path) — registered with a non-absolute path"* ]]
check "brain-mcp-relative-path-warns" $?
[[ "$OUT_P9" != *"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-relative-path-not-reported-registered" $?
printf '{"mcpServers":{"brain":{"command":"python3","args":["x/../core/brain/brain-mcp.py"]}}}' > "$BMX_FIX/claude.json"
OUT_P9B="$(bmx_doctor_at_repo_root)"
[[ "$OUT_P9B" == *"[WARN"*"brain MCP (plugin path) — registered with a non-absolute path"* && "$OUT_P9B" != *"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-relative-dotdot-path-not-accepted" $?
# POSITIVE CONTROL — the ABSOLUTE form of the same file, from the same CWD, is
# still accepted; without it the two checks above would pass a blanket reject.
printf '{"mcpServers":{"brain":{"command":"python3","args":["%s/core/brain/brain-mcp.py"]}}}' "$REPO_ROOT" > "$BMX_FIX/claude.json"
OUT_P9C="$(bmx_doctor_at_repo_root)"
[[ "$OUT_P9C" == *"[PASS"*"brain MCP (plugin path) — registered in"* ]]
check "brain-mcp-absolute-path-still-accepted" $?

echo
echo "=== (p10) row sanitizer: C1 + bidi controls removed, Korean intact, invalid UTF-8 survivable ==="
# REGRESSION: the filter was `tr -d '\000-\037\177'` (C0 + DEL only), so U+009B —
# a ONE-CHARACTER "ESC[" on terminals that honour C1 — and the bidi overrides
# U+202A-U+202E / U+2066-U+2069 / U+200E / U+200F went straight through: U+009B
# restores the row-spoofing primitive, U+202E reverses the displayed text of a row.
# A byte-level `tr` cannot fix that without shredding multi-byte UTF-8 (this repo
# emits Korean), so the filter is character-aware — and must therefore survive
# invalid UTF-8 rather than throw and blank the row. Needles are built with python3
# because bash 3.2 printf/$'' have no \uXXXX escape.
P10_CSI="$(python3 -c 'import sys; sys.stdout.buffer.write("\u009b".encode())')"
P10_RLO="$(python3 -c 'import sys; sys.stdout.buffer.write("\u202e".encode())')"
P10_NEL="$(python3 -c 'import sys; sys.stdout.buffer.write("\u0085".encode())')"
# same reaching route as (p8): a non-absolute path whose hostile component is
# popped by ".." — payload = U+009B "2J" 한글 U+202E U+0085
python3 - "$BMX_FIX/claude.json" <<'PY'
import json, sys
payload = "\u009b2J한글\u202e\u0085/../core/brain/brain-mcp.py"
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"mcpServers": {"brain": {"command": "python3", "args": [payload]}}}, f)
PY
OUT_P10="$(bmx_doctor_at_repo_root)"
RC_P10=$?
[[ $RC_P10 -eq 0 && "$OUT_P10" == *"brain MCP (plugin path) — registered with a non-absolute path"* ]]
check "row-sanitizer-c1-payload-reaches-row" $?
[[ "$OUT_P10" == *"한글"* ]]
check "row-sanitizer-keeps-korean-intact" $?
[[ "$OUT_P10" != *"$P10_CSI"* ]]
check "row-sanitizer-strips-u009b-csi" $?
[[ "$OUT_P10" != *"$P10_RLO"* ]]
check "row-sanitizer-strips-u202e-bidi-override" $?
[[ "$OUT_P10" != *"$P10_NEL"* ]]
check "row-sanitizer-strips-u0085-nel" $?

# invalid UTF-8 must not throw and blank the row. Route: the config PATH itself
# (the "no user config" row echoes it) carries a lone \xff next to Korean and a
# U+009B — the bad byte is dropped, everything printable survives.
P10_BADNAME="$(python3 -c 'import sys; sys.stdout.buffer.write(b"no-such-\xff-\xed\x95\x9c\xea\xb8\x80-\xc2\x9b2J.json")')"
OUT_P10B="$(AGENT_PLUGIN_CACHE_ROOT="$BMX_FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json \
  AGENT_CLAUDE_USER_CONFIG="$BMX_FIX/$P10_BADNAME" bash "$SETUP" --doctor 2>&1)"
RC_P10B=$?
[[ $RC_P10B -eq 0 && "$OUT_P10B" == *"[WARN"*"brain MCP (plugin path) — no user config at"*"no-such-"*".json"* ]]
check "row-sanitizer-invalid-utf8-does-not-blank-row" $?
[[ "$OUT_P10B" == *"한글"* ]]
check "row-sanitizer-invalid-utf8-keeps-korean" $?
P10_FF="$(printf '\377')"
[[ "$OUT_P10B" != *"$P10_FF"* && "$OUT_P10B" != *"$P10_CSI"* ]]
check "row-sanitizer-invalid-utf8-byte-and-c1-removed" $?
rm -rf "$BMX_FIX"

echo
echo "=== (q) safe_mktemp_d: every guard arm rejects, a real call still yields a usable dir ==="
Q_RC=0
( mktemp() { printf '%s\n' "/tmp/agent-doctor-test-never-created"; return 1; }; safe_mktemp_d ) >/dev/null 2>&1 || Q_RC=$?
[[ "$Q_RC" -ne 0 ]]
check "safe-mktemp-rejects-nonzero-exit" $?
Q_RC2=0
( mktemp() { printf ''; return 0; }; safe_mktemp_d ) >/dev/null 2>&1 || Q_RC2=$?
[[ "$Q_RC2" -ne 0 ]]
check "safe-mktemp-rejects-empty-output" $?
Q_REAL="$(safe_mktemp_d)"
Q_REAL_RC=$?
track_fixture "$Q_REAL"
[[ $Q_REAL_RC -eq 0 && -n "$Q_REAL" && -d "$Q_REAL" ]]
check "safe-mktemp-real-call-returns-usable-dir" $?
Q_NONDIR="$Q_REAL/not-a-directory"
touch "$Q_NONDIR"
Q_RC3=0
( mktemp() { printf '%s\n' "$Q_NONDIR"; return 0; }; safe_mktemp_d ) >/dev/null 2>&1 || Q_RC3=$?
[[ "$Q_RC3" -ne 0 ]]
check "safe-mktemp-rejects-non-directory" $?
rm -rf "$Q_REAL"
# The guard is only worth anything if the fixtures actually route through it.
# The old assertion grepped for the ONE BMP_FIX line, so GMW_FIX/GMX_FIX/BMX_FIX
# (and every earlier fixture) could go back to a bare `mktemp -d` — whose empty-
# but-status-0 failure mode yields paths like "/brain-mcp.py", i.e. writes at the
# filesystem root — without failing anything. Assert over the WHOLE file instead:
# zero top-level fixture assignments from a bare `mktemp -d`, and a plausible
# number of them from safe_mktemp_d (the second half is the anti-vacuity control —
# a file with no fixtures at all would otherwise pass the first).
SELF="${BASH_SOURCE[0]}"
Q_RAW_N="$({ grep -c -E '^[A-Za-z_][A-Za-z_0-9]*="\$\(mktemp -d' "$SELF" || true; })"
[[ "$Q_RAW_N" -eq 0 ]]
check "no-fixture-dir-from-bare-mktemp" $?
Q_GUARDED_N="$({ grep -c -E '^[A-Za-z_][A-Za-z_0-9]*="\$\(safe_mktemp_d\)"' "$SELF" || true; })"
[[ "$Q_GUARDED_N" -ge 16 ]]
check "all-fixture-dirs-routed-through-safe-mktemp" $?
# and the cleanup trap must be armed for the abnormal exits, not just EXIT
Q_TRAP_N="$({ grep -c -E "^trap ('cleanup_fixtures; exit [0-9]+' (INT|TERM)|cleanup_fixtures EXIT)\$" "$SELF" || true; })"
[[ "$Q_TRAP_N" -eq 3 ]]
check "cleanup-trap-armed-on-exit-int-term" $?
# a trap that could delete an untracked path is worse than no trap: prove the
# recorder refuses empty/unset/nonexistent values instead of recording them
Q_TRACK_BEFORE=${#FIXTURE_DIRS[@]}
track_fixture ""
track_fixture "/nonexistent/agent-doctor-test-never-created"
track_fixture "/"
[[ ${#FIXTURE_DIRS[@]} -eq $Q_TRACK_BEFORE ]]
check "track-fixture-refuses-empty-and-uncreated-paths" $?

echo
echo "=== (q) kiro gateway lanes: profiles + preflight installed -> PASS ==="
# kiro_rows <output> — only the doctor rows this check owns.
kiro_rows() { printf '%s\n' "$1" | grep 'kiro gateway lanes' || true; }

KIRO_FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (kiro fixture)"; exit 1; }
mkdir -p "$KIRO_FIX/agents" "$KIRO_FIX/bin"
for b in kiro-cli fix-preflight; do
  printf '#!/bin/sh\nexit 0\n' > "$KIRO_FIX/bin/$b"; chmod +x "$KIRO_FIX/bin/$b"
done
# Fixture names are deliberately NOT the shipped ones (fix-*), so no test here
# can pass by accident off this machine's real ~/.kiro/agents or PATH.
write_kiro_registry() {  # $1 = enabled true|false
  cat > "$KIRO_FIX/backends.json" <<JSON
{"version":2,"roles":{},"backends":{
 "codex":{"vendor":"openai","connection":"cli","enabled":true,"cmd":["codex","exec"],
          "tier_args":{"TOP":["--profile","deep"]},"preflight":["codex","--version"]},
 "kiro-openai":{"vendor":"openai","connection":"cli","gateway":"kiro","enabled":$1,
   "cmd":["kiro-cli","chat","--no-interactive"],
   "tier_args":{"LOW":["--agent","fix-low"],"TOP":["--agent","fix-top"]},
   "preflight":["fix-preflight"],"timeout_s":420}}}
JSON
}
write_kiro_registry true
touch "$KIRO_FIX/agents/fix-low.json" "$KIRO_FIX/agents/fix-top.json"
doctor_kiro() {  # run doctor with the kiro fixture wired in; $1 = extra PATH prefix dir
  PATH="$1:/usr/bin:/bin" AGENT_BACKENDS_FILE="$KIRO_FIX/backends.json" \
    AGENT_KIRO_AGENTS_DIR="$KIRO_FIX/agents" bash "$SETUP" --doctor 2>&1
}
OUT_Q="$(doctor_kiro "$KIRO_FIX/bin")"
RC_Q=$?
[[ $RC_Q -eq 0 && "$OUT_Q" == *"[PASS"*"kiro gateway lanes — 1 enabled lane(s), 2 profile(s) present in $KIRO_FIX/agents, preflight resolvable (fix-preflight)"* ]]
check "kiro-wired-pass" $?

echo
echo "=== (q2) kiro gateway lanes: one profile missing -> WARN naming ONLY that profile ==="
rm -f "$KIRO_FIX/agents/fix-top.json"
OUT_Q2="$(doctor_kiro "$KIRO_FIX/bin")"
RC_Q2=$?
Q2_ROWS="$(kiro_rows "$OUT_Q2")"
[[ "$Q2_ROWS" == *"[WARN"*"profile(s) referenced by an enabled kiro backend missing from $KIRO_FIX/agents: fix-top;"* ]]
check "kiro-missing-profile-warn" $?
[[ "$Q2_ROWS" != *fix-low* ]]
check "kiro-missing-profile-omits-present-ones" $?
[[ $RC_Q2 -eq 0 ]]
check "kiro-missing-profile-is-warn-not-fail" $?
touch "$KIRO_FIX/agents/fix-top.json"

echo
echo "=== (q3) kiro gateway lanes: preflight not on PATH -> WARN naming it + the exit-127 consequence ==="
mkdir -p "$KIRO_FIX/bin-nopf"
cp "$KIRO_FIX/bin/kiro-cli" "$KIRO_FIX/bin-nopf/kiro-cli"
OUT_Q3="$(doctor_kiro "$KIRO_FIX/bin-nopf")"
RC_Q3=$?
Q3_ROWS="$(kiro_rows "$OUT_Q3")"
[[ "$Q3_ROWS" == *"[WARN"*"preflight probe not resolvable on PATH: fix-preflight;"*"127"* ]]
check "kiro-missing-preflight-warn" $?
[[ $RC_Q3 -eq 0 ]]
check "kiro-missing-preflight-is-warn-not-fail" $?

echo
echo "=== (q4) kiro gateway lanes: every kiro backend disabled -> skipped PASS, no WARN ==="
write_kiro_registry false
OUT_Q4="$(doctor_kiro "$KIRO_FIX/bin")"
Q4_ROWS="$(kiro_rows "$OUT_Q4")"
[[ "$Q4_ROWS" == *"[PASS"*"kiro gateway lanes — no enabled kiro backend in $KIRO_FIX/backends.json (check skipped)"* ]]
check "kiro-all-disabled-skip-pass" $?
[[ "$Q4_ROWS" != *"[WARN"* ]]
check "kiro-all-disabled-no-warn" $?
write_kiro_registry true

echo
echo "=== (q5) kiro gateway lanes: gateway CLI absent -> ONE WARN, no profile/preflight cascade ==="
mkdir -p "$KIRO_FIX/bin-empty"
OUT_Q5="$(doctor_kiro "$KIRO_FIX/bin-empty")"
Q5_ROWS="$(kiro_rows "$OUT_Q5")"
[[ "$Q5_ROWS" == *"[WARN"*"gateway CLI not installed: kiro-cli;"* ]]
check "kiro-no-cli-warn" $?
Q5_N="$(printf '%s\n' "$Q5_ROWS" | grep -c 'kiro gateway lanes' || true)"
[[ "$Q5_N" -eq 1 ]]
check "kiro-no-cli-single-row-no-cascade" $?

echo
echo "=== (q6) kiro gateway lanes: control chars in a registry-derived name cannot split a row ==="
cat > "$KIRO_FIX/backends.json" <<'JSON'
{"version":2,"roles":{},"backends":{
 "kiro-openai":{"vendor":"openai","connection":"cli","gateway":"kiro","enabled":true,
   "cmd":["kiro-cli","chat","--no-interactive"],
   "tier_args":{"LOW":["--agent","ev\u001b[2Jil\nkiro gateway lanes — forged row"]},
   "preflight":["fix-preflight"],"timeout_s":420}}}
JSON
OUT_Q6="$(doctor_kiro "$KIRO_FIX/bin")"
RC_Q6=$?
Q6_ROWS="$(kiro_rows "$OUT_Q6")"
[[ "$Q6_ROWS" == *"[WARN"*"ev?[2Jil?kiro gateway lanes — forged row"* ]]
check "kiro-control-chars-sanitized-in-row" $?
Q6_N="$(printf '%s\n' "$Q6_ROWS" | grep -c 'kiro gateway lanes' || true)"
[[ "$Q6_N" -eq 1 ]]
check "kiro-control-chars-cannot-split-row" $?
case "$OUT_Q6" in
  *$'\x1b'*) check "kiro-escape-stripped-from-output" 1 ;;
  *)         check "kiro-escape-stripped-from-output" 0 ;;
esac
[[ $RC_Q6 -eq 0 ]]
check "kiro-control-chars-no-crash" $?
write_kiro_registry true

echo
echo "=== (q9) kiro gateway lanes: enabled lane with NO profile and NO preflight -> WARN naming it, never PASS ==="
# The regression this pins: the check only accumulated MISSING files, so a lane
# declaring {"tier_args":{"TOP":[]},"preflight":[]} left both accumulators empty
# and printed "0 profile(s) present ... preflight resolvable (none declared)" as
# a PASS — a lane with neither a read-only profile nor a fail-closed probe.
write_kiro_registry_raw() { cat > "$KIRO_FIX/backends.json"; }
write_kiro_registry_raw <<'JSON'
{"version":2,"roles":{},"backends":{
 "kiro-openai":{"vendor":"openai","connection":"cli","gateway":"kiro","enabled":true,
   "cmd":["kiro-cli","chat","--no-interactive"],
   "tier_args":{"TOP":[]},"preflight":[],"timeout_s":420}}}
JSON
OUT_Q9="$(doctor_kiro "$KIRO_FIX/bin")"
RC_Q9=$?
Q9_ROWS="$(kiro_rows "$OUT_Q9")"
[[ "$Q9_ROWS" == *"[WARN"*"pinning NO --agent profile"*"kiro-openai"* ]]
check "kiro-zero-profile-lane-warns-naming-lane" $?
[[ "$Q9_ROWS" == *"[WARN"*"declaring NO preflight probe"*"kiro-openai"* ]]
check "kiro-zero-preflight-lane-warns-naming-lane" $?
[[ "$Q9_ROWS" != *"[PASS"* ]]
check "kiro-zero-profile-and-preflight-never-passes" $?
[[ $RC_Q9 -eq 0 ]]
check "kiro-zero-profile-is-warn-not-fail" $?

echo
echo "=== (q10) kiro gateway lanes: dangling trailing --agent -> WARN naming lane:tier (not silently dropped) ==="
write_kiro_registry_raw <<'JSON'
{"version":2,"roles":{},"backends":{
 "kiro-openai":{"vendor":"openai","connection":"cli","gateway":"kiro","enabled":true,
   "cmd":["kiro-cli","chat","--no-interactive"],
   "tier_args":{"LOW":["--agent","fix-low"],"TOP":["--agent"]},
   "preflight":["fix-preflight"],"timeout_s":420}}}
JSON
OUT_Q10="$(doctor_kiro "$KIRO_FIX/bin")"
Q10_ROWS="$(kiro_rows "$OUT_Q10")"
[[ "$Q10_ROWS" == *"[WARN"*"tier(s) that do not pin a profile: kiro-openai:TOP"* ]]
check "kiro-dangling-agent-warns-naming-lane-and-tier" $?
[[ "$Q10_ROWS" != *"[PASS"* ]]
check "kiro-dangling-agent-never-passes" $?

echo
echo "=== (q11) kiro gateway lanes: non-array cmd -> WARN (was silently dropped) ==="
write_kiro_registry_raw <<'JSON'
{"version":2,"roles":{},"backends":{
 "kiro-openai":{"vendor":"openai","connection":"cli","gateway":"kiro","enabled":true,
   "cmd":"kiro-cli chat",
   "tier_args":{"LOW":["--agent","fix-low"]},
   "preflight":["fix-preflight"],"timeout_s":420}}}
JSON
OUT_Q11="$(doctor_kiro "$KIRO_FIX/bin")"
Q11_ROWS="$(kiro_rows "$OUT_Q11")"
[[ "$Q11_ROWS" == *"[WARN"*"unusable cmd"*"kiro-openai"* ]]
check "kiro-non-array-cmd-warns" $?
[[ "$Q11_ROWS" != *"[PASS"* ]]
check "kiro-non-array-cmd-never-passes" $?

echo
echo "=== (q12) kiro gateway lanes: non-object tier_args -> WARN (was silently dropped) ==="
write_kiro_registry_raw <<'JSON'
{"version":2,"roles":{},"backends":{
 "kiro-openai":{"vendor":"openai","connection":"cli","gateway":"kiro","enabled":true,
   "cmd":["kiro-cli","chat","--no-interactive"],
   "tier_args":["LOW"],
   "preflight":["fix-preflight"],"timeout_s":420}}}
JSON
OUT_Q12="$(doctor_kiro "$KIRO_FIX/bin")"
Q12_ROWS="$(kiro_rows "$OUT_Q12")"
[[ "$Q12_ROWS" == *"[WARN"*"tier_args is not an object"*"kiro-openai"* ]]
check "kiro-non-object-tier-args-warns" $?
[[ "$Q12_ROWS" != *"[PASS"* ]]
check "kiro-non-object-tier-args-never-passes" $?

echo
echo "=== (q13) kiro gateway lanes: non-string first preflight element -> WARN (was silently dropped) ==="
write_kiro_registry_raw <<'JSON'
{"version":2,"roles":{},"backends":{
 "kiro-openai":{"vendor":"openai","connection":"cli","gateway":"kiro","enabled":true,
   "cmd":["kiro-cli","chat","--no-interactive"],
   "tier_args":{"LOW":["--agent","fix-low"]},
   "preflight":[123,"fix-preflight"],"timeout_s":420}}}
JSON
OUT_Q13="$(doctor_kiro "$KIRO_FIX/bin")"
Q13_ROWS="$(kiro_rows "$OUT_Q13")"
[[ "$Q13_ROWS" == *"[WARN"*"unusable preflight argv"*"kiro-openai"* ]]
check "kiro-non-string-preflight-element-warns" $?
[[ "$Q13_ROWS" != *"[PASS"* ]]
check "kiro-non-string-preflight-never-passes" $?
write_kiro_registry true

echo
echo "=== (q7) kiro gateway lanes: registry absent -> skipped; jq absent -> WARN, never a silent PASS ==="
OUT_Q7="$(PATH="$KIRO_FIX/bin:/usr/bin:/bin" AGENT_BACKENDS_FILE=/nonexistent/backends.json \
  bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_Q7" == *"[PASS"*"kiro gateway lanes — no backends registry at /nonexistent/backends.json (check skipped)"* ]]
check "kiro-registry-absent-skip" $?
# A PATH with no jq at all: symlink every /bin + /usr/bin tool EXCEPT jq, so the
# doctor keeps its coreutils/python3/git but cannot parse JSON.
NOJQ="$KIRO_FIX/nojq"
mkdir -p "$NOJQ"
for p in /bin/* /usr/bin/*; do
  b="$(basename "$p")"
  [[ "$b" == "jq" ]] && continue
  ln -sf "$p" "$NOJQ/$b" 2>/dev/null || true
done
cp "$KIRO_FIX/bin/kiro-cli" "$KIRO_FIX/bin/fix-preflight" "$NOJQ/"
OUT_Q8="$(PATH="$NOJQ" AGENT_BACKENDS_FILE="$KIRO_FIX/backends.json" \
  AGENT_KIRO_AGENTS_DIR="$KIRO_FIX/agents" bash "$SETUP" --doctor 2>&1)"
RC_Q8=$?
Q8_ROWS="$(kiro_rows "$OUT_Q8")"
[[ "$Q8_ROWS" == *"[WARN"*"check skipped: jq not found"* ]]
check "kiro-no-jq-warn-not-pass" $?
[[ "$Q8_ROWS" != *"[PASS"* ]]
check "kiro-no-jq-no-false-pass" $?
[[ $RC_Q8 -eq 0 ]]
check "kiro-no-jq-does-not-abort-doctor" $?
rm -rf "$KIRO_FIX"

echo
echo "=== (r) install_kiro(): throwaway HOME — profiles seeded, pre-existing not overwritten, symlink resolves ==="
IK_HOME="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (install_kiro fixture)"; exit 1; }
track_fixture "$IK_HOME"
mkdir -p "$IK_HOME/.kiro/agents"
echo '{"model":"user-pinned-model","tools":["read"],"allowedTools":["read"]}' \
  > "$IK_HOME/.kiro/agents/kiro-openai-low.json"
OUT_R="$(AGENT_SETUP_NO_DOCTOR=1 HOME="$IK_HOME" bash "$SETUP" --kiro 2>&1)"
RC_R=$?
[[ $RC_R -eq 0 ]]
check "install-kiro-exits-0" $?
[[ -d "$IK_HOME/bin" ]]
check "install-kiro-creates-home-bin" $?
[[ -L "$IK_HOME/bin/kiro-preflight" ]]
check "install-kiro-symlinks-preflight"  $?
[[ "$(readlink "$IK_HOME/bin/kiro-preflight")" == "$REPO_ROOT/adapters/kiro/kiro-preflight.sh" ]]
check "install-kiro-preflight-symlink-resolves" $?
# every shipped adapters/kiro/*.json.template gets a sibling profile file
IK_ALL_SEEDED=0
for f in "$REPO_ROOT"/adapters/kiro/*.json.template; do
  [[ -e "$f" ]] || continue
  base="$(basename "$f" .json.template)"
  [[ -f "$IK_HOME/.kiro/agents/$base.json" ]] || IK_ALL_SEEDED=1
done
[[ "$IK_ALL_SEEDED" -eq 0 ]]
check "install-kiro-seeds-every-template" $?
[[ "$OUT_R" == *"skipped (exists — user-owned model pin): $IK_HOME/.kiro/agents/kiro-openai-low.json"* ]]
check "install-kiro-announces-skip-of-existing-profile" $?
[[ "$(cat "$IK_HOME/.kiro/agents/kiro-openai-low.json")" == *"user-pinned-model"* ]]
check "install-kiro-does-not-overwrite-existing-profile" $?
[[ "$OUT_R" == *"seeded: $IK_HOME/.kiro/agents/kiro-openai-mid.json"* ]]
check "install-kiro-announces-seed-of-new-profile" $?
[[ "$OUT_R" == *"kiro-cli not found on PATH"* ]]
check "install-kiro-notes-missing-cli" $?
rm -rf "$IK_HOME"

# A dangling symlink at a profile path is false under -e; without the -L half
# of the guard, cp would follow it and write through to the link's target
# instead of skipping (security review 2026-08-20).
IK_HOME3="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (dangling-symlink fixture)"; exit 1; }
track_fixture "$IK_HOME3"
mkdir -p "$IK_HOME3/.kiro/agents"
ln -s "$IK_HOME3/nonexistent-target.json" "$IK_HOME3/.kiro/agents/kiro-openai-top.json"
AGENT_SETUP_NO_DOCTOR=1 HOME="$IK_HOME3" bash "$SETUP" --kiro >/dev/null 2>&1
[[ ! -e "$IK_HOME3/nonexistent-target.json" ]]
check "install-kiro-does-not-write-through-dangling-symlink" $?
[[ -L "$IK_HOME3/.kiro/agents/kiro-openai-top.json" ]]
check "install-kiro-leaves-dangling-symlink-in-place" $?
rm -rf "$IK_HOME3"

echo
echo "=== (r2) doctor ~/bin row — PASS when ~/bin is on PATH, WARN when PATH is stripped of it ==="
IK_HOME2="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (install_kiro doctor-row fixture)"; exit 1; }
track_fixture "$IK_HOME2"
AGENT_SETUP_NO_DOCTOR=1 HOME="$IK_HOME2" bash "$SETUP" --kiro >/dev/null 2>&1
OUT_R2A="$(HOME="$IK_HOME2" PATH="$IK_HOME2/bin:/usr/bin:/bin" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_R2A" == *"[PASS"*"worker symlink dir — ~/bin exists and is on PATH"* ]]
check "home-bin-doctor-row-pass-when-on-path" $?
OUT_R2B="$(HOME="$IK_HOME2" PATH="/usr/bin:/bin" bash "$SETUP" --doctor 2>&1)"
[[ "$OUT_R2B" == *"[WARN"*"worker symlink dir"*"not on PATH"* ]]
check "home-bin-doctor-row-warn-when-off-path" $?
rm -rf "$IK_HOME2"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
