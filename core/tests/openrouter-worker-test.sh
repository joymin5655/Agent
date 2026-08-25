#!/usr/bin/env bash
# openrouter-worker-test.sh — contract battery for
# adapters/openrouter/openrouter-worker.sh and openrouter-preflight.sh.
#
# Every case drives STUBBED `curl` and `security` on PATH — zero network
# calls, zero paid calls. The battery asserts on the PAYLOAD/argv the worker
# composes (model resolved from the tiers file, prompt in the JSON body) and
# on its guard/classification behavior (sensitive-cwd refusal, Keychain
# refusal, 429 -> fail-open, retention warning), because those are the
# properties adapters/openrouter/README.md documents as this lane's actual
# safety boundary (no OS sandbox — this is a plain HTTP call, not a wrapped
# agentic CLI).
#
# Usage: bash core/tests/openrouter-worker-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
WORKER="$REPO_ROOT/adapters/openrouter/openrouter-worker.sh"
PREFLIGHT="$REPO_ROOT/adapters/openrouter/openrouter-preflight.sh"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 2; }

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"   # canonicalize (macOS mktemp lands under a
                                # /var/folders symlink to /private/var/folders;
                                # the worker resolves its cwd the same way via
                                # `pwd -P`, so a fixture path written unresolved
                                # would never match — same class of pitfall as
                                # macOS's $TMPDIR-vs-/tmp symlink).
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"

TIERS="$TMP/tiers.json"
cat > "$TIERS" <<'JSON'
{ "tiers": {
    "LOW":  { "model": "stub/low-free" },
    "MID":  { "model": "stub/mid-free" },
    "TOP":  { "model": "stub/top-free" }
} }
JSON

SENS="$TMP/sensitive-paths"
cat > "$SENS" <<EOF
# comment line, and a blank line follow

$TMP/blocked-project
EOF

# Stub `security` — always returns a fake key unless STUB_NO_KEY is set.
write_security_stub() {
  local mode="$1"   # ok | missing
  if [[ "$mode" == "missing" ]]; then
    cat > "$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  else
    cat > "$STUB_DIR/security" <<'STUB'
#!/usr/bin/env bash
echo "STUB-OPENROUTER-KEY-42"
STUB
  fi
  chmod +x "$STUB_DIR/security"
}

# Stub `curl` — records its config-file contents and the payload it was told
# to send, then answers according to $CURL_MODE (env baked into the stub).
write_curl_stub() {  # write_curl_stub <mode: ok|429|error> [reply-content]
  local mode="$1" reply="${2:-STUB-REPLY-TEXT}"
  cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
# find -K <cfgfile> and -o <outfile> in argv
cfg=""; out=""
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "-K" ]]; then cfg="\$a"; fi
  if [[ "\$prev" == "-o" ]]; then out="\$a"; fi
  prev="\$a"
done
cp "\$cfg" "$TMP/last-curl-cfg"
# Copy the referenced payload file's CONTENT out too, while it still exists —
# the worker's own WORK_DIR (holding the payload) is removed by its EXIT trap
# once it finishes, before this test script gets a chance to inspect it.
data_ref="\$(grep '^data = @' "\$cfg" | sed 's/^data = @//')"
[[ -n "\$data_ref" && -f "\$data_ref" ]] && cp "\$data_ref" "$TMP/last-payload.json"
case "$mode" in
  ok)
    cat > "\$out" <<JSON
{"choices":[{"message":{"content":"$reply"}}]}
JSON
    printf '200'
    ;;
  429)
    printf '{}' > "\$out"
    printf '429'
    ;;
  error)
    printf '{"error":{"message":"boom"}}' > "\$out"
    printf '500'
    ;;
esac
exit 0
STUB
  chmod +x "$STUB_DIR/curl"
}

run_worker() {  # run_worker <tier> <prompt> [extra env...]
  local tier="$1" prompt="$2"; shift 2
  ( cd "$TMP" && printf '%s' "$prompt" | env PATH="$STUB_DIR:/usr/bin:/bin" \
      OPENROUTER_TIERS_FILE="$TIERS" \
      OPENROUTER_SENSITIVE_PATHS_FILE="$SENS" \
      "$@" \
      bash "$WORKER" --tier "$tier" )
}

