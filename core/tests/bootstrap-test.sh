#!/usr/bin/env bash
# bootstrap-test.sh — the dependency-bootstrap + local-layer-export battery (Wave 2).
#
# Covers `setup.sh --bootstrap` (missing-dependency installer with per-package
# consent) and `core/infra/local-layer-export.sh` (global-layer -> generic YAML
# manifest, gitleaks-gated save). NO real package manager is ever invoked here —
# brew/apt-get/sudo are all PATH-stub mocks that log their invocation and exit 0;
# a test that actually shelled out to a real installer would not be a test, it
# would be a system mutation.
#
#   (a) all-dependencies-present short-circuit (no OS/pkg-mgr detection needed).
#   (b) --dry-run: prints the install plan, calls the mocked installer ZERO times,
#       zero filesystem mutation under a scratch $HOME (same snapshot-diff pattern
#       Wave 1's plugin-path-install-test.sh established).
#   (c) non-interactive stdin (`echo | ...`, no seam involved — this is what a
#       real pipe naturally is) forces the SAME dry-run downgrade, zero installs.
#   (d) interactive consent (AGENT_BOOTSTRAP_STDIN_IS_TTY=1 test seam + scripted
#       y/n answers): a "n" answer must NOT invoke the mock installer, a "y"
#       answer MUST — in the SAME run, across two different missing deps. This is
#       the RED-probe-shaped assertion: if per-package gating were broken (e.g.
#       consent ignored, or all-or-nothing), either half of this pairing would
#       fail. Verified by manual mutation during development (see lane report).
#   (e) apt branch (AGENT_BOOTSTRAP_PKG_MGR=apt seam, mocked apt-get+sudo) gets
#       the same coverage as the brew branch, so the Linux path isn't unexercised
#       just because this suite likely runs on macOS.
#   (f) unsupported package manager -> exit 1, missing deps named, zero installs.
#   (g) local-layer-export.sh happy path: hooks/plugins/skills all render
#       correctly from synthetic fixtures (never the real global config). Uses
#       real gitleaks when the host has it; on a gitleaks-less host (CI), the
#       AGENT_EXPORT_SCANNER seam points the exporter at a deterministic stub
#       (see build_scanner_stub below) so this stays a real pass/fail check
#       instead of universally failing closed — mirrors gitleaks-fire-test.sh's
#       "SKIP loud, don't silently pass" spirit, but here we CAN keep exercising
#       the code path via the seam rather than skipping it outright.
#   (h) local-layer-export.sh ANTI-VACUOUS RED PROBE: a secret embedded in a
#       hook command string must make the exporter REFUSE to save (file never
#       created), paired with the (g) clean-fixture CONTROL proving the probe
#       isn't an always-fail. Same real-or-stub scanner choice as (g) — the stub
#       matches on the identical sk-ant- pattern this repo's own gitleaks.toml
#       rule catches, so the refusal path is exercised for the right reason on
#       either host.
#   (i) local-layer-export.sh fail-closed when gitleaks itself is absent (cannot
#       claim "0 findings" without running the scanner). Deliberately does NOT
#       use the AGENT_EXPORT_SCANNER seam — it PATH-stubs gitleaks out instead,
#       so this section always exercises the genuine absent-scanner code path
#       regardless of what (g)/(h) chose.
#   (j) setup.sh --doctor is unaffected by any of the above — still exit 0, still
#       read-only under a scratch-HOME snapshot (regression guard: bootstrap must
#       never leak side effects into the diagnosis path).
#
# Usage: bash core/tests/bootstrap-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
EXPORTER="$REPO_ROOT/core/infra/local-layer-export.sh"

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

safe_mktemp_d() {
  local d
  d="$(mktemp -d)" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  printf '%s\n' "$d"
}

