#!/usr/bin/env bash
# runtime-profile-test.sh — core/infra/runtime-profile.py detect / recommend / save.
#
# Positive: plans read from fake claude / codex state. Negative: planted email, org,
# tokens never reach stdout, stderr or the saved profile; every failure mode degrades
# to "unknown" with exit 0 and no traceback.
#
# Usage: bash core/tests/runtime-profile-test.sh
# shellcheck disable=SC2015,SC2016  # ok() never fails, so A && ok || bad is a safe if-else
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RP="$REPO_ROOT/core/infra/runtime-profile.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 — $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE_PATH="/usr/bin:/bin"
export AGENT_PROFILE_FILE="$WORK/out/profile.json"
export CODEX_HOME="$WORK/codex"
export HOME="$WORK/home"
mkdir -p "$HOME" "$CODEX_HOME"

b64url() { python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).decode().rstrip("="))'; }

# fake_claude <dir> <loggedIn> <subscriptionType>
fake_claude() {
    mkdir -p "$1"
    cat > "$1/claude" <<SH
#!/bin/sh
echo '{"loggedIn": $2, "authMethod":"x", "email":"leak@example.invalid", "orgId":"LEAKORGID", "orgName":"LEAKORG", "subscriptionType": "$3"}'
SH
    chmod +x "$1/claude"
}
# fake_codex <dir> <exit-code>
fake_codex() {
    mkdir -p "$1"
    printf '#!/bin/sh\nif [ %s -eq 0 ]; then echo "Logged in using ChatGPT"; else echo "Not logged in" >&2; fi\nexit %s\n' "$2" "$2" > "$1/codex"
    chmod +x "$1/codex"
}
# write_auth <claim-json> — auth.json with a JWT carrying the given auth-namespace payload
write_auth() {
    local payload
    payload="$(printf '%s' "$1" | b64url)"
    cat > "$CODEX_HOME/auth.json" <<JSON
{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"hdr.$payload.sig","access_token":"LEAKTOKEN-access","refresh_token":"LEAKTOKEN-refresh","account_id":"LEAKACCT"}}
JSON
}
run() { env PATH="$1:$BASE_PATH" python3 "$RP" "${@:2}" >"$WORK/out.txt" 2>"$WORK/err.txt"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$WORK/out.txt" "$1"; }

BIN="$WORK/bin"
fake_claude "$BIN" true max
fake_codex "$BIN" 0
write_auth '{"email":"leak@example.invalid","https://api.openai.com/auth":{"chatgpt_plan_type":"plus","chatgpt_account_id":"LEAKACCT"}}'

echo "=== positive ==="
run "$BIN" detect --json && rc=0 || rc=$?
[[ $rc -eq 0 ]] && [[ "$(jget 'd["claude"]["plan"]')" == max ]] && [[ "$(jget 'd["claude"]["authenticated"]')" == True ]] \
    && ok "claude plan max" || bad "claude plan max" "rc=$rc $(cat "$WORK/out.txt")"
[[ "$(jget 'd["codex"]["plan"]')" == plus ]] && ok "codex plan plus" || bad "codex plan plus" "$(cat "$WORK/out.txt")"
[[ "$(jget 'd["antigravity"]["installed"]')" == False ]] && ok "agy absent" || bad "agy absent" "$(cat "$WORK/out.txt")"
run "$BIN" recommend --json || true
[[ "$(jget 'd["main_vendor"]')" == anthropic && "$(jget 'd["reviewers"][0]')" == openai ]] \
    && ok "recommend main=anthropic reviewers[0]=openai" || bad "recommend" "$(cat "$WORK/out.txt")"
[[ "$(jget 'd["plans"]["openai"]')" == plus ]] && ok "plus is a normal reviewer plan" || bad "plans" "$(cat "$WORK/out.txt")"

echo "=== no leaks ==="
run "$BIN" detect || true
run "$BIN" save && rc=0 || rc=$?
LEAKS="$WORK/leaks.txt"
cat "$WORK/out.txt" "$WORK/err.txt" "$AGENT_PROFILE_FILE" > "$LEAKS"
{ run "$BIN" detect --json || true; }; cat "$WORK/out.txt" "$WORK/err.txt" >> "$LEAKS"
if grep -Eq 'leak@example|LEAK|hdr\.' "$LEAKS"; then bad "no-leak" "secret string found"; else ok "no email/token/org in output or profile"; fi

echo "=== save ==="
[[ $rc -eq 0 && -f "$AGENT_PROFILE_FILE" ]] && ok "save writes profile" || bad "save" "rc=$rc"
mode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$AGENT_PROFILE_FILE")"
[[ "$mode" == 0o600 ]] && ok "profile mode 0600" || bad "mode" "$mode"
run "$BIN" save --main openai || true
python3 - "$AGENT_PROFILE_FILE" <<'PY' && ok "--main openai excludes openai from reviewers" || bad "--main" "$(cat "$AGENT_PROFILE_FILE")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["main_vendor"] == "openai" and "openai" not in d["reviewers"] and "anthropic" in d["reviewers"], d
assert "detected_at" in d
PY
run "$BIN" save --main bogus && rc=0 || rc=$?
[[ $rc -ne 0 ]] && grep -q 'main' "$WORK/err.txt" && ok "invalid --main rejected with message" || bad "invalid --main" "rc=$rc"

echo "=== degraded / negative ==="
tb() { grep -q Traceback "$WORK/out.txt" "$WORK/err.txt" && echo tb || echo clean; }
EMPTY="$WORK/empty"; mkdir -p "$EMPTY"
rm -f "$CODEX_HOME/auth.json"
run "$EMPTY" detect --json && rc=0 || rc=$?
[[ $rc -eq 0 && "$(jget 'd["claude"]["installed"]')" == False && "$(jget 'd["claude"]["plan"]')" == unknown ]] \
    && ok "no CLIs on PATH -> unknown" || bad "no CLIs" "rc=$rc $(cat "$WORK/out.txt")"
run "$EMPTY" recommend --json || true
[[ "$(jget 'd["main_vendor"]')" == anthropic && "$(jget 'd["reviewers"]')" == "[]" ]] && ok "recommend fallback anthropic" || bad "fallback" "$(cat "$WORK/out.txt")"

OUT="$WORK/bin2"; fake_claude "$OUT" false max; fake_codex "$OUT" 1
run "$OUT" detect --json && rc=0 || rc=$?
[[ $rc -eq 0 && "$(jget 'd["claude"]["authenticated"]')" == False && "$(jget 'd["claude"]["plan"]')" == unknown \
   && "$(jget 'd["codex"]["authenticated"]')" == False ]] && ok "logged out -> false/unknown" || bad "logged out" "$(cat "$WORK/out.txt")"

fake_codex "$OUT" 0
echo '{not json' > "$CODEX_HOME/auth.json"
run "$OUT" detect --json && rc=0 || rc=$?
[[ $rc -eq 0 && "$(jget 'd["codex"]["plan"]')" == unknown && "$(tb)" == clean ]] && ok "corrupt auth.json" || bad "corrupt auth" "rc=$rc"

printf '{"tokens":{"id_token":"a.!!!notb64.c"}}' > "$CODEX_HOME/auth.json"
run "$OUT" detect --json && rc=0 || rc=$?
[[ $rc -eq 0 && "$(jget 'd["codex"]["plan"]')" == unknown && "$(tb)" == clean ]] && ok "bad base64 JWT" || bad "bad jwt" "rc=$rc"

write_auth '{"https://api.openai.com/auth":{"chatgpt_plan_type":"Pl us;$(x)"}}'
run "$OUT" detect --json && rc=0 || rc=$?
[[ $rc -eq 0 && "$(jget 'd["codex"]["plan"]')" == unknown ]] && ok "odd plan chars -> unknown" || bad "odd plan" "$(cat "$WORK/out.txt")"

fake_claude "$OUT" true 'Ma x!'
run "$OUT" detect --json || true
[[ "$(jget 'd["claude"]["plan"]')" == unknown ]] && ok "odd claude plan -> unknown" || bad "odd claude plan" "$(cat "$WORK/out.txt")"

echo "=== antigravity ==="
mkdir -p "$BIN" "$HOME/.gemini/antigravity-cli"
printf '#!/bin/sh\nexit 99\n' > "$BIN/agy"; chmod +x "$BIN/agy"
run "$BIN" detect --json || true
[[ "$(jget 'd["antigravity"]["authenticated"]')" == unknown && "$(jget 'd["antigravity"]["plan"]')" == unknown ]] \
    && ok "agy without token -> unknown" || bad "agy no token" "$(cat "$WORK/out.txt")"
: > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
run "$BIN" detect --json || true
[[ "$(jget 'd["antigravity"]["authenticated"]')" == True && "$(jget 'd["antigravity"]["plan"]')" == unknown ]] \
    && ok "agy token present -> authenticated, plan unknown" || bad "agy token" "$(cat "$WORK/out.txt")"

echo "=== council fixes: codex/claude exit semantics ==="
CX="$WORK/bin3"; mkdir -p "$CX"
rm -f "$CODEX_HOME/auth.json"
printf '#!/bin/sh\necho boom >&2\nexit 2\n' > "$CX/codex"; chmod +x "$CX/codex"
run "$CX" detect --json || true
[[ "$(jget 'd["codex"]["authenticated"]')" == unknown ]] && ok "codex exit 2 -> unknown" || bad "codex exit 2" "$(cat "$WORK/out.txt")"
printf '#!/bin/sh\necho "Not logged in" >&2\nexit 1\n' > "$CX/codex"
run "$CX" detect --json || true
[[ "$(jget 'd["codex"]["authenticated"]')" == False ]] && ok "codex 'Not logged in' exit 1 -> False" || bad "codex not logged in" "$(cat "$WORK/out.txt")"
printf '#!/bin/sh\necho {\\"loggedIn\\": false}\nexit 1\n' > "$CX/claude"; chmod +x "$CX/claude"
run "$CX" detect --json || true
[[ "$(jget 'd["claude"]["authenticated"]')" == False ]] && ok "claude loggedIn false with exit 1 -> False" || bad "claude exit 1" "$(cat "$WORK/out.txt")"
printf '#!/bin/sh\necho garbage\nexit 1\n' > "$CX/claude"
run "$CX" detect --json || true
[[ "$(jget 'd["claude"]["authenticated"]')" == unknown ]] && ok "claude garbage -> unknown" || bad "claude garbage" "$(cat "$WORK/out.txt")"

echo "=== council fixes: plan newline ==="
NL="$WORK/bin4"; fake_codex "$NL" 0
printf '#!/bin/sh\nprintf "{\\"loggedIn\\": true, \\"subscriptionType\\": \\"max\\\\n\\"}\\n"\n' > "$NL/claude"; chmod +x "$NL/claude"
write_auth '{"https://api.openai.com/auth":{"chatgpt_plan_type":"plus\n"}}'
run "$NL" detect --json || true
[[ "$(jget 'd["claude"]["plan"]')" == unknown && "$(jget 'd["codex"]["plan"]')" == unknown ]] \
    && ok "trailing newline plan -> unknown" || bad "newline plan" "$(cat "$WORK/out.txt")"
run "$NL" detect || true
[[ "$(wc -l < "$WORK/out.txt" | tr -d ' ')" == 3 ]] && ok "detect text is exactly 3 lines" || bad "3 lines" "$(cat "$WORK/out.txt")"

echo "=== council fixes: save refuses non-profile files ==="
VICTIM="$WORK/victim.json"
echo '{"tokens":{"access_token":"LEAKTOKEN-victim"}}' > "$VICTIM"
cp "$VICTIM" "$WORK/victim.orig"
ln -sf "$VICTIM" "$WORK/link.json"
for tgt in "$VICTIM" "$WORK/link.json"; do
    AGENT_PROFILE_FILE="$tgt" run "$BIN" save && rc=0 || rc=$?
    if [[ $rc -eq 1 ]] && cmp -s "$VICTIM" "$WORK/victim.orig" && ! cat "$WORK/out.txt" "$WORK/err.txt" | grep -q LEAK; then
        ok "save refuses non-profile target ($(basename "$tgt"))"
    else bad "save refuse" "rc=$rc"; fi
done
echo plain > "$WORK/afile"
AGENT_PROFILE_FILE="$WORK/afile/profile.json" run "$BIN" save && rc=0 || rc=$?
if [[ $rc -eq 1 ]] && ! grep -q Traceback "$WORK/err.txt" && [[ -s "$WORK/err.txt" ]]; then ok "save OSError -> one-line message, exit 1"
else bad "save OSError" "rc=$rc $(cat "$WORK/err.txt")"; fi

echo "=== council fixes: doctor row validation ==="
doc_row() {  # doc_row <profile-json> -> doctor output in $WORK/doc.txt
    printf '%s' "$1" > "$WORK/p.json"
    AGENT_PROFILE_FILE="$WORK/p.json" bash "$REPO_ROOT/setup.sh" --doctor </dev/null > "$WORK/doc.txt" 2>&1 || true
}
doc_row '{"main_vendor":"anthropic\n  [PASS] forged","reviewers":["openai"]}'
[[ "$(grep -c 'runtime profile' "$WORK/doc.txt")" == 1 ]] && ! grep -q 'forged' "$WORK/doc.txt" \
    && grep 'runtime profile' "$WORK/doc.txt" | grep -q WARN && ok "newline-forged profile -> single WARN row" || bad "forged newline" "$(grep -n 'runtime profile\|forged' "$WORK/doc.txt")"
doc_row '{"main_vendor":"anth\u001bropic","reviewers":[]}'
[[ "$(grep -c 'runtime profile' "$WORK/doc.txt")" == 1 ]] && ! LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f]' "$WORK/doc.txt" \
    && ok "ESC profile -> no control bytes" || bad "esc profile" "control bytes"
