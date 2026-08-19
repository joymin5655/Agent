#!/usr/bin/env bash
# gemini-preflight-test.sh — contract battery for adapters/gemini/gemini-preflight.sh.
#
# Every case drives a STUBBED worker on PATH and a FIXTURE registry via
# AGENT_BACKENDS_FILE — zero paid calls. The probe is fail-closed: each case
# pins one refusal path, and the exact-token case pins the only pass path.
# The stub is named after the fixture registry's own cmd[0] (gemini-worker),
# so the probe's registry->argv resolution is exercised for real (kiro
# preflight hole (d): a probe that validates a different executable than the
# dispatch lies).
#
# Usage: bash core/tests/gemini-preflight-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
PROBE="$REPO_ROOT/adapters/gemini/gemini-preflight.sh"
TOKEN="GEMINI-PREFLIGHT-OK-7d1f3a"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name] (exit $got)"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected exit $want, got $got"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
export PATH="$STUB_DIR:$PATH"

REG="$TMP/backends.json"
cat > "$REG" <<'JSON'
{ "version": 2, "roles": {},
  "backends": { "gemini": { "vendor": "google", "enabled": false,
    "cmd": ["gemini-worker"], "tier_args": {"MID": ["--tier","mid"]},
    "preflight": ["gemini-preflight"] } } }
JSON

mk_stub() {  # mk_stub <body>
  cat > "$STUB_DIR/gemini-worker" <<STUB
#!/usr/bin/env bash
$1
STUB
  chmod +x "$STUB_DIR/gemini-worker"
}

echo "=== registry/lane refusals (exit 7 / 1) ==="
AGENT_BACKENDS_FILE="$TMP/nope.json" bash "$PROBE" gemini >/dev/null 2>&1
check "missing-registry-refuses-7" 7 $?
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" no-such-lane >/dev/null 2>&1
check "unknown-lane-refuses-7" 7 $?
rm -f "$STUB_DIR/gemini-worker"
# Deterministic PATH: the host may have a REAL ~/bin/gemini-worker symlink
# installed (setup.sh --gemini), which would satisfy command -v and flip this
# case. Restrict to the stub dir + system dirs (jq/grep live there).
PATH="$STUB_DIR:$(dirname "$(command -v jq)"):/usr/bin:/bin" AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "cmd0-not-on-path-exits-1" 1 $?

echo
echo "=== probe outcomes over the registry argv ==="
# Pass path: exact token comes back, argv recorded for the assertion below.
mk_stub "{ printf 'argv:'; printf ' %q' \"\$@\"; printf '\n'; } >> '$TMP/argv'; cat > /dev/null; echo 'banner'; echo '$TOKEN'"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "exact-token-passes-0" 0 $?
grep -q -- '--tier mid' "$TMP/argv" 2>/dev/null; check "probe-rides-cheapest-tier-argv" 0 $?
# Mutation note: probing `gemini --version` instead of the worker round trip
# fails probe-rides-cheapest-tier-argv (and the token case, since --version
# carries no token).

mk_stub "cat > /dev/null; echo 'Error: 401 UNAUTHENTICATED'; exit 0"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "auth-error-text-refuses-3-even-on-exit-0" 3 $?

mk_stub "cat > /dev/null; echo 'IneligibleTierError: account not eligible'; exit 0"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "ineligible-tier-refuses-3" 3 $?

mk_stub "cat > /dev/null; echo 'hello, how can I help?'"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "no-token-reply-refuses-5" 5 $?

mk_stub "cat > /dev/null; echo 'boom'; exit 9"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "nonzero-exit-refuses-5" 5 $?

mk_stub "cat > /dev/null; sleep 30"
AGENT_BACKENDS_FILE="$REG" GEMINI_PREFLIGHT_TIMEOUT_S=2 bash "$PROBE" gemini >/dev/null 2>&1
check "hung-probe-times-out-4" 4 $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