echo "=== (a) happy path: model from tiers file, prompt reaches the payload ==="
write_security_stub ok
write_curl_stub ok "hello from stub"
out="$(run_worker mid 'PROBE-PROMPT-9' 2>"$TMP/err_a")"; rc=$?
check "happy-path-exits-0" 0 "$rc"
check "stdout-is-assistant-content" "hello from stub" "$out"
# The stub copies the payload file's content out before the worker's own
# EXIT trap removes its WORK_DIR (see write_curl_stub) — read that copy.
if [[ -f "$TMP/last-payload.json" ]]; then
  jq -e '.model == "stub/mid-free"' "$TMP/last-payload.json" >/dev/null 2>&1
  check "payload-model-is-mid-tier-pin" 0 $?
  jq -e '.messages[0].content == "PROBE-PROMPT-9"' "$TMP/last-payload.json" >/dev/null 2>&1
  check "payload-prompt-matches-stdin" 0 $?
else
  check "payload-model-is-mid-tier-pin" 0 1
  check "payload-prompt-matches-stdin" 0 1
fi
grep -qi "retain\|train" "$TMP/err_a"; check "retention-warning-on-stderr" 0 $?
grep -q '^header = "Authorization: Bearer STUB-OPENROUTER-KEY-42"$' "$TMP/last-curl-cfg"
check "key-passed-via-curl-config-not-argv" 0 $?

echo
echo "=== (b) Keychain missing -> fail-closed ==="
write_security_stub missing
out="$(run_worker mid 'x' 2>&1)"; rc=$?
check "missing-keychain-exits-4" 4 "$rc"

echo
echo "=== (c) HTTP 429 -> exit 75 (fail-open signal) ==="
write_security_stub ok
write_curl_stub 429
out="$(run_worker mid 'x' 2>"$TMP/err_c")"; rc=$?
check "rate-limited-exits-75" 75 "$rc"
grep -qi "rate-limited" "$TMP/err_c"; check "rate-limited-message-on-stderr" 0 $?

echo
echo "=== (d) HTTP error -> generic failure ==="
write_curl_stub error
out="$(run_worker mid 'x' 2>"$TMP/err_d")"; rc=$?
check "http-error-exits-1" 1 "$rc"
grep -qi "boom" "$TMP/err_d"; check "http-error-body-reported" 0 $?

echo
echo "=== (e) sensitive-cwd refusal + AGENT_OPENROUTER_FORCE override ==="
write_curl_stub ok "should-not-be-called-if-refused"
mkdir -p "$TMP/blocked-project/sub"
out="$( cd "$TMP/blocked-project/sub" && printf 'x' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$SENS" \
    bash "$WORKER" --tier mid 2>"$TMP/err_e" )"; rc=$?
check "sensitive-cwd-refuses-9" 9 "$rc"
grep -qi "sensitive path" "$TMP/err_e"; check "sensitive-cwd-message-on-stderr" 0 $?

out="$( cd "$TMP/blocked-project/sub" && printf 'x' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$SENS" \
    AGENT_OPENROUTER_FORCE=1 \
    bash "$WORKER" --tier mid 2>/dev/null )"; rc=$?
check "force-override-bypasses-guard" 0 "$rc"

echo
echo "=== (e2) guard matrix — trailing slash, symlinked entry, fail-closed, egress floor (security review 2026-08-25) ==="
# trailing-slash entry must still match (used to silently disable the line)
printf '%s/\n' "$TMP/blocked-project" > "$TMP/sens-slash"
out="$( cd "$TMP/blocked-project/sub" && printf 'x' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$TMP/sens-slash" \
    bash "$WORKER" --tier mid 2>/dev/null )"; rc=$?
check "trailing-slash-entry-still-refuses" 9 "$rc"

# blocklist entry that is a SYMLINK to the real dir must still match (cwd is pwd -P)
ln -s "$TMP/blocked-project" "$TMP/blocked-link"
printf '%s\n' "$TMP/blocked-link" > "$TMP/sens-link"
out="$( cd "$TMP/blocked-project/sub" && printf 'x' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$TMP/sens-link" \
    bash "$WORKER" --tier mid 2>/dev/null )"; rc=$?
check "symlinked-entry-still-refuses" 9 "$rc"