doc_row '{"main_vendor":"openai","reviewers":["anthropic","google"]}'
grep 'runtime profile' "$WORK/doc.txt" | grep -q 'PASS.*main=openai' && ok "valid profile -> PASS main=openai" || bad "valid profile" "$(grep 'runtime profile' "$WORK/doc.txt")"

echo "=== setup.sh non-interactive ==="
# Source only the profile function (running setup.sh would install into the real tree).
export FRAMEWORK_ROOT="$REPO_ROOT"
eval "$(awk '/^offer_runtime_profile\(\) \{/,/^\}/' "$REPO_ROOT/setup.sh")"
rm -f "$AGENT_PROFILE_FILE"
out="$(offer_runtime_profile </dev/null 2>&1)" && rc=0 || rc=$?
if [[ $rc -eq 0 ]] && ! grep -q 'Main vendor \[' <<<"$out" && [[ ! -e "$AGENT_PROFILE_FILE" ]]; then
    ok "non-tty: no prompt, no profile, returns 0"
else bad "non-tty" "rc=$rc out=$out"; fi
out="$(AGENT_SETUP_NO_PROFILE=1 offer_runtime_profile 2>&1)"
[[ -z "$out" ]] && ok "AGENT_SETUP_NO_PROFILE=1 is silent" || bad "no-profile opt-out" "$out"
out="$(AGENT_SETUP_NO_DOCTOR=1 offer_runtime_profile 2>&1)"
[[ -z "$out" ]] && ok "AGENT_SETUP_NO_DOCTOR=1 skips the profile step" || bad "no-doctor skip" "$out"
out="$(bash "$REPO_ROOT/setup.sh" --doctor </dev/null 2>&1)" || true
grep -q 'runtime profile' <<<"$out" && ok "--doctor shows runtime profile row" || bad "doctor row" "missing"

echo
echo "runtime-profile-test: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
