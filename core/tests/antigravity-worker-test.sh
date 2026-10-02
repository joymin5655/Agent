#!/usr/bin/env bash
# antigravity-worker-test.sh — contract battery for adapters/antigravity/antigravity-worker.sh.
#
# Every case drives a STUBBED `agy` CLI on PATH — zero paid calls. The battery
# asserts on the ARGV the worker composes and on the PROMPT the stub receives:
# the two bridges this worker exists for are stdin -> the POSITIONAL prompt of
# -p (measured: flags after -p are misparsed, so flags must precede it), and the
# tier -> single-model resolution owned by the adapter's tiers file (model IDs
# are forbidden in core/infra/backends.json).
#
# Usage: bash core/tests/antigravity-worker-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
WORKER="$REPO_ROOT/adapters/antigravity/antigravity-worker.sh"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}

# check_true <name> <cmd...>: pass when the command succeeds (no $? after [[ ]]).
check_true() { local n="$1"; shift; if "$@"; then check "$n" 0 0; else check "$n" 0 1; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
RECORD="$TMP/record"
ENVREC="$TMP/envrec"
SECREC="$TMP/secrec"
unset ANTIGRAVITY_AUTH GEMINI_API_KEY AGENT_ANTIGRAVITY_WORKER
FAKE_KEY="FAKE-GEMINI-KEY-FOR-TEST"

# Stub agy: records argv (one line, %q-quoted) and cwd. The prompt arrives as
# the positional value of -p, so the argv line carries it. AGY_STUB_MODE picks
# the --output-format json envelope / stderr / exit code the stub emits; the
# soft-deny notice is the text measured on agy 1.1.14 (probe1-default.txt).
cat > "$STUB_DIR/agy" <<STUB
#!/usr/bin/env bash
{
  printf 'argv:'; printf ' %q' "\$@"; printf '\n'
  printf 'cwd: %s\n' "\$PWD"
} >> "$RECORD"
# Env presence goes to its OWN file so a leaked key can never hide in the argv record.
{
  printf 'GEMINI_API_KEY=%s\n' "\${GEMINI_API_KEY-<unset>}"
  printf 'AGENT_ANTIGRAVITY_WORKER=%s\n' "\${AGENT_ANTIGRAVITY_WORKER-<unset>}"
  # The workspace deny plugin the worker must have written BEFORE agy starts.
  d=.agents/plugins/agent-worker-deny
  printf 'DENY_PLUGIN=%s\n' "\$([[ -f \$d/hooks.json && -f \$d/plugin.json && -x \$d/deny.sh ]] && echo present || echo absent)"
  printf 'DENY_PRE=%s\n' "\$(printf '{}' | \$d/deny.sh PreToolUse 2>&1 | tr -d '\n')"
  printf 'DENY_STOP=%s\n' "\$(printf '{}' | \$d/deny.sh Stop 2>&1 | tr -d '\n')"
  printf 'DENY_CMD=%s\n' "\$(jq -r '.["agent-worker-deny"].PreToolUse[0].hooks[0].command' \$d/hooks.json 2>&1)"
  printf 'DENY_MATCHER=%s\n' "\$(jq -r '.["agent-worker-deny"].PreToolUse[0].matcher' \$d/hooks.json 2>&1)"
  printf 'DENY_PWD=%s\n' "\$PWD"
} >> "$ENVREC"
case "\${AGY_STUB_MODE:-success}" in
  success)  printf '{"conversation_id":"c1","status":"SUCCESS","response":"ok"}\n' ;;
  softdeny) printf '{"conversation_id":"c1","status":"SUCCESS","response":"ok"}\n'
            printf 'Error: permission check failed for command "touch PWNED": user denied permission to run command:\ntouch PWNED\n' >&2 ;;
  # agy 1.2.12 (measured 2026-09-29): envelope carries denied_actions, response is
  # empty, stderr names the auto-denied permission.
  softdeny12) printf '{"conversation_id":"c1","status":"SUCCESS","response":"","denied_actions":[{"action":"write_file","display_name":"WriteToFile"}]}\n'
            printf 'jetski: no output produced — a tool required the "write_file" permission that headless mode cannot prompt for, so it was auto-denied.\n' >&2 ;;
  denied_actions_only) printf '{"conversation_id":"c1","status":"SUCCESS","response":"","denied_actions":[{"action":"write_file","display_name":"WriteToFile"}]}\n' ;;
  stderr_only12) printf '{"conversation_id":"c1","status":"SUCCESS","response":""}\n'
            printf 'jetski: no output produced — a tool required the "write_file" permission that headless mode cannot prompt for, so it was auto-denied.\n' >&2 ;;
  denied_empty) printf '{"conversation_id":"c1","status":"SUCCESS","response":"ok","denied_actions":[]}\n' ;;
  error)    printf '{"conversation_id":"c1","status":"ERROR","error":"boom"}\n' ;;
  fail3)    printf '{"conversation_id":"c1","status":"ERROR","error":"boom"}\n'; exit 3 ;;
  waiting)  printf '{"conversation_id":"c1","status":"WAITING","response":""}\n' ;;
  garbage)  printf 'not json at all\n' ;;
  fail1)    printf '{"conversation_id":"c1","status":"ERROR","error":"run failure"}\n'; exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/agy"