# no guard file resolvable anywhere -> fail closed
out="$( cd "$TMP" && printf 'x' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$TMP/definitely-absent" \
    bash "$WORKER" --tier mid 2>"$TMP/err_e2" )"; rc=$?
check "absent-guard-file-fails-closed-9" 9 "$rc"
grep -qi "no sensitive-paths guard" "$TMP/err_e2"; check "absent-guard-message" 0 $?

# /dev/null as the guard file is empty -> also fail closed, not a silent bypass
out="$( cd "$TMP" && printf 'x' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE=/dev/null \
    bash "$WORKER" --tier mid 2>/dev/null )"; rc=$?
check "dev-null-guard-fails-closed-9" 9 "$rc"

# egress floor: a planted AWS-key shape must refuse before curl. The fixture is
# the official AWS-docs example key: the worker's regex floor still matches it,
# while gitleaks' default rules already ignore it (same key as docs/getting-started.md).
write_curl_stub ok "should-not-be-called-on-secret"
out="$( cd "$TMP" && printf 'context AKIAIOSFODNN7EXAMPLE end' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$SENS" \
    bash "$WORKER" --tier mid 2>"$TMP/err_e3" )"; rc=$?
check "credential-pattern-refuses-9" 9 "$rc"
grep -qi "credential pattern" "$TMP/err_e3"; check "credential-pattern-message" 0 $?

# byte cap: oversized prompt refuses (cap lowered via env for the test)
out="$( cd "$TMP" && head -c 2048 /dev/zero | tr '\0' 'a' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$SENS" \
    OPENROUTER_PROMPT_MAX_BYTES=1024 \
    bash "$WORKER" --tier mid 2>/dev/null )"; rc=$?
check "prompt-byte-cap-refuses-9" 9 "$rc"

# UNSAFE override lets the same oversized prompt through
out="$( cd "$TMP" && head -c 2048 /dev/zero | tr '\0' 'a' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TIERS" OPENROUTER_SENSITIVE_PATHS_FILE="$SENS" \
    OPENROUTER_PROMPT_MAX_BYTES=1024 AGENT_OPENROUTER_UNSAFE_PROMPT=1 \
    bash "$WORKER" --tier mid 2>/dev/null )"; rc=$?
check "unsafe-override-bypasses-floor" 0 "$rc"

echo
echo "=== (f) usage/config refusals ==="
out="$(run_worker huge 'x' 2>/dev/null)"; rc=$?
check "bad-tier-exits-2" 2 "$rc"
echo '{ "tiers": { "MID": {} } }' > "$TMP/no-model.json"
out="$( cd "$TMP" && printf 'x' | env PATH="$STUB_DIR:/usr/bin:/bin" \
    OPENROUTER_TIERS_FILE="$TMP/no-model.json" OPENROUTER_SENSITIVE_PATHS_FILE="$SENS" \
    bash "$WORKER" --tier mid 2>/dev/null )"; rc=$?
check "tiers-without-model-exits-2" 2 "$rc"

echo
echo "=== (g) preflight: exact-token pass/fail ==="
write_security_stub ok
BINDIR="$TMP/prefbin"
mkdir -p "$BINDIR"
REGISTRY="$TMP/backends.json"
cat > "$REGISTRY" <<JSON
{ "backends": { "openrouter": { "cmd": ["openrouter-worker-stub"] } } }
JSON

cat > "$BINDIR/openrouter-worker-stub" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "OPENROUTER-PREFLIGHT-OK-7f1a3d"
STUB
chmod +x "$BINDIR/openrouter-worker-stub"
out="$(env PATH="$BINDIR:$STUB_DIR:/usr/bin:/bin" AGENT_BACKENDS_FILE="$REGISTRY" \
    bash "$PREFLIGHT" openrouter 2>&1)"; rc=$?
check "preflight-exact-token-passes" 0 "$rc"

cat > "$BINDIR/openrouter-worker-stub" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "not the token"
STUB
chmod +x "$BINDIR/openrouter-worker-stub"
out="$(env PATH="$BINDIR:$STUB_DIR:/usr/bin:/bin" AGENT_BACKENDS_FILE="$REGISTRY" \
    bash "$PREFLIGHT" openrouter 2>&1)"; rc=$?
check "preflight-wrong-token-fails-5" 5 "$rc"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
