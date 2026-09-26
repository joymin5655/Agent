#!/usr/bin/env bash
# runtime-currency-test.sh — battery for the runtime-currency gate.
#
# Hermetic: builds a scratch registry + scratch pin files under mktemp, pins
# "today" via AGENT_CURRENCY_TODAY, never reads the real registry except in the
# final self-check (the shipped registry must pass its own gate in non-strict
# mode — that is the liveness canary, and it is what CI runs).
#
# Usage: bash core/tests/runtime-currency-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/core/tests/runtime-currency.sh"
PASS=0; FAIL=0
check() { local name="$1" cond="$2"; if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS+1)); else echo "  FAIL [$name]"; FAIL=$((FAIL+1)); fi; }
# expect <name> <want-rc> <cmd...> — runs cmd, compares rc, keeps output in $OUT
OUT=""
expect() { local name="$1" want="$2"; shift 2; OUT="$("$@" 2>&1)"; local rc=$?; [[ "$rc" -eq "$want" ]]; check "$name" $?; }
grepq() { printf '%s\n' "$OUT" | grep -Eq -- "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/adapters/x"
export AGENT_CURRENCY_TODAY="2026-09-26"
export AGENT_CURRENCY_REPO_ROOT="$TMP"

# helper: write a registry with one first-party runtime pointing at adapters/x/*.toml
mkreg() {  # $1 measured_on, $2 checked_on, $3 retired patterns JSON array, $4 out
  cat > "$4" <<EOF
{"schema_version":1,"max_age_days_default":45,"runtimes":{"rt":{"kind":"first-party","vendor":"v",
 "cli_version_measured":"1.0","measured_on":"$1","docs":[{"url":"https://x","checked_on":"$2"}],
 "pin_files":["adapters/x/*.toml"],"retired_model_patterns":$3}}}
EOF
}
printf 'model = "live-model-9"\n# model = "dead-model-1" (comment, must be ignored)\n' > "$TMP/adapters/x/a.toml"

echo "=== (a) fresh registry, live pin -> pass, no warn ==="
mkreg 2026-09-20 2026-09-25 '["dead-model-[0-9]"]' "$TMP/r.json"
expect "fresh-live-pass" 0 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
grepq '0 warn, 0 failed'; check "fresh-live-no-warn" $?
grepq 'rt-no-retired-pins'; check "comment-line-ignored" $?

echo "=== (b) stale measured_on -> WARN (rc 0), --strict -> FAIL (rc 1) ==="
mkreg 2026-07-01 2026-09-25 '[]' "$TMP/r.json"
expect "stale-warn-rc0" 0 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
grepq 'WARN \[rt-measured_on-stale\] 87d old'; check "stale-warn-line" $?
expect "stale-strict-rc1" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE" --strict
grepq 'FAIL \[rt-measured_on-stale\]'; check "stale-strict-line" $?

echo "=== (c) stale docs[].checked_on -> WARN; window override via env ==="
mkreg 2026-09-20 2026-08-01 '[]' "$TMP/r.json"
expect "stale-doc-warn" 0 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
grepq 'WARN \[rt-docs\[0\]-stale\] 56d'; check "stale-doc-line" $?
expect "window-override-pass" 0 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" AGENT_CURRENCY_MAX_AGE_DAYS=90 bash "$GATE"
grepq '0 warn'; check "window-override-no-warn" $?

echo "=== (d) retired ID on a pin line -> FAIL even non-strict ==="
printf 'model = "dead-model-1"\n' > "$TMP/adapters/x/b.toml"
mkreg 2026-09-20 2026-09-25 '["dead-model-[0-9]"]' "$TMP/r.json"
expect "retired-pin-rc1" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
grepq 'FAIL \[rt-retired-pin\] adapters/x/b.toml:1'; check "retired-pin-line" $?
rm -f "$TMP/adapters/x/b.toml"

echo "=== (e) retired ID only in prose (no pin syntax) -> not a pin, passes ==="
printf 'description = "was dead-model-1 until 2026-07"\n' > "$TMP/adapters/x/c.toml"
expect "prose-mention-ok" 0 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
rm -f "$TMP/adapters/x/c.toml"

echo "=== (f) pin syntaxes: json \"model\":, yaml model:, argv --model ==="
printf '{"model": "dead-model-2"}\n' > "$TMP/adapters/x/d.toml"
expect "json-pin-caught" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"; rm -f "$TMP/adapters/x/d.toml"
printf 'model: dead-model-3\n' > "$TMP/adapters/x/e.toml"
expect "yaml-pin-caught" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"; rm -f "$TMP/adapters/x/e.toml"
printf 'exec claude --model dead-model-4 "$@"\n' > "$TMP/adapters/x/f.toml"
expect "argv-pin-caught" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"; rm -f "$TMP/adapters/x/f.toml"

echo "=== (g) schema: first-party without retired_model_patterns -> FAIL; gateway without -> ok ==="
cat > "$TMP/r.json" <<'EOF'
{"runtimes":{"fp":{"kind":"first-party","vendor":"v","cli_version_measured":"1","measured_on":"2026-09-20","pin_files":[]},
             "gw":{"kind":"gateway","vendor":"g","cli_version_measured":"1","measured_on":"2026-09-20","pin_files":[]}}}
EOF
expect "schema-rc1" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
grepq 'FAIL \[fp-schema\] missing retired_model_patterns'; check "schema-first-party-missing" $?
grepq 'ok +\[gw-schema\]'; check "schema-gateway-ok" $?
grepq 'ok +\[gw-retired-skip\]'; check "gateway-retired-skipped" $?

echo "=== (h) fail-closed: missing registry, malformed JSON, bad date, missing pin files ==="
expect "missing-registry-rc1" 1 env AGENT_CURRENCY_REGISTRY="$TMP/nope.json" bash "$GATE"
printf '{not json' > "$TMP/bad.json"
expect "malformed-rc1" 1 env AGENT_CURRENCY_REGISTRY="$TMP/bad.json" bash "$GATE"
grepq 'FAIL \[registry-parse\]'; check "malformed-line" $?
mkreg 2026-13-99 2026-09-25 '[]' "$TMP/r.json"
expect "bad-date-rc1" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
grepq 'unparseable date'; check "bad-date-line" $?
mkreg 2026-09-20 2026-09-25 '["x"]' "$TMP/r.json"
sed -i.bak 's|adapters/x/\*.toml|adapters/none/*.toml|' "$TMP/r.json"
expect "pin-files-missing-rc1" 1 env AGENT_CURRENCY_REGISTRY="$TMP/r.json" bash "$GATE"
grepq 'FAIL \[rt-pin-files-missing\]'; check "pin-files-missing-line" $?

echo "=== (i) liveness canary: the SHIPPED registry passes its own gate (non-strict) ==="
unset AGENT_CURRENCY_REPO_ROOT
expect "shipped-registry-passes" 0 bash "$GATE"
grepq '=== Results: [0-9]+ ok'; check "shipped-registry-summary" $?
# and it must actually scan the codex profile templates (regression: a glob typo
# would silently turn the retired-ID check into a no-op)
grepq 'ok +\[codex-no-retired-pins\] [1-9][0-9]* file\(s\) scanned'; check "shipped-scans-codex-pins" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