# Stub security: records argv; serves a FAKE key unless SEC_STUB_MODE=missing
# (the real CLI prints an error and exits 44 when the item is absent).
cat > "$STUB_DIR/security" <<SECSTUB
#!/usr/bin/env bash
{ printf 'argv:'; printf ' %q' "\$@"; printf '\n'; } >> "$SECREC"
if [[ "\${SEC_STUB_MODE:-ok}" == missing ]]; then
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
  exit 44
fi
printf '%s\n' "$FAKE_KEY"
SECSTUB
chmod +x "$STUB_DIR/security"

# Transparent sandbox-exec stub: makes `command -v sandbox-exec` succeed (so the
# worker takes its REAL sandboxed branch and we test that branch's argv), then
# strips ONLY THE FIRST `-p <profile>` (the sandbox profile) and runs the rest —
# so agy's own `-p <prompt>` survives and the stub records the real dispatch
# argv. (The real sandbox's write-deny is an OS concern, not an argv concern.)
cat > "$STUB_DIR/sandbox-exec" <<'SBSTUB'
#!/usr/bin/env bash
args=("$@")
i=0; out=(); stripped=0
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "-p" && $stripped -eq 0 ]]; then
    [[ -n "${PROFILE_REC:-}" ]] && printf '%s' "${args[$((i+1))]}" > "$PROFILE_REC"
    stripped=1; i=$((i+2)); continue
  fi
  out+=("${args[$i]}"); i=$((i+1))
done
exec "${out[@]}"
SBSTUB
chmod +x "$STUB_DIR/sandbox-exec"
export PATH="$STUB_DIR:$PATH"

TIERS="$TMP/tiers.json"
cat > "$TIERS" <<'JSON'
{ "model": "gemini-3.1-pro-low", "tiers": { "MID": [], "TOP": ["--model", "gemini-3.1-pro-high"] } }
JSON

echo "=== (a) stdin -> positional -p prompt, model pin, json envelope, flags-before-prompt ==="
: > "$RECORD"
printf 'PROBE-PROMPT-77' | ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
rc=$?
check "mid-dispatch-exits-0" 0 "$rc"
grep -q 'PROBE-PROMPT-77' "$RECORD";        check "prompt-reaches-cli-as-positional" 0 $?
grep -q -- '--model gemini-3.1-pro-low' "$RECORD"; check "mid-model-from-tiers-file" 0 $?
grep -q -- '--output-format json' "$RECORD"; check "json-envelope-requested" 0 $?
# flags must precede the prompt: the argv up to -p carries no prompt text, and
# --print-timeout (a flag) must appear before -p.
grep -qE 'argv:.*--print-timeout [^ ]+ -p ' "$RECORD"; check "flags-precede-positional-prompt" 0 $?
grep -q 'dangerously-skip-permissions' "$RECORD"; check "skip-permissions-never-present" 1 $?

