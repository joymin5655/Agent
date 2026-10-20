#!/usr/bin/env bash
# harness-root-test.sh — fixture battery for extras/scripts/harness-root.sh.
# Resolution order: $AGENT_HARNESS_ROOT, <extras root>/.., sibling plugin-cache entry
# (same version first, else highest). The cwd is never a candidate. Unresolvable -> rc 1 + hint.
# Usage: bash core/tests/harness-root-test.sh
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/extras/scripts/harness-root.sh"
PASS=0; FAIL=0
check() { if [[ "$2" -eq 0 ]]; then echo "  ok   [$1]"; PASS=$((PASS+1)); else echo "  FAIL [$1]"; FAIL=$((FAIL+1)); fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mk_core() {  # <dir>: a directory carrying the full core marker set
  mkdir -p "$1/core/infra" "$1/.claude-plugin"
  : > "$1/core/infra/backends.json"; : > "$1/core/infra/manager-audit.sh"
  : > "$1/core/infra/telemetry-digest.sh"; : > "$1/.claude-plugin/plugin.json"
}
# resolve <cwd> <plugin_root> [VAR=val...] -> OUT, RC
resolve() { local cwd="$1" root="$2"; shift 2; OUT="$(cd "$cwd" && env -u AGENT_HARNESS_ROOT "$@" CLAUDE_PLUGIN_ROOT="$root" bash "$SCRIPT" 2>/dev/null)"; RC=$?; }

echo "=== (a) cache layout: same-version sibling wins ==="
C="$TMP/cache/agent"; mkdir -p "$C/agent-harness-extras/0.2.0"
mk_core "$C/agent-harness/0.1.0"; mk_core "$C/agent-harness/0.2.0"; mk_core "$C/agent-harness/0.10.0"
resolve "$TMP" "$C/agent-harness-extras/0.2.0"
[[ $RC -eq 0 && "$OUT" == "$C/agent-harness/0.2.0" ]]; check "same-version-hit" $?

echo "=== (b) no same-version sibling -> highest version (sort -V) ==="
mkdir -p "$C/agent-harness-extras/0.9.0"
resolve "$TMP" "$C/agent-harness-extras/0.9.0"
[[ $RC -eq 0 && "$OUT" == "$C/agent-harness/0.10.0" ]]; check "highest-version-fallback" $?

echo "=== (c) incomplete sibling (missing marker) is rejected ==="
C2="$TMP/cache2/agent"; mkdir -p "$C2/agent-harness-extras/1.0.0" "$C2/agent-harness/1.0.0/core/infra"
: > "$C2/agent-harness/1.0.0/core/infra/backends.json"
resolve "$TMP" "$C2/agent-harness-extras/1.0.0"
[[ $RC -eq 1 && -z "$OUT" ]]; check "partial-core-not-accepted" $?

echo "=== (d) unresolvable -> rc 1, hint on stderr ==="
ERR="$(cd "$TMP" && env -u AGENT_HARNESS_ROOT CLAUDE_PLUGIN_ROOT="$TMP/nowhere/x/y" bash "$SCRIPT" 2>&1 >/dev/null)"
[[ "$ERR" == *"core not found"* ]]; check "hint-on-failure" $?

echo "=== (e) the cwd is never a candidate ==="
CHK="$TMP/checkout"; mk_core "$CHK"
resolve "$CHK" "$TMP/nowhere/x/y"
[[ $RC -eq 1 ]]; check "cwd-checkout-not-an-execution-root" $?

echo "=== (f) AGENT_HARNESS_ROOT override wins over the cache; an invalid override falls through ==="
resolve "$TMP" "$C/agent-harness-extras/0.2.0" AGENT_HARNESS_ROOT="$CHK"
[[ $RC -eq 0 && "$OUT" == "$CHK" ]]; check "override-wins" $?
resolve "$TMP" "$C/agent-harness-extras/0.2.0" AGENT_HARNESS_ROOT="$TMP/empty"
[[ $RC -eq 0 && "$OUT" == "$C/agent-harness/0.2.0" ]]; check "invalid-override-falls-through" $?

echo "=== (g) extras/ inside a checkout resolves to the checkout ==="
mkdir -p "$CHK/extras"
resolve "$TMP" "$CHK/extras"
[[ $RC -eq 0 && "$OUT" == "$CHK" ]]; check "parent-of-extras" $?

echo "=== (h) real repo: its own extras resolves to the repo ==="
resolve "$TMP" "$REPO_ROOT/extras"
[[ $RC -eq 0 && "$OUT" == "$REPO_ROOT" ]]; check "repo-extras-resolves" $?

echo; echo "harness-root-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
