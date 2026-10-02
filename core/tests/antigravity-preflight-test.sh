#!/usr/bin/env bash
# antigravity-preflight-test.sh — contract battery for adapters/antigravity/antigravity-preflight.sh.
#
# Every case drives a STUBBED worker on PATH and a FIXTURE registry via
# AGENT_BACKENDS_FILE — zero paid calls. The stub is named after the fixture
# registry's own cmd[0] (antigravity-worker), so the probe's registry->argv
# resolution is exercised for real. The stub speaks the worker's contract:
# agy's --output-format json envelope on stdout, exit 9 for a soft-denied tool
# call, exit 10 for a non-SUCCESS / unparseable envelope.
#
# Usage: bash core/tests/antigravity-preflight-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
PROBE="$REPO_ROOT/adapters/antigravity/antigravity-preflight.sh"
TOKEN="ANTIGRAVITY-PREFLIGHT-OK-7d3f1a"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name] (exit $got)"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected exit $want, got $got"; FAIL=$((FAIL + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (the probe resolves its argv from the registry with jq)"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
export PATH="$STUB_DIR:$PATH"

REG="$TMP/backends.json"
cat > "$REG" <<'JSON'
{ "version": 2, "roles": {},
  "backends": { "gemini": { "vendor": "google", "enabled": true,
    "cmd": ["antigravity-worker"], "tier_args": {"MID": ["--tier","mid"]},
    "preflight": ["antigravity-preflight"] } } }
JSON

mk_stub() {  # mk_stub <body>
  cat > "$STUB_DIR/antigravity-worker" <<STUB
#!/usr/bin/env bash
$1
STUB
  chmod +x "$STUB_DIR/antigravity-worker"
}

echo "=== registry/lane refusals (exit 7 / 1) ==="
AGENT_BACKENDS_FILE="$TMP/nope.json" bash "$PROBE" gemini >/dev/null 2>&1
check "missing-registry-refuses-7" 7 $?
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" no-such-lane >/dev/null 2>&1
check "unknown-lane-refuses-7" 7 $?
rm -f "$STUB_DIR/antigravity-worker"
# Deterministic PATH: the host may have a real ~/bin/antigravity-worker symlink.
PATH="$STUB_DIR:$(dirname "$(command -v jq)"):/usr/bin:/bin" AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "cmd0-not-on-path-exits-1" 1 $?

echo
echo "=== probe outcomes over the worker's JSON envelope ==="
mk_stub "{ printf 'argv:'; printf ' %q' \"\$@\"; printf '\n'; } >> '$TMP/argv'; cat > /dev/null
printf '{\"status\":\"SUCCESS\",\"response\":\"$TOKEN\\\\n\"}\n'"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "success-envelope-with-token-passes-0" 0 $?
grep -q -- '--tier mid' "$TMP/argv" 2>/dev/null; check "probe-rides-cheapest-tier-argv" 0 $?

# Soft-deny: agy exits 0 but a tool approval could not be obtained; the worker
# reports it as exit 9. The lane is reported absent, not healthy.
mk_stub "cat > /dev/null
printf '{\"status\":\"SUCCESS\",\"response\":\"$TOKEN\"}\n'
echo 'antigravity-worker: agy soft-denied a tool call' >&2; exit 9"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "soft-deny-reports-absent-8" 8 $?

mk_stub "cat > /dev/null; printf '{\"status\":\"ERROR\",\"error\":\"boom\"}\n'; exit 10"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "non-success-status-refuses-5" 5 $?

mk_stub "cat > /dev/null; printf '{\"status\":\"SUCCESS\",\"response\":\"hello, how can I help?\"}\n'"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "no-token-in-response-refuses-5" 5 $?

# An error path that echoes the prompt carries the token outside .response —
# that is not proof of inference.
mk_stub "cat > /dev/null; printf '{\"status\":\"SUCCESS\",\"response\":\"hi\"}\n'
echo 'echo of prompt: $TOKEN' >&2"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "token-only-on-stderr-refuses-5" 5 $?

mk_stub "cat > /dev/null; echo 'Error: authentication required' >&2; exit 1"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "authentication-required-refuses-3" 3 $?

mk_stub "cat > /dev/null; echo 'Error: 401 UNAUTHENTICATED'; exit 0"
AGENT_BACKENDS_FILE="$REG" bash "$PROBE" gemini >/dev/null 2>&1
check "auth-error-text-refuses-3-even-on-exit-0" 3 $?

mk_stub "cat > /dev/null; sleep 30"
AGENT_BACKENDS_FILE="$REG" ANTIGRAVITY_PREFLIGHT_TIMEOUT_S=2 bash "$PROBE" gemini >/dev/null 2>&1
check "hung-probe-times-out-4" 4 $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