echo
echo "=== (b) TOP tier resolves to ONE model (override, no double -m) ==="
: > "$RECORD"
printf 'x' | ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier top >/dev/null 2>&1
grep -q -- '--model gemini-3.1-pro-high' "$RECORD"; check "top-model-override-applied" 0 $?
mcount="$(grep -o -- '--model' "$RECORD" | wc -l | tr -d ' ')"
check "exactly-one-model-flag" 1 "$mcount"
# neutral cwd — the review runs in WORK_DIR, not the caller's repo dir.
caller_cwd="$PWD"
rec_cwd="$(grep '^cwd: ' "$RECORD" | head -1 | cut -d' ' -f2-)"
[[ -n "$rec_cwd" && "$rec_cwd" != "$caller_cwd" ]]; check "neutral-cwd-not-caller-cwd" 0 $?

echo
echo "=== (c) config refusals ==="
printf 'x' | ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier huge >/dev/null 2>&1
check "bad-tier-exits-2" 2 $?
echo '{ "tiers": {} }' > "$TMP/no-model.json"
printf 'x' | ANTIGRAVITY_TIERS_FILE="$TMP/no-model.json" bash "$WORKER" --tier mid >/dev/null 2>&1
check "tiers-without-model-exits-2" 2 $?
# A tampered tiers file smuggling a non-model flag through a tier's args.
echo '{ "model": "gemini-3.1-pro-low", "tiers": { "MID": ["--dangerously-skip-permissions"] } }' > "$TMP/evil.json"
printf 'x' | ANTIGRAVITY_TIERS_FILE="$TMP/evil.json" bash "$WORKER" --tier mid >/dev/null 2>&1
check "non-allowlisted-tier-token-exits-2" 2 $?
# A model id that isn't a real agy id (flag smuggled through the model slot).
echo '{ "model": "gemini-3.1-pro-low", "tiers": { "TOP": ["--model", "--dangerously-skip-permissions"] } }' > "$TMP/badmodel.json"
printf 'x' | ANTIGRAVITY_TIERS_FILE="$TMP/badmodel.json" bash "$WORKER" --tier top >/dev/null 2>&1
check "invalid-model-id-exits-2" 2 $?

echo
echo "=== (d) sandbox fail-closed when sandbox-exec absent ==="
# Build a curated PATH: everything the worker needs EXCEPT sandbox-exec (which
# lives in /usr/bin alongside mktemp, so it can't be excluded by dropping a
# whole dir). Symlink the exact tools the worker calls into a clean dir.
NOSB="$TMP/nosb"; mkdir -p "$NOSB"; cp "$STUB_DIR/agy" "$NOSB/agy"
# env + bash too: the agy stub's `#!/usr/bin/env bash` shebang resolves both
# through this curated PATH.
for tool in jq mktemp cat tr rm dirname env bash mkdir chmod; do
  src="$(command -v "$tool")" && ln -sf "$src" "$NOSB/$tool"
done
# sanity: this curated PATH must NOT resolve sandbox-exec
if PATH="$NOSB" command -v sandbox-exec >/dev/null 2>&1; then
  echo "  FAIL [test-setup] curated PATH still resolves sandbox-exec"; FAIL=$((FAIL+1))
fi
printf 'x' | PATH="$NOSB" ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "no-sandbox-refuses-7" 7 $?
# Opt-out lets it through (0) even without sandbox-exec.
printf 'x' | PATH="$NOSB" ANTIGRAVITY_TIERS_FILE="$TIERS" ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1 bash "$WORKER" --tier mid >/dev/null 2>&1
check "opt-out-allows-unsandboxed-0" 0 $?

echo
echo "=== (e) unsafe HOME refusal ==="
printf 'x' | HOME='/tmp/x") (allow file-write* (subpath "/' ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "unsafe-home-refuses-8" 8 $?

echo
echo "=== (f-migration) tiers-file path migration (~/.gemini/antigravity-cli -> ~/.agent) ==="
FAKE_HOME="$TMP/fakehome"

