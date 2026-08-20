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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
RECORD="$TMP/record"

# Stub agy: records argv (one line, %q-quoted) and cwd. The prompt arrives as
# the positional value of -p, so the argv line carries it.
cat > "$STUB_DIR/agy" <<STUB
#!/usr/bin/env bash
{
  printf 'argv:'; printf ' %q' "\$@"; printf '\n'
  printf 'cwd: %s\n' "\$PWD"
} >> "$RECORD"
STUB
chmod +x "$STUB_DIR/agy"

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
  if [[ "${args[$i]}" == "-p" && $stripped -eq 0 ]]; then stripped=1; i=$((i+2)); continue; fi
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
for tool in jq mktemp cat tr rm dirname env bash; do
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
