#!/usr/bin/env bash
# plugin-path-install-test.sh — the plugin/marketplace install-path battery (Wave 1:
# plugin-path parity + dependency doctor).
#
# A shell install (`bash setup.sh --claude`) has always been doctor-verified end to
# end. A PLUGIN/marketplace install (the "install once via /plugin marketplace add"
# path README.md and getting-started.md advertise) had NO equivalent proof: nothing
# asserted that a fresh machine which only ever ran `/plugin install agent-harness`
# gets useful guidance instead of silent gaps. This battery closes that:
#
#   (a)+(b) doctor, run against a SIMULATED plugin-only install (cache dir present,
#       no shell-install settings wiring) inside an ISOLATED SCRATCH $HOME, reports
#       the plugin path correctly AND surfaces the two new checks this wave adds:
#       `gh` presence (setup-doctor-test.sh (o) already covers the mechanics; here
#       it's asserted in the plugin-path context) and brain MCP plugin-path guidance
#       (setup-doctor-test.sh (p)-(p6) covers the mechanics in depth; here it's
#       asserted as part of the end-to-end install narrative this CI job mirrors).
#       The scratch $HOME is snapshotted (full recursive file listing) before and
#       after: a repo-only `git status --porcelain` diff is NOT sufficient here — a
#       security review of an earlier version of check 19 found it ran `gh --version`
#       (not just `command -v gh`), which writes ~/.local/state/gh/device-id on a
#       clean $HOME. That write is invisible to a repo git-status diff (it's outside
#       the repo) but IS caught by this scratch-HOME snapshot, which is the point.
#       PYTHONDONTWRITEBYTECODE=1 is set to suppress an unrelated, pre-existing,
#       harmless side effect: macOS system python3 (used by many PRE-EXISTING doctor
#       checks, e.g. 7/8/11/12/15/16/18 — not introduced by this wave) writes its own
#       bytecode cache under ~/Library/Caches/com.apple.python on first run against a
#       fresh $HOME. Without suppressing that noise, the snapshot assertion could
#       never go green regardless of this wave's fix, defeating its purpose.
#   (c) gitleaks / sqlite3+jq absence degrades LOUDLY, not silently — doctor WARNs
#       with an install hint (setup-doctor-test.sh (b) proves gitleaks; this proves
#       sqlite3+jq here since check 14 has no dedicated fixture elsewhere) AND
#       core/infra/supervisor-goal.sh's hard dependency guard (every subcommand,
#       before any DB touch) prints a HUMAN-READABLE message before its exit 127 —
#       not a bare "command not found".
#   (d) ANTI-VACUOUS RED PROBE: a plugin-path install is only as trustworthy as its
#       plugin manifest. This proves the manifest gate the whole install path leans
#       on (core/tests/registry-drift.sh, via its REGISTRY_DRIFT_ROOT seam) actually
#       catches a broken .claude-plugin/plugin.json — not a test that only ever
#       exercises the passing path. A clean-fixture control run proves the probe
#       isn't an always-fail either.
#
# This is the local mirror of the `.github/workflows/ci.yml` `plugin-path-install`
# job — same operations, so a green run here is the same evidence CI produces.
#
# Usage: bash core/tests/plugin-path-install-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
REGISTRY_DRIFT="$REPO_ROOT/core/tests/registry-drift.sh"

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

# safe_mktemp_d — `mktemp -d` guarded against both a nonzero exit AND (bash 3.2 has
# no `set -o pipefail` interaction here, but a belt-and-suspenders check costs
# nothing) a captured empty/non-directory result — an unguarded `FIX="$(mktemp -d)"`
# that silently produced an empty string would turn every later `rm -rf "$FIX"` /
# `mkdir -p "$FIX/..."` in this file into an operation on cwd or on a literal
# relative path, which is exactly the kind of mistake a temp-file test must not make.
safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  printf '%s\n' "$d"
}

echo "=== (a)+(b) doctor on a simulated plugin-only install, isolated scratch \$HOME: exit 0, new checks present, zero writes anywhere under \$HOME ==="
FIX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (plugin-cache fixture)"; exit 1; }
mkdir -p "$FIX/cache/market/agent-harness/0.5.4"
SCRATCH="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (scratch HOME)"; exit 1; }

BEFORE_SNAPSHOT="$(find "$SCRATCH" -mindepth 1 | sort)"
OUT_A="$(HOME="$SCRATCH" PYTHONDONTWRITEBYTECODE=1 AGENT_PLUGIN_CACHE_ROOT="$FIX/cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json AGENT_CLAUDE_USER_CONFIG="$SCRATCH/.claude.json" bash "$SETUP" --doctor 2>&1)"
RC_A=$?
AFTER_SNAPSHOT="$(find "$SCRATCH" -mindepth 1 | sort)"