# (1) only the NEW path has a file -> used directly, no migration chatter.
rm -rf "$FAKE_HOME"; mkdir -p "$FAKE_HOME/.agent"
cat > "$FAKE_HOME/.agent/antigravity-tiers.json" <<'JSON'
{ "model": "gemini-3.8-flash-medium", "tiers": { "MID": [], "TOP": ["--model", "gemini-3.1-pro-high"] } }
JSON
: > "$RECORD"
err="$(printf 'x' | HOME="$FAKE_HOME" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
grep -q -- '--model gemini-3.8-flash-medium' "$RECORD"; check "new-path-only-used" 0 $?
printf '%s' "$err" | grep -qi 'migrat'; check "new-path-only-no-migration-chatter" 1 $?

# (2) only the OLD path has a file -> migrated to the new path + warning naming both.
rm -rf "$FAKE_HOME"; mkdir -p "$FAKE_HOME/.gemini/antigravity-cli"
cat > "$FAKE_HOME/.gemini/antigravity-cli/agent-tiers.json" <<'JSON'
{ "model": "gemini-3.1-pro-low", "tiers": { "MID": [], "TOP": ["--model", "gemini-3.1-pro-high"] } }
JSON
: > "$RECORD"
err="$(printf 'x' | HOME="$FAKE_HOME" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
grep -q -- '--model gemini-3.1-pro-low' "$RECORD"; check "old-path-only-model-used" 0 $?
[[ -f "$FAKE_HOME/.agent/antigravity-tiers.json" ]]; check "old-path-only-new-file-created" 0 $?
printf '%s' "$err" | grep -q "$FAKE_HOME/.gemini/antigravity-cli/agent-tiers.json"; check "migration-message-names-old-path" 0 $?
printf '%s' "$err" | grep -q "$FAKE_HOME/.agent/antigravity-tiers.json"; check "migration-message-names-new-path" 0 $?

# (3) BOTH paths have a file -> new wins, stale-old warning.
cat > "$FAKE_HOME/.agent/antigravity-tiers.json" <<'JSON'
{ "model": "gemini-3.8-flash-medium", "tiers": { "MID": [], "TOP": ["--model", "gemini-3.1-pro-high"] } }
JSON
: > "$RECORD"
err="$(printf 'x' | HOME="$FAKE_HOME" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
grep -q -- '--model gemini-3.8-flash-medium' "$RECORD"; check "both-paths-new-wins" 0 $?
printf '%s' "$err" | grep -qi 'stale'; check "both-paths-stale-warning" 0 $?

# ANTIGRAVITY_TIERS_FILE explicit override still bypasses migration entirely.
: > "$RECORD"
err="$(printf 'x' | HOME="$FAKE_HOME" ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
grep -q -- '--model gemini-3.1-pro-low' "$RECORD"; check "explicit-tiers-file-still-wins" 0 $?

echo
echo "=== (g) --effort tier token: valid pass-through + invalid refusal ==="
EFFORT_TIERS="$TMP/effort-tiers.json"
cat > "$EFFORT_TIERS" <<'JSON'
{ "model": "gemini-3.8-flash-medium", "tiers": { "MID": [], "TOP": ["--model", "gemini-3.1-pro-high", "--effort", "high"] } }
JSON
: > "$RECORD"
printf 'x' | ANTIGRAVITY_TIERS_FILE="$EFFORT_TIERS" bash "$WORKER" --tier top >/dev/null 2>&1
check "effort-token-dispatch-exits-0" 0 $?
grep -qE -- '--effort high .*-p ' "$RECORD"; check "effort-precedes-positional-prompt" 0 $?
cat > "$TMP/bad-effort.json" <<'JSON'
{ "model": "gemini-3.8-flash-medium", "tiers": { "MID": [], "TOP": ["--effort", "ultra-mega"] } }
JSON
printf 'x' | ANTIGRAVITY_TIERS_FILE="$TMP/bad-effort.json" bash "$WORKER" --tier top >/dev/null 2>&1
check "invalid-effort-level-exits-2" 2 $?

