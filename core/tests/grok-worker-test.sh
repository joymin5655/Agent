#!/usr/bin/env bash
# grok-worker-test.sh — contract battery for adapters/grok/grok-worker.sh.
#
# Every case drives a STUBBED `grok` CLI on PATH — zero paid calls. The battery
# asserts on the ARGV the worker composes and on the PROMPT the stub receives,
# because those are the two bridges this worker exists for: stdin -> a
# --prompt-file argument (the grok CLI has no stdin prompt mode), and the tier
# -> model/effort mapping owned by the adapter's tiers file (model IDs are
# forbidden in core/infra/backends.json).
#
# Usage: bash core/tests/grok-worker-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
WORKER="$REPO_ROOT/adapters/grok/grok-worker.sh"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
RECORD="$TMP/record"

# Stub grok: records argv, the resolved prompt-file CONTENT, and its cwd.
cat > "$STUB_DIR/grok" <<STUB
#!/usr/bin/env bash
{
  printf 'argv:'; printf ' %q' "\$@"; printf '\n'
  printf 'cwd: %s\n' "\$PWD"
  prev=""
  for a in "\$@"; do
    if [[ "\$prev" == "--prompt-file" ]]; then printf 'prompt: '; cat "\$a"; printf '\n'; fi
    prev="\$a"
  done
} >> "$RECORD"
STUB
chmod +x "$STUB_DIR/grok"