[[ $RC_A -eq 0 ]]
check "doctor-exit-0-on-plugin-path" $?
[[ "$OUT_A" == *"[PASS"*"claude install path — plugin"* ]]
check "plugin-path-detected" $?
[[ "$OUT_A" == *"gh — "* ]]
check "gh-check-present" $?
[[ "$OUT_A" == *"brain MCP (plugin path) — "* ]]
check "brain-mcp-guidance-present" $?
[[ "$BEFORE_SNAPSHOT" == "$AFTER_SNAPSHOT" ]]
check "doctor-scratch-home-zero-writes" $?
rm -rf "$FIX" "$SCRATCH"

# sqlite3/jq ship in /usr/bin on some machines (macOS system Python tooling), so the
# usual "PATH=/usr/bin:/bin" hide-the-tool trick (used for gitleaks elsewhere) does
# NOT hide them here. Build an allowlist-only PATH stub instead: symlink just the
# tools setup.sh's doctor()/supervisor-goal.sh's preflight actually need (resolved
# from the CURRENT PATH), deliberately EXCLUDING sqlite3 and jq. Whitelisting by name
# guarantees the two targets stay absent regardless of where the real machine keeps them.
STUB="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (PATH stub)"; exit 1; }
for c in mkdir dirname basename cat chmod cmp date git grep head paste python3 rm sed tail tr xargs cp sort cut wc; do
  p="$(command -v "$c" 2>/dev/null || true)"
  # printf/echo etc. resolve to bash builtins ("printf", not a path) on some
  # systems — only symlink real absolute paths, never a self-referential name.
  [[ "$p" == /* ]] && ln -sf "$p" "$STUB/$c"
done
# `PATH=X bash script` resolves "bash" itself against the NEW PATH (assignment
# takes effect before the command-name search) — so bash must be invoked by its
# resolved absolute path, or the stub PATH breaks its own interpreter lookup.
BASH_BIN="$(command -v bash)"

echo
echo "=== (c1) gitleaks + sqlite3/jq absence -> doctor WARNs loudly with install hints, never silent ==="
OUT_C1="$(PATH="$STUB" "$BASH_BIN" "$SETUP" --doctor 2>&1)"
RC_C1=$?
[[ $RC_C1 -eq 0 && "$OUT_C1" == *"[WARN"*"gitleaks — not found"*"brew install gitleaks"* ]]
check "gitleaks-loud-warn-not-silent" $?
[[ "$OUT_C1" == *"[WARN"*"goal-mode deps — missing"*"Install: brew/apt install sqlite3 jq"* ]]
check "goalmode-deps-loud-warn-not-silent" $?

echo
echo "=== (c2) goal-mode hard preflight: missing sqlite3/jq -> human-readable ERROR before exit 127 ==="
OUT_C2="$(PATH="$STUB" "$BASH_BIN" "$REPO_ROOT/core/infra/supervisor-goal.sh" status some-plugin-path-fixture-slug 2>&1)"
RC_C2=$?
[[ $RC_C2 -eq 127 ]]
check "goalmode-preflight-exit-127" $?
[[ "$OUT_C2" == *"ERROR: "*" missing. Install via your package manager"* ]]
check "goalmode-preflight-human-readable" $?
[[ "$OUT_C2" != *"command not found"* ]]
check "goalmode-preflight-not-bare-shell-error" $?
rm -rf "$STUB"

echo
echo "=== (d1) ANTI-VACUOUS RED PROBE: broken plugin.json (missing version) -> registry-drift catches it ==="
RFX="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d failed (registry-drift fixture)"; exit 1; }
mkdir -p "$RFX/.claude-plugin" "$RFX/core/hooks" "$RFX/hooks" "$RFX/agents"
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$RFX/.claude-plugin/plugin.json"
cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$RFX/.claude-plugin/marketplace.json"
cp "$REPO_ROOT/hooks/hooks.json" "$RFX/hooks/hooks.json"
cp -R "$REPO_ROOT/core/hooks/." "$RFX/core/hooks/"
cp -R "$REPO_ROOT/agents/." "$RFX/agents/"
python3 - "$RFX/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
del p["version"]
json.dump(p, open(sys.argv[1], "w"))
PY
OUT_D1="$(REGISTRY_DRIFT_ROOT="$RFX" bash "$REGISTRY_DRIFT" 2>&1)"
RC_D1=$?
[[ $RC_D1 -eq 1 ]]
check "red-probe-broken-manifest-detected-exit-1" $?
[[ "$OUT_D1" == *"plugin.json missing version"* ]]
check "red-probe-broken-manifest-named" $?

echo
echo "=== (d2) CONTROL: unmodified manifest fixture -> registry-drift passes (probe is not an always-fail) ==="
cp "$REPO_ROOT/.claude-plugin/plugin.json" "$RFX/.claude-plugin/plugin.json"
OUT_D2="$(REGISTRY_DRIFT_ROOT="$RFX" bash "$REGISTRY_DRIFT" 2>&1)"
RC_D2=$?
[[ $RC_D2 -eq 0 ]]
check "control-clean-manifest-passes" $?
rm -rf "$RFX"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