echo
echo "=== (h) status envelope + soft-deny: exit 0 from agy is not success by itself ==="
out="$(printf 'x' | AGY_STUB_MODE=success ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>/dev/null)"
check "success-status-exits-0" 0 $?
check "envelope-passed-through-on-stdout" "SUCCESS" "$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
err="$(printf 'x' | AGY_STUB_MODE=softdeny ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
check "soft-deny-exits-9" 9 $?
printf '%s' "$err" | grep -q 'user denied permission'; check "soft-deny-notice-forwarded-to-stderr" 0 $?
printf '%s' "$err" | grep -qi 'soft-den'; check "soft-deny-named-in-worker-message" 0 $?
# agy 1.2.12: denied_actions envelope (primary) and/or new stderr text (fallback).
err="$(printf 'x' | AGY_STUB_MODE=softdeny12 ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
check "soft-deny-1.2.12-envelope-and-stderr-exits-9" 9 $?
printf '%s' "$err" | grep -q 'auto-denied'; check "soft-deny-1.2.12-notice-forwarded" 0 $?
printf 'x' | AGY_STUB_MODE=denied_actions_only ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "denied-actions-envelope-only-exits-9" 9 $?
printf 'x' | AGY_STUB_MODE=stderr_only12 ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "soft-deny-1.2.12-stderr-only-exits-9" 9 $?
printf 'x' | AGY_STUB_MODE=denied_empty ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "empty-denied-actions-is-not-soft-deny" 0 $?
printf 'x' | AGY_STUB_MODE=fail3 ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "agy-exit-3-passed-through" 3 $?
printf 'x' | AGY_STUB_MODE=error ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "error-status-exits-10" 10 $?
printf 'x' | AGY_STUB_MODE=waiting ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "waiting-status-exits-10" 10 $?
printf 'x' | AGY_STUB_MODE=garbage ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "unparseable-envelope-exits-10" 10 $?
printf 'x' | AGY_STUB_MODE=fail1 ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "agy-nonzero-exit-passed-through" 1 $?

echo
echo "=== (i) worker-mode flag + opt-in API-key auth (Keychain, env-only) ==="
AH="$TMP/authhome"; rm -rf "$AH"; mkdir -p "$AH/.gemini/antigravity-cli"
echo '{"modelProvider":"gemini"}' > "$AH/.gemini/antigravity-cli/settings.json"

# keyring default: security never called, key not in agy env, worker flag set.
: > "$RECORD"; : > "$ENVREC"; rm -f "$SECREC"
printf 'x' | HOME="$AH" USER=testuser ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "keyring-default-exits-0" 0 $?
check_true "security-not-called-when-auth-unset" test ! -e "$SECREC"
grep -q '^GEMINI_API_KEY=<unset>$' "$ENVREC"; check "no-api-key-in-agy-env-when-auth-unset" 0 $?
grep -q '^AGENT_ANTIGRAVITY_WORKER=1$' "$ENVREC"; check "worker-flag-exported-for-agy" 0 $?
: > "$ENVREC"; rm -f "$SECREC"
printf 'x' | HOME="$AH" USER=testuser ANTIGRAVITY_AUTH=keyring ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check_true "security-not-called-for-other-auth-value" test ! -e "$SECREC"

# apikey: key read via Keychain, lands ONLY in agy's environment.
: > "$RECORD"; : > "$ENVREC"; rm -f "$SECREC"
out="$(printf 'x' | HOME="$AH" USER=testuser ANTIGRAVITY_AUTH=apikey ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>"$TMP/apikey.err")"
check "apikey-dispatch-exits-0" 0 $?
grep -q -- '^argv: find-generic-password -a testuser -s gemini-api-key -w$' "$SECREC"; check "keychain-read-argv-matches-openrouter-pattern" 0 $?
grep -q "^GEMINI_API_KEY=$FAKE_KEY\$" "$ENVREC"; check "key-reaches-agy-env" 0 $?
grep -q '^AGENT_ANTIGRAVITY_WORKER=1$' "$ENVREC"; check "worker-flag-exported-with-apikey" 0 $?
grep -q "$FAKE_KEY" "$RECORD"; check "key-never-in-agy-argv" 1 $?
printf '%s' "$out" | grep -q "$FAKE_KEY"; check "key-never-in-worker-stdout" 1 $?
grep -q "$FAKE_KEY" "$TMP/apikey.err"; check "key-never-in-worker-stderr" 1 $?
check_true "apikey-with-modelprovider-set-is-quiet" test ! -s "$TMP/apikey.err"