# Transparent sandbox-exec stub for the argv-contract cases (a)-(d): it makes
# `command -v sandbox-exec` succeed (so the worker takes its REAL sandboxed
# branch and we test that branch's argv composition), but it just strips
# `-p <profile>` and runs the command — so the grok stub can still write RECORD
# (the real sandbox would deny a write outside WORK_DIR, which is the whole
# point of case (e), tested separately below with the REAL sandbox-exec).
cat > "$STUB_DIR/sandbox-exec" <<'SBSTUB'
#!/usr/bin/env bash
args=("$@")
i=0; out=()
while [[ $i -lt ${#args[@]} ]]; do
  if [[ "${args[$i]}" == "-p" ]]; then i=$((i+2)); continue; fi
  out+=("${args[$i]}"); i=$((i+1))
done
exec "${out[@]}"
SBSTUB
chmod +x "$STUB_DIR/sandbox-exec"
export PATH="$STUB_DIR:$PATH"

TIERS="$TMP/tiers.json"
cat > "$TIERS" <<'JSON'
{ "model": "stub-model-x", "tiers": { "MID": [], "TOP": ["--reasoning-effort", "high"] } }
JSON

echo "=== (a) stdin -> --prompt-file bridge, model pin, web-search default-off ==="
: > "$RECORD"
printf 'PROBE-PROMPT-77' | GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
rc=$?
check "mid-dispatch-exits-0" 0 "$rc"
grep -q 'prompt: PROBE-PROMPT-77' "$RECORD"; check "prompt-reaches-cli-via-file" 0 $?
grep -q -- '-m stub-model-x' "$RECORD";      check "model-pin-from-tiers-file" 0 $?
grep -q -- '--disable-web-search' "$RECORD"; check "web-search-off-by-default" 0 $?
grep -q -- '--no-subagents' "$RECORD";       check "subagents-disabled" 0 $?
# Mutation note: replacing --prompt-file with a bare -p "" (stdin silently
# dropped) fails prompt-reaches-cli-via-file.

echo
echo "=== (b) tier args + neutral cwd ==="
: > "$RECORD"
printf 'x' | GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier top >/dev/null 2>&1
grep -q -- '--reasoning-effort high' "$RECORD"; check "top-tier-args-applied" 0 $?
caller_cwd="$PWD"
rec_cwd="$(grep '^cwd: ' "$RECORD" | head -1 | cut -d' ' -f2-)"
[[ -n "$rec_cwd" && "$rec_cwd" != "$caller_cwd" ]]; check "neutral-cwd-not-caller-cwd" 0 $?
# Mutation note: dropping the `cd "$WORK_DIR"` (repo lands on the CLI's path)
# fails neutral-cwd-not-caller-cwd.

echo
echo "=== (c) web-search opt-in ==="
: > "$RECORD"
printf 'x' | GROK_TIERS_FILE="$TIERS" GROK_WORKER_WEB_SEARCH=1 bash "$WORKER" --tier mid >/dev/null 2>&1
grep -q -- '--disable-web-search' "$RECORD"; check "opt-in-removes-disable-flag" 1 $?

echo
echo "=== (d) config refusals ==="
printf 'x' | GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier huge >/dev/null 2>&1
check "bad-tier-exits-2" 2 $?
echo '{ "tiers": {} }' > "$TMP/no-model.json"
printf 'x' | GROK_TIERS_FILE="$TMP/no-model.json" bash "$WORKER" --tier mid >/dev/null 2>&1
check "tiers-without-model-exits-2" 2 $?

echo
echo "=== (e) sandbox write-block regression (macOS only) ==="
# The read-only guarantee is OS-enforced, so it must be REGRESSION-TESTED at
# the OS layer: a stub CLI that tries to write OUTSIDE the sandbox allowlist
# (the caller's HOME, standing in for the repo under review) must be blocked,
# while the worker still exits 0 on the reply path. A future edit that drops
# the sandbox wrapper or widens the profile fails write-blocked-outside-allowlist.
# Remove the transparent stub so the REAL sandbox-exec is exercised.
rm -f "$STUB_DIR/sandbox-exec"
if command -v sandbox-exec >/dev/null 2>&1; then
  PWNED="$HOME/.cache/grok-worker-test-pwned.$$"
  rm -f "$PWNED"
  cat > "$STUB_DIR/grok" <<STUB
#!/usr/bin/env bash
echo x > "$PWNED" 2>/dev/null
echo reply
STUB
  chmod +x "$STUB_DIR/grok"
  printf 'x' | GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
  [[ ! -e "$PWNED" ]]; check "write-blocked-outside-allowlist" 0 $?
  rm -f "$PWNED"

  # credential-read denial: a stub that reads ~/.ssh must come back empty.
  SSHDIR="$HOME/.ssh"; SECRET="$SSHDIR/grok-test-secret.$$"
  mkdir -p "$SSHDIR"; echo "TOP-SECRET-KEY" > "$SECRET"
  cat > "$STUB_DIR/grok" <<STUB
#!/usr/bin/env bash
cat "$SECRET" 2>/dev/null || echo READ-DENIED
STUB
  chmod +x "$STUB_DIR/grok"
  got="$(printf 'x' | GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>/dev/null)"
  [[ "$got" != *TOP-SECRET-KEY* ]]; check "credential-read-denied" 0 $?
  rm -f "$SECRET"

  # tiers-file write denial: a stub that writes the tiers file must be blocked
  # (argv-persistence hole). Point the tiers file inside ~/.grok so it is on
  # the write-deny literal path the worker installs.
  GROKDIR="$HOME/.grok"; mkdir -p "$GROKDIR"
  TF="$GROKDIR/agent-tiers.json"; TF_BAK=""
  [[ -f "$TF" ]] && { TF_BAK="$TF.bak.$$"; cp "$TF" "$TF_BAK"; }
  echo '{"model":"stub-model-x","tiers":{"MID":[]}}' > "$TF"
  cat > "$STUB_DIR/grok" <<STUB
#!/usr/bin/env bash
echo '{"model":"pwned","tiers":{"MID":[]}}' > "$TF" 2>/dev/null && echo WROTE || echo BLOCKED
STUB
  chmod +x "$STUB_DIR/grok"
  printf 'x' | bash "$WORKER" --tier mid >/dev/null 2>&1
  grep -q pwned "$TF"; check "tiers-file-write-denied" 1 $?
  [[ -n "$TF_BAK" ]] && mv "$TF_BAK" "$TF" || rm -f "$TF"
else
  echo "  skip [write-blocked-outside-allowlist] sandbox-exec not present (non-macOS)"
fi

echo
echo "=== (f) unsafe HOME refusal ==="
printf 'x' | HOME='/tmp/x") (allow file-write* (subpath "/' GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "unsafe-home-refuses-8" 8 $?

echo
echo "=== (g) vendor usage-limit classification -> exit 75 (fail-open signal) ==="
# The xAI free tier ends a run with a "usage limit" message and a generic
# exit 1 (measured 2026-08-18). The worker must reclassify that to 75
# (EX_TEMPFAIL) so call-worker marks the lane rate-limited — and must NOT
# touch any other nonzero exit.
LIMIT_STUB="$TMP/limitbin"
mkdir -p "$LIMIT_STUB"
cat > "$LIMIT_STUB/grok" <<'LSTUB'
#!/usr/bin/env bash
echo "You've reached your free Grok Build usage limit for now. Try again later."
exit 1
LSTUB
chmod +x "$LIMIT_STUB/grok"
printf 'x' | PATH="$LIMIT_STUB:$PATH" GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "usage-limit-exits-75" 75 $?
cat > "$LIMIT_STUB/grok" <<'LSTUB'
#!/usr/bin/env bash
echo "some unrelated backend error"
exit 1
LSTUB
printf 'x' | PATH="$LIMIT_STUB:$PATH" GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid >/dev/null 2>&1
check "plain-failure-stays-1" 1 $?
# Output must still reach stdout after the capture-and-classify change.
out="$(printf 'x' | PATH="$LIMIT_STUB:$PATH" GROK_TIERS_FILE="$TIERS" bash "$WORKER" --tier mid 2>/dev/null)"
[[ "$out" == *"unrelated backend error"* ]]; check "cli-output-still-streams" 0 $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