# build_stub <dir> <extra-cmd-list...> — populate <dir> with symlinks to every
# real absolute-path command bootstrap()/doctor() need, EXCLUDING whatever the
# caller wants to simulate as missing (by simply not listing it). Mirrors the
# allowlist-only PATH stub pattern from plugin-path-install-test.sh.
#
# BASE_CMDS (tools this script's OWN plumbing genuinely executes — mkdir, cat,
# sed, ...) are symlinked to the real host binary only, same as always: if one
# is truly absent the caller has a bigger problem than this test. The EXTRA
# args (bootstrap-managed deps: gitleaks/sqlite3/jq/gh), by contrast, are only
# ever PRESENCE-checked by setup.sh's bootstrap()/doctor() (`command -v`, never
# invoked) when a caller lists them here to mean "this dep already exists" —
# so on a host that genuinely lacks one (e.g. a CI runner with no gitleaks
# binary at all), a harmless no-op placeholder satisfies that same contract
# without depending on host tooling the fixture never actually needed to run.
BASE_CMDS="mkdir dirname basename cat chmod cmp date git grep head paste python3 rm sed tail tr xargs cp sort cut wc uname find"
build_stub() {
  local dir="$1"; shift
  local c p
  for c in $BASE_CMDS; do
    p="$(command -v "$c" 2>/dev/null || true)"
    [[ "$p" == /* ]] && ln -sf "$p" "$dir/$c"
  done
  for c in "$@"; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [[ "$p" == /* ]]; then
      ln -sf "$p" "$dir/$c"
    else
      printf '#!/bin/sh\nexit 0\n' > "$dir/$c"
      chmod +x "$dir/$c"
    fi
  done
}
BASH_BIN="$(command -v bash)"

# build_scanner_stub <dir> — a deterministic stand-in for gitleaks that speaks
# just enough of its CLI surface for local-layer-export.sh's call site
# (`detect --no-git --source <file> [--config <path>]`): find the --source
# file, grep it for the exact pattern this repo's OWN gitleaks.toml
# anthropic-api-key rule catches (sk-ant-[A-Za-z0-9_-]{20,}), exit 1 (leak
# found — same as real gitleaks) if present, exit 0 (clean) otherwise. Used
# ONLY when the host has no real gitleaks (see the seam selection below) —
# CI-portability fix, not a permanent replacement for the real fire-test.
build_scanner_stub() {
  local dir="$1"
  cat > "$dir/stub-scanner.sh" <<'EOF'
#!/bin/sh
src=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) src="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$src" ] || exit 2
grep -qE 'sk-ant-[A-Za-z0-9_-]{20,}' "$src" && exit 1
exit 0
EOF
  chmod +x "$dir/stub-scanner.sh"
}

# Seam selection: real gitleaks when the host has it (so this battery still
# doubles as a real fire-test locally), the deterministic stub otherwise (so
# a gitleaks-less CI runner exercises the same pass/fail branches instead of
# universally failing closed on every (g)/(h) call). A plain scalar (not an
# array) — macOS ships bash 3.2, where `"${arr[@]}"` on an EMPTY array under
# `set -u` throws "unbound variable" (fixed only in bash 4.4+); a scalar has
# no such trap and needs no conditional-expansion idiom at the call sites.
SCANNER_SEAM_VALUE="gitleaks"
if ! command -v gitleaks >/dev/null 2>&1; then
  STUB_SCANNER_DIR="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
  build_scanner_stub "$STUB_SCANNER_DIR"
  SCANNER_SEAM_VALUE="$STUB_SCANNER_DIR/stub-scanner.sh"
fi

echo "=== (a) all dependencies present -> short-circuit message, no OS detection needed ==="
STUB_A="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
build_stub "$STUB_A" sqlite3 jq gitleaks gh
OUT_A="$(PATH="$STUB_A" "$BASH_BIN" "$SETUP" --bootstrap 2>&1)"
RC_A=$?
[[ $RC_A -eq 0 && "$OUT_A" == *"All bootstrap-managed dependencies already present"* ]]
check "all-present-short-circuit" $?
rm -rf "$STUB_A"

# --- shared fixture for (b)-(f): gh missing, everything else present, mocked brew ---
# (b)-(d) pin AGENT_BOOTSTRAP_PKG_MGR=brew at the call sites: without the seam,
# bootstrap() detects the REAL host OS (uname), so on a Linux CI runner these
# brew-mock sections would take the apt branch (and exit 1, apt-get not being in
# the stub PATH) — the assertions are only meaningful with the brew path pinned.
setup_missing_gh_fixture() {
  local dir="$1" log="$2"
  build_stub "$dir" sqlite3 jq gitleaks
  cat > "$dir/brew" <<EOF
#!/bin/sh
echo "MOCK_BREW: \$*" >> "$log"
exit 0
EOF
  chmod +x "$dir/brew"
}

echo
echo "=== (b) --dry-run: plan printed, ZERO installer calls, zero fs mutation under scratch HOME ==="
STUB_B="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
LOG_B="$(mktemp)" || { echo "FAIL: mktemp"; exit 1; }
setup_missing_gh_fixture "$STUB_B" "$LOG_B"
SCRATCH_B="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
BEFORE_B="$(find "$SCRATCH_B" -mindepth 1 | sort)"
OUT_B="$(HOME="$SCRATCH_B" PYTHONDONTWRITEBYTECODE=1 AGENT_BOOTSTRAP_PKG_MGR=brew PATH="$STUB_B" "$BASH_BIN" "$SETUP" --bootstrap --dry-run 2>&1)"
RC_B=$?
AFTER_B="$(find "$SCRATCH_B" -mindepth 1 | sort)"
[[ $RC_B -eq 0 ]]
check "dry-run-exit-0" $?
[[ "$OUT_B" == *"[dry-run] would run: brew install gh"* ]]
check "dry-run-prints-plan" $?
[[ ! -s "$LOG_B" ]]
check "dry-run-zero-installer-calls" $?
[[ "$BEFORE_B" == "$AFTER_B" ]]
check "dry-run-zero-fs-mutation" $?
rm -rf "$STUB_B" "$SCRATCH_B" "$LOG_B"

echo
echo "=== (c) non-interactive stdin (real pipe, no seam) -> forced dry-run downgrade, zero installs ==="
STUB_C="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
LOG_C="$(mktemp)" || { echo "FAIL: mktemp"; exit 1; }
setup_missing_gh_fixture "$STUB_C" "$LOG_C"
OUT_C="$(echo | env AGENT_BOOTSTRAP_PKG_MGR=brew PATH="$STUB_C" "$BASH_BIN" "$SETUP" --bootstrap 2>&1)"
RC_C=$?
[[ $RC_C -eq 0 && "$OUT_C" == *"downgraded to --dry-run"* ]]
check "noninteractive-downgrade-note" $?
[[ ! -s "$LOG_C" ]]
check "noninteractive-zero-installer-calls" $?
rm -rf "$STUB_C" "$LOG_C"

echo
echo "=== (d) interactive consent (seam-forced), mixed y/n across 2 missing deps: n skips, y installs -> RED-probe-shaped pairing ==="
STUB_D="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
LOG_D="$(mktemp)" || { echo "FAIL: mktemp"; exit 1; }
build_stub "$STUB_D" sqlite3 jq
cat > "$STUB_D/brew" <<EOF
#!/bin/sh
echo "MOCK_BREW: \$*" >> "$LOG_D"
exit 0
EOF
chmod +x "$STUB_D/brew"
# gitleaks AND gh both excluded from the stub -> both missing. Answer "n" to the
# first prompt, "y" to the second (order follows the deps array: gitleaks, sqlite3,
# jq, gh — with sqlite3/jq present, only gitleaks then gh are ever prompted).
OUT_D="$(printf 'n\ny\n' | AGENT_BOOTSTRAP_STDIN_IS_TTY=1 AGENT_BOOTSTRAP_PKG_MGR=brew PATH="$STUB_D" "$BASH_BIN" "$SETUP" --bootstrap 2>&1)"
RC_D=$?
[[ $RC_D -eq 0 ]]
check "interactive-exit-0" $?
[[ "$OUT_D" == *"... skipped: gitleaks"* ]]
check "interactive-n-answer-skips" $?
[[ "$OUT_D" == *"Installing gh"* ]]
check "interactive-y-answer-installs" $?
# The pairing that actually catches a broken gate: exactly ONE mock call, and it
# must be for "gh", never for "gitleaks" (a broken all-or-nothing gate, or one
# that ignores the answer entirely, would fail one of these two).
[[ "$(cat "$LOG_D")" == "MOCK_BREW: install gh" ]]
check "interactive-exactly-one-call-for-consented-pkg-only" $?
rm -rf "$STUB_D" "$LOG_D"

echo
echo "=== (e) apt branch (AGENT_BOOTSTRAP_PKG_MGR seam, mocked apt-get+sudo): same y-consent -> install coverage ==="
STUB_E="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
LOG_E="$(mktemp)" || { echo "FAIL: mktemp"; exit 1; }
build_stub "$STUB_E" sqlite3 jq gitleaks
cat > "$STUB_E/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
chmod +x "$STUB_E/sudo"
cat > "$STUB_E/apt-get" <<EOF
#!/bin/sh
echo "MOCK_APT: \$*" >> "$LOG_E"
exit 0
EOF
chmod +x "$STUB_E/apt-get"
OUT_E="$(printf 'y\n' | AGENT_BOOTSTRAP_STDIN_IS_TTY=1 AGENT_BOOTSTRAP_PKG_MGR=apt PATH="$STUB_E" "$BASH_BIN" "$SETUP" --bootstrap 2>&1)"
RC_E=$?
[[ $RC_E -eq 0 && "$OUT_E" == *"Package manager: apt"* ]]
check "apt-branch-detected-via-seam" $?
[[ "$(cat "$LOG_E")" == "MOCK_APT: install -y gh" ]]
check "apt-branch-invokes-mocked-apt-get-via-sudo" $?
rm -rf "$STUB_E" "$LOG_E"

echo
echo "=== (f) unsupported package manager (AGENT_BOOTSTRAP_PKG_MGR=\"\" seam) -> exit 1, missing deps named, zero installs ==="
STUB_F="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
build_stub "$STUB_F" sqlite3 jq gitleaks
OUT_F="$(AGENT_BOOTSTRAP_PKG_MGR="" PATH="$STUB_F" "$BASH_BIN" "$SETUP" --bootstrap 2>&1)"
RC_F=$?
[[ $RC_F -eq 1 && "$OUT_F" == *"No supported package manager detected"*"gh"* ]]
check "unsupported-pkg-mgr-exit-1-named" $?
rm -rf "$STUB_F"

echo
echo "=== (f2) MED-2: AGENT_BOOTSTRAP_STDIN_IS_TTY=1 ALONE (no pkg-mgr seam) must NOT enable installs on a piped stdin ==="
# On a real host pkg_mgr is auto-detected (seam unset), so the tty override must
# be inert — else `yes y | AGENT_BOOTSTRAP_STDIN_IS_TTY=1 setup.sh --bootstrap`
# would auto-consent to a real `sudo apt-get install` on a NOPASSWD host. Piped
# stdin + tty-seam-only must still downgrade to dry-run with zero installer calls.
STUB_F2="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
build_stub "$STUB_F2" sqlite3 jq gh
CALLLOG_F2="$STUB_F2/install-calls.log"
# mock whichever real manager this platform auto-detects (brew on macOS, apt-get
# +sudo on Linux) so pkg_mgr resolves WITHOUT the seam; any invocation logs.
for m in brew apt-get sudo; do
  cat > "$STUB_F2/$m" <<EOF
#!/bin/sh
echo "INSTALL_INVOKED: $m \$*" >> "$CALLLOG_F2"
EOF
  chmod +x "$STUB_F2/$m"
done
OUT_F2="$(printf 'y\ny\n' | env AGENT_BOOTSTRAP_STDIN_IS_TTY=1 PATH="$STUB_F2" "$BASH_BIN" "$SETUP" --bootstrap 2>&1)"
RC_F2=$?
[[ $RC_F2 -eq 0 && "$OUT_F2" == *"dry-run"* && ! -f "$CALLLOG_F2" ]]
check "tty-seam-alone-cannot-force-real-install" $?
rm -rf "$STUB_F2"

echo
echo "=== (g) local-layer-export.sh happy path: hooks/plugins/skills all render from synthetic fixtures ==="
FIX_G="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
cat > "$FIX_G/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"\"/some/path/adapter.sh\" agent-session-start.sh"}
]}]}}
JSON
mkdir -p "$FIX_G/cache/market/agent-harness/0.5.4" "$FIX_G/cache/market/agent-harness/0.5.5"
mkdir -p "$FIX_G/skills/spec" "$FIX_G/skills/supervise"
OUT_G_FILE="$FIX_G/out.yml"
OUT_G="$(AGENT_GLOBAL_SETTINGS="$FIX_G/settings.json" AGENT_PLUGIN_CACHE_ROOT="$FIX_G/cache" AGENT_GLOBAL_SKILLS_DIR="$FIX_G/skills" AGENT_EXPORT_SCANNER="$SCANNER_SEAM_VALUE" bash "$EXPORTER" "$OUT_G_FILE" 2>&1)"
RC_G=$?
[[ $RC_G -eq 0 && -f "$OUT_G_FILE" ]]
check "export-happy-path-exit-0-file-written" $?
[[ "$(cat "$OUT_G_FILE")" == *'event: "SessionStart"'* && "$(cat "$OUT_G_FILE")" == *'command: "agent-session-start.sh"'* ]]
check "export-hooks-rendered" $?
[[ "$(cat "$OUT_G_FILE")" == *'name: "agent-harness"'* && "$(cat "$OUT_G_FILE")" == *'version: "0.5.5"'* ]]
check "export-plugins-rendered-latest-version" $?
[[ "$(cat "$OUT_G_FILE")" == *'- "spec"'* && "$(cat "$OUT_G_FILE")" == *'- "supervise"'* ]]
check "export-skills-rendered" $?
[[ "$(cat "$OUT_G_FILE")" != *"/some/path/"* ]]
check "export-no-absolute-paths-leaked" $?

echo
echo "=== (h) ANTI-VACUOUS RED PROBE: secret in a hook script name -> export REFUSES to save (paired with (g)'s clean control) ==="
# gitleaks-safe fixture: assemble the synthetic key at runtime (${Z} splice
# convention, cf. PR#103) so the contiguous sk-ant- pattern — which this repo's
# own gitleaks.toml rule now catches — never exists as a literal in this
# committed file. The secret rides in the hook SCRIPT FILENAME (…​.sh): the
# emitter now emits only script-extension tokens (never trailing args — see the
# MED-3 fix / (i4)), so a leaky --key=arg would NOT reach the manifest; the
# realistic residual vector is a secret embedded in a filename, which does. The
# rendered fixture still carries the full sk-ant- pattern, exercising the
# refusal path.
Z="ant"
FAKE_KEY="sk-${Z}-api03-mOCegejpkfgCrZiEYKwqG0EIwv31lctdBUbkfLnirNrujjqAXVZQ8N52CWiQDaFXWDivw5TJfAMXJL4uQFyrdHjWfJz1R4B"
printf '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[\n  {"type":"command","command":"\\"/some/path/adapter.sh\\" leaky-%s.sh"}\n]}]}}\n' "$FAKE_KEY" > "$FIX_G/leaky-settings.json"
OUT_H_FILE="$FIX_G/leaky-out.yml"
OUT_H="$(AGENT_GLOBAL_SETTINGS="$FIX_G/leaky-settings.json" AGENT_PLUGIN_CACHE_ROOT="$FIX_G/no-cache" AGENT_GLOBAL_SKILLS_DIR="$FIX_G/no-skills" AGENT_EXPORT_SCANNER="$SCANNER_SEAM_VALUE" bash "$EXPORTER" "$OUT_H_FILE" 2>&1)"
RC_H=$?
[[ $RC_H -eq 1 && "$OUT_H" == *"REFUSED"* ]]
check "red-probe-secret-injection-refused-exit-1" $?
[[ ! -f "$OUT_H_FILE" ]]
check "red-probe-secret-injection-file-not-written" $?
rm -rf "$FIX_G"

echo
echo "=== (i) local-layer-export.sh fail-closed when gitleaks itself is absent ==="
STUB_I="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
build_stub "$STUB_I" sqlite3 jq
FIX_I="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
OUT_I_FILE="$FIX_I/out.yml"
OUT_I="$(PATH="$STUB_I" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json AGENT_PLUGIN_CACHE_ROOT=/nonexistent/cache AGENT_GLOBAL_SKILLS_DIR=/nonexistent/skills "$BASH_BIN" "$EXPORTER" "$OUT_I_FILE" 2>&1)"
RC_I=$?
[[ $RC_I -eq 2 && "$OUT_I" == *"gitleaks not installed"* ]]
check "export-failclosed-no-gitleaks" $?
[[ ! -f "$OUT_I_FILE" ]]
check "export-failclosed-file-not-written" $?
rm -rf "$STUB_I" "$FIX_I"

echo
echo "=== (i2) missing AGENT_GITLEAKS_CONFIG must FAIL CLOSED (exit 2), not down-scan with built-in rules ==="
# gitleaks' built-in rules miss the sk-ant- session/oauth/variant shapes the repo
# gitleaks.toml catches (measured 0/3 vs 3/3), so a config-less scan is a weaker
# gate — "ruleset absent" is the same epistemic state as "scanner absent": exit 2.
# (Also guards the old bash-3.2 empty-array crash: exit 2 with a real error, never
# a crash masquerading as a refusal.)
FIX_I2="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
cat > "$FIX_I2/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"\"/some/path/adapter.sh\" agent-session-start.sh"}
]}]}}
JSON
OUT_I2_FILE="$FIX_I2/out.yml"
OUT_I2="$(AGENT_GLOBAL_SETTINGS="$FIX_I2/settings.json" AGENT_PLUGIN_CACHE_ROOT="$FIX_I2/no-cache" AGENT_GLOBAL_SKILLS_DIR="$FIX_I2/no-skills" AGENT_GITLEAKS_CONFIG=/nonexistent/gitleaks.toml AGENT_EXPORT_SCANNER="$SCANNER_SEAM_VALUE" bash "$EXPORTER" "$OUT_I2_FILE" 2>&1)"
RC_I2=$?
[[ $RC_I2 -eq 2 && ! -f "$OUT_I2_FILE" && "$OUT_I2" == *"ruleset not found"* && "$OUT_I2" != *"unbound variable"* ]]
check "export-missing-config-fails-closed-exit-2" $?
rm -rf "$FIX_I2"

echo
echo "=== (i3) MED-3: hook trailing args (secret/PII) never reach the manifest — only the script name does ==="
FIX_I3="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
# a hook whose command carries a PII arg (--user alice) and a --home path; the
# emitter must export only the .sh script basename, dropping every argument.
# synthetic /home/ path (not /Users/, which the sanitize gate reserves for REAL
# home paths); still a home-shaped arg whose basename would be PII if leaked.
cat > "$FIX_I3/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"\"/home/synthuser/.claude/adapter.sh\" real-hook.sh --user synthuser --home /home/synthuser"}
]}]}}
JSON
OUT_I3_FILE="$FIX_I3/out.yml"
OUT_I3="$(AGENT_GLOBAL_SETTINGS="$FIX_I3/settings.json" AGENT_PLUGIN_CACHE_ROOT="$FIX_I3/no-cache" AGENT_GLOBAL_SKILLS_DIR="$FIX_I3/no-skills" AGENT_EXPORT_SCANNER="$SCANNER_SEAM_VALUE" bash "$EXPORTER" "$OUT_I3_FILE" 2>&1)"
RC_I3=$?
[[ $RC_I3 -eq 0 && -f "$OUT_I3_FILE" ]] && \
  [[ "$(cat "$OUT_I3_FILE")" == *'command: "real-hook.sh"'* ]] && \
  [[ "$(cat "$OUT_I3_FILE")" != *synthuser* && "$(cat "$OUT_I3_FILE")" != *"/home/"* ]]
check "export-hook-args-and-pii-not-leaked" $?
rm -rf "$FIX_I3"

echo
echo "=== (i4) MED-3 followup: an ARG value ending in a script extension must NOT displace the script name ==="
FIX_I4="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
# last-token / last-extension heuristics would export "leaked.py" (the arg value);
# stopping at the first flag keeps only the real script "real-hook.sh".
cat > "$FIX_I4/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[
  {"type":"command","command":"\"/opt/x/real-hook.sh\" --config=/tmp/leaked.py"}
]}]}}
JSON
OUT_I4_FILE="$FIX_I4/out.yml"
OUT_I4="$(AGENT_GLOBAL_SETTINGS="$FIX_I4/settings.json" AGENT_PLUGIN_CACHE_ROOT="$FIX_I4/no-cache" AGENT_GLOBAL_SKILLS_DIR="$FIX_I4/no-skills" AGENT_EXPORT_SCANNER="$SCANNER_SEAM_VALUE" bash "$EXPORTER" "$OUT_I4_FILE" 2>&1)"
RC_I4=$?
[[ $RC_I4 -eq 0 && "$(cat "$OUT_I4_FILE")" == *'command: "real-hook.sh"'* && "$(cat "$OUT_I4_FILE")" != *leaked.py* ]]
check "export-arg-extension-does-not-win" $?
rm -rf "$FIX_I4"

echo
echo "=== (i5) an extension-less / piped-shell hook must stay VISIBLE (first-token basename), not silently vanish ==="
FIX_I5="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
cat > "$FIX_I5/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[
  {"type":"command","command":"rtk hook claude"}
]}],"UserPromptSubmit":[{"matcher":"*","hooks":[
  {"type":"command","command":"node /opt/x/binary-hook --flag v"}
]}]}}
JSON
OUT_I5_FILE="$FIX_I5/out.yml"
OUT_I5="$(AGENT_GLOBAL_SETTINGS="$FIX_I5/settings.json" AGENT_PLUGIN_CACHE_ROOT="$FIX_I5/no-cache" AGENT_GLOBAL_SKILLS_DIR="$FIX_I5/no-skills" AGENT_EXPORT_SCANNER="$SCANNER_SEAM_VALUE" bash "$EXPORTER" "$OUT_I5_FILE" 2>&1)"
RC_I5=$?
# both hooks present (executable basenames rtk / node), no argument values leaked
[[ $RC_I5 -eq 0 ]] && \
  [[ "$(cat "$OUT_I5_FILE")" == *'command: "rtk"'* && "$(cat "$OUT_I5_FILE")" == *'command: "node"'* ]] && \
  [[ "$(cat "$OUT_I5_FILE")" != *claude* && "$(cat "$OUT_I5_FILE")" != *binary-hook* && "$(cat "$OUT_I5_FILE")" != *"--flag"* ]]
check "export-extensionless-hook-stays-visible" $?
rm -rf "$FIX_I5"

echo
echo "=== (i6) gate liveness canary: a DEAD gate (existing-but-ruleless config) fails closed, secret never written ==="
FIX_I6="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
Z6="ant"
FAKE6="sk-${Z6}-api03-mOCegejpkfgCrZiEYKwqG0EIwv31lctdBUbkfLnirNrujjqAXVZQ8N52CWiQDaFXWDivw5TJfAMXJL4uQFyrdHjWfJz1R4B"
printf '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[\n  {"type":"command","command":"\\"/x/adapter.sh\\" leaky-%s.sh"}\n]}]}}\n' "$FAKE6" > "$FIX_I6/settings.json"
: > "$FIX_I6/empty.toml"   # exists (-f true) but carries NO rules -> gate is dead
OUT_I6_FILE="$FIX_I6/out.yml"
# NOTE: real gitleaks with an empty ruleset finds nothing; the stub always matches
# sk-ant- regardless of --config, so the canary only proves "dead gate" against a
# real scanner. Run this section ONLY when real gitleaks is present.
if [[ "$SCANNER_SEAM_VALUE" == "gitleaks" ]]; then
  OUT_I6="$(AGENT_GLOBAL_SETTINGS="$FIX_I6/settings.json" AGENT_PLUGIN_CACHE_ROOT="$FIX_I6/no-cache" AGENT_GLOBAL_SKILLS_DIR="$FIX_I6/no-skills" AGENT_GITLEAKS_CONFIG="$FIX_I6/empty.toml" bash "$EXPORTER" "$OUT_I6_FILE" 2>&1)"
  RC_I6=$?
  [[ $RC_I6 -eq 2 && ! -f "$OUT_I6_FILE" && "$OUT_I6" == *"gate is not functioning"* ]]
  check "export-dead-gate-canary-fails-closed" $?
else
  check "export-dead-gate-canary-fails-closed (skipped: stub scanner cannot model a dead ruleset)" 0
fi
rm -rf "$FIX_I6"

echo
echo "=== (j) setup.sh --doctor is unaffected: still exit 0, still read-only (scratch-HOME snapshot) ==="
SCRATCH_J="$(safe_mktemp_d)" || { echo "FAIL: mktemp -d"; exit 1; }
BEFORE_J="$(find "$SCRATCH_J" -mindepth 1 | sort)"
OUT_J="$(HOME="$SCRATCH_J" PYTHONDONTWRITEBYTECODE=1 AGENT_PLUGIN_CACHE_ROOT="$SCRATCH_J/no-cache" AGENT_GLOBAL_SETTINGS=/nonexistent/settings.json AGENT_CLAUDE_USER_CONFIG="$SCRATCH_J/.claude.json" "$BASH_BIN" "$SETUP" --doctor 2>&1)"
RC_J=$?
AFTER_J="$(find "$SCRATCH_J" -mindepth 1 | sort)"
[[ $RC_J -eq 0 ]]
check "doctor-still-exit-0-after-bootstrap-changes" $?
[[ "$BEFORE_J" == "$AFTER_J" ]]
check "doctor-still-read-only-after-bootstrap-changes" $?
rm -rf "$SCRATCH_J"

[[ -n "${STUB_SCANNER_DIR:-}" ]] && rm -rf "$STUB_SCANNER_DIR"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