# missing Keychain item -> exit 2, message names the service, never a value.
: > "$RECORD"
err="$(printf 'x' | HOME="$AH" USER=testuser SEC_STUB_MODE=missing ANTIGRAVITY_AUTH=apikey ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
check "missing-keychain-item-exits-2" 2 $?
printf '%s' "$err" | grep -q 'gemini-api-key'; check "missing-item-message-names-service" 0 $?
printf '%s' "$err" | grep -q "$FAKE_KEY"; check "missing-item-message-has-no-key" 1 $?
check_true "missing-item-no-agy-dispatch" test ! -s "$RECORD"

# no `security` on PATH -> exit 2.
printf 'x' | HOME="$AH" USER=testuser PATH="$NOSB" ANTIGRAVITY_AUTH=apikey ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "security-cli-missing-exits-2" 2 $?

# settings.json without modelProvider gemini -> warn (env var alone has no effect), still runs.
NH="$TMP/nomodelprov"; rm -rf "$NH"; mkdir -p "$NH/.gemini/antigravity-cli"
echo '{}' > "$NH/.gemini/antigravity-cli/settings.json"
err="$(printf 'x' | HOME="$NH" USER=testuser ANTIGRAVITY_AUTH=apikey ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
check "missing-modelprovider-still-dispatches" 0 $?
printf '%s' "$err" | grep -q 'modelProvider'; check "missing-modelprovider-warns" 0 $?
printf '%s' "$err" | grep -q "$FAKE_KEY"; check "modelprovider-warning-has-no-key" 1 $?
# no settings file at all -> same warning.
err="$(printf 'x' | HOME="$TMP/emptyhome" USER=testuser ANTIGRAVITY_AUTH=apikey ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'modelProvider'; check "absent-settings-file-warns" 0 $?

echo
echo "=== (j) workspace deny plugin + apikey fail-closed ==="
# Written before agy starts, in agy's cwd; static hook denies every exec/write tool.
: > "$ENVREC"; : > "$RECORD"
printf 'x' | HOME="$AH" USER=testuser ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "deny-plugin-dispatch-exits-0" 0 $?
grep -q '^DENY_PLUGIN=present$' "$ENVREC"; check "deny-plugin-present-in-agy-cwd" 0 $?
grep -q '^DENY_PRE={"decision":"deny","reason":"review worker: tools are disabled"}$' "$ENVREC"; check "deny-plugin-pre-denies" 0 $?
grep -q '^DENY_STOP={"decision":"stop"}$' "$ENVREC"; check "deny-plugin-stop-stops" 0 $?
dpwd="$(grep '^DENY_PWD=' "$ENVREC" | head -1 | cut -d= -f2-)"
grep -qF "DENY_CMD=\"$dpwd/.agents/plugins/agent-worker-deny/deny.sh\" PreToolUse" "$ENVREC"; check "deny-plugin-hook-command-absolute" 0 $?
for t in run_command send_command_input write_to_file replace_file_content multi_replace_file_content; do
  grep -q "^DENY_MATCHER=.*\b$t\b" "$ENVREC"; check "deny-plugin-matcher-covers[$t]" 0 $?
done
# apikey: the key is exported only after the plugin exists (it is present when agy starts with the key).
: > "$ENVREC"
printf 'x' | HOME="$AH" USER=testuser ANTIGRAVITY_AUTH=apikey ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
grep -q "^GEMINI_API_KEY=$FAKE_KEY\$" "$ENVREC" && grep -q '^DENY_PLUGIN=present$' "$ENVREC"; check "apikey-with-deny-plugin-present" 0 $?
# Plugin cannot be written -> refuse (exit 2), agy never starts, and it never sees the key.
FAILBIN="$TMP/failbin"; mkdir -p "$FAILBIN"
cat > "$FAILBIN/mkdir" <<'MKSTUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == *".agents"* ]] && { echo "mkdir: forced failure" >&2; exit 1; }; done
exec /bin/mkdir "$@"
MKSTUB
chmod +x "$FAILBIN/mkdir"
for auth in apikey keyring; do
  : > "$ENVREC"; : > "$RECORD"
  err="$(printf 'x' | PATH="$FAILBIN:$PATH" HOME="$AH" USER=testuser ANTIGRAVITY_AUTH="$auth" ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>&1 >/dev/null)"
  check "deny-plugin-write-failure-exits-2[$auth]" 2 $?
  check_true "deny-plugin-write-failure-no-agy-dispatch[$auth]" test ! -s "$RECORD"
  check_true "deny-plugin-write-failure-no-key-in-env[$auth]" test ! -s "$ENVREC"
  printf '%s' "$err" | grep -q "$FAKE_KEY"; check "deny-plugin-write-failure-message-has-no-key[$auth]" 1 $?
done

echo
echo "=== (k) sandbox profile: hook / plugin config is not writable; other ~/.gemini state is ==="
PROFILE_REC="$TMP/profile.sb"; rm -f "$PROFILE_REC"
# physical path: the sandbox matches real paths, and /var is a symlink to /private/var on macOS
SBHOME="$(cd "$TMP" && pwd -P)/sbhome"; rm -rf "$SBHOME"
mkdir -p "$SBHOME/.gemini/config/plugins/agent-harness" "$SBHOME/.gemini/tmp" "$SBHOME/.gemini/antigravity-cli"
printf 'ORIGINAL\n' > "$SBHOME/.gemini/config/hooks.json"
printf 'ORIGINAL\n' > "$SBHOME/.gemini/config/plugins/agent-harness/hooks.json"
printf 'ORIGINAL\n' > "$SBHOME/.gemini/settings.json"
printf 'x' | PROFILE_REC="$PROFILE_REC" HOME="$SBHOME" ANTIGRAVITY_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "profile-captured-exits-0" 0 $?
if [[ ! -s "$PROFILE_REC" ]]; then
  echo "  FAIL [profile-captured] the sandbox-exec stub recorded no profile"; FAIL=$((FAIL+1))
elif ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then
  echo "  ok   [sandbox-enforcement-skipped] sandbox-exec cannot run in this environment"; PASS=$((PASS+1))
else
  # shellcheck disable=SC2016  # the $1 is expanded by the inner sh, not here
  sb_write() { /usr/bin/sandbox-exec -p "$(cat "$PROFILE_REC")" /bin/sh -c 'printf PLANTED > "$1"' sh "$1" 2>/dev/null; }
  sb_write "$SBHOME/.gemini/config/hooks.json";                          check "sandbox-blocks-write-config-hooks-json" 1 $?
  sb_write "$SBHOME/.gemini/config/plugins/agent-harness/hooks.json";    check "sandbox-blocks-write-plugin-hooks-json" 1 $?
  sb_write "$SBHOME/.gemini/config/plugins/new-plugin.json";             check "sandbox-blocks-new-file-under-plugins" 1 $?
  sb_write "$SBHOME/.gemini/settings.json";                              check "sandbox-blocks-write-gemini-settings-json" 1 $?
  check "config-hooks-json-unchanged" "ORIGINAL" "$(cat "$SBHOME/.gemini/config/hooks.json")"
  check "plugin-hooks-json-unchanged" "ORIGINAL" "$(cat "$SBHOME/.gemini/config/plugins/agent-harness/hooks.json")"
  sb_write "$SBHOME/.gemini/tmp/x";                                      check "sandbox-still-allows-agy-state-write" 0 $?
  sb_write "$SBHOME/.gemini/antigravity-cli/state";                      check "sandbox-still-allows-agy-cli-dir-write" 0 $?
  sb_write "$SBHOME/outside.txt";                                        check "sandbox-blocks-write-outside-allowlist" 1 $?
fi

echo
echo "=== (f) no stray grok-worker reference in the antigravity adapter ==="
# antigravity-preflight.sh's missing-on-PATH hint once wrongly pointed at
# ~/bin/grok-worker (copy-paste from the grok adapter) — regression guard.
if grep -rq "grok-worker" "$REPO_ROOT/adapters/antigravity/" 2>/dev/null; then
  echo "  FAIL [no-grok-worker-reference] found in: $(grep -rl "grok-worker" "$REPO_ROOT/adapters/antigravity/" 2>/dev/null | tr '\n' ' ')"
  FAIL=$((FAIL + 1))
else
  echo "  ok   [no-grok-worker-reference]"
  PASS=$((PASS + 1))
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
