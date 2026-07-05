#!/usr/bin/env bash
# hook-config-test.sh — verify secret-content-scan.py + hook_config.py integration.
#
# Feeds canonical PreToolUse event JSON to secret-content-scan.py via stdin and
# asserts the decision. Covers: built-in pattern still fires, project config
# adds a pattern, project config adds an exempt path, malformed config is
# fail-safe, and MCP-shaped input is actually scanned.
#
# Usage: bash core/tests/hook-config-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
#
# NOTE: no 40+ char token literal is ever stored in this source (would trip
# gitleaks). Test tokens are built at runtime via string repetition.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/secret-content-scan.py"
CONFIG_DIR="$REPO_ROOT/.agent"
CONFIG_JSON="$CONFIG_DIR/hook-config.json"
CONFIG_YML="$CONFIG_DIR/hook-config.yml"

PASS=0
FAIL=0

# Runtime-built tokens (never a literal in source).
SK_TOKEN="sk-$(printf 'A%.0s' $(seq 1 45))"          # sk- + 45 'A' → built-in API key pattern
MYCO_TOKEN="myco_secret_$(printf 'B%.0s' $(seq 1 24))"  # matches the custom config regex

# Track whether the repo already had an .agent/hook-config.{json,yml} so we
# never clobber a real one. We only create/remove our own temp files.
PREEXISTING_CONFIG=0
[[ -f "$CONFIG_JSON" ]] && PREEXISTING_CONFIG=1
PREEXISTING_YML=0
[[ -f "$CONFIG_YML" ]] && PREEXISTING_YML=1
HAD_AGENT_DIR=0
[[ -d "$CONFIG_DIR" ]] && HAD_AGENT_DIR=1

cleanup() {
  if [[ "$PREEXISTING_CONFIG" -eq 0 && -f "$CONFIG_JSON" ]]; then
    rm -f "$CONFIG_JSON"
  fi
  if [[ "$PREEXISTING_YML" -eq 0 && -f "$CONFIG_YML" ]]; then
    rm -f "$CONFIG_YML"
  fi
  if [[ "$HAD_AGENT_DIR" -eq 0 && -d "$CONFIG_DIR" ]]; then
    rmdir "$CONFIG_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$PREEXISTING_CONFIG" -eq 1 ]]; then
  echo "FAIL — a real $CONFIG_JSON exists; refusing to overwrite. Aborting test."
  exit 1
fi
if [[ "$PREEXISTING_YML" -eq 1 ]]; then
  echo "FAIL — a real $CONFIG_YML exists; refusing to overwrite. Aborting test."
  exit 1
fi
mkdir -p "$CONFIG_DIR"

# run_case <name> <event-json> <expect: deny|allow>
run_case() {
  local name="$1" event="$2" expect="$3"
  local out
  out=$(printf '%s' "$event" | AGENT_PROJECT_DIR="$REPO_ROOT" python3 "$HOOK" 2>/dev/null || true)
  local got="allow"
  [[ "$out" == *'"permissionDecision": "deny"'* || "$out" == *'"permissionDecision":"deny"'* ]] && got="deny"
  if [[ "$got" == "$expect" ]]; then
    echo "  ok   [$name] expected=$expect"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] expected=$expect got=$got :: $out"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== (a) built-in pattern still fires (no config) ==="
run_case "builtin-sk-deny" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"app/config.ts\",\"content\":\"const k = '${SK_TOKEN}'\"}}" \
  deny

echo "=== (b) project config adds a custom secret_pattern → deny ==="
cat > "$CONFIG_JSON" <<EOF
{
  "python_hooks": {
    "secret_patterns": [
      ["myco_secret_[A-Za-z0-9]{20,}", "MyCo internal token"]
    ]
  }
}
EOF
run_case "config-custom-pattern-deny" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"app/svc.ts\",\"content\":\"token = '${MYCO_TOKEN}'\"}}" \
  deny
# Built-in must still fire while config is loaded (additive, not replacing).
run_case "config-builtin-still-deny" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"app/svc.ts\",\"content\":\"k = '${SK_TOKEN}'\"}}" \
  deny

echo "=== (c) project config adds an exempt_path → built-in skipped (allow) ==="
cat > "$CONFIG_JSON" <<EOF
{
  "python_hooks": {
    "exempt_paths": ["vendor/whitelisted/"]
  }
}
EOF
run_case "config-exempt-allow" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"vendor/whitelisted/sample.ts\",\"content\":\"k = '${SK_TOKEN}'\"}}" \
  allow

echo "=== (d) malformed config → fail-safe (built-in still fires) ==="
printf '%s' '{ this is : not valid json, ]' > "$CONFIG_JSON"
run_case "malformed-config-failsafe" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"app/config.ts\",\"content\":\"k = '${SK_TOKEN}'\"}}" \
  deny
rm -f "$CONFIG_JSON"

echo "=== (e) MCP-shaped event (firecrawl scrape) with nested sk- URL → deny ==="
run_case "mcp-firecrawl-deny" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"mcp__firecrawl__firecrawl_scrape\",\"tool_input\":{\"url\":\"https://api.example.com/v1?key=${SK_TOKEN}\"}}" \
  deny

echo "=== (f) exempt-everything config CANNOT exempt the universe (still deny) ==="
# Hostile config: exempt_paths ["/"] would, under substring match, exempt every
# path. The loader must drop the over-broad fragment so the built-in still fires.
cat > "$CONFIG_JSON" <<EOF
{
  "python_hooks": {
    "exempt_paths": ["/"]
  }
}
EOF
run_case "exempt-everything-blocked" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"app/config.ts\",\"content\":\"k = '${SK_TOKEN}'\"}}" \
  deny
rm -f "$CONFIG_JSON"

echo "=== (g) ReDoS config regex is time-bounded (completes) + built-in still denies ==="
# Hostile config: a catastrophic-backtracking regex. It must NOT hang the hook —
# loader screens drop it, and the runtime SIGALRM watchdog bounds anything that
# slips through. Verify the hook COMPLETES (timeout exit != 124).
cat > "$CONFIG_JSON" <<EOF
{
  "python_hooks": {
    "secret_patterns": [
      ["(a+)+\$", "x"]
    ]
  }
}
EOF
# Pathological input: ~40 'a' chars + a non-matching 'X' (built at runtime).
REDOS_INPUT="$(printf 'a%.0s' $(seq 1 40))X"
REDOS_EVENT="{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"app/note.txt\",\"content\":\"${REDOS_INPUT}\"}}"
printf '%s' "$REDOS_EVENT" | timeout 8 env AGENT_PROJECT_DIR="$REPO_ROOT" python3 "$HOOK" >/dev/null 2>&1
REDOS_RC=$?
if [[ "$REDOS_RC" -ne 124 ]]; then
  echo "  ok   [redos-time-bounded] hook completed (rc=$REDOS_RC, not 124)"
  PASS=$((PASS + 1))
else
  echo "  FAIL [redos-time-bounded] hook hung — timeout fired (rc=124)"
  FAIL=$((FAIL + 1))
fi
# Built-in sk- must STILL deny while the offending config is loaded.
run_case "redos-config-builtin-still-deny" \
  "{\"event\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"app/config.ts\",\"content\":\"k = '${SK_TOKEN}'\"}}" \
  deny
rm -f "$CONFIG_JSON"

echo "=== (h) template's live-schema example is loader-consumable (drift guard) ==="
# templates/hook-config.yml.template ships a commented python_hooks: example
# bracketed by LIVE-SCHEMA-EXAMPLE-BEGIN/END markers. Extract it, uncomment
# it into a real .agent/hook-config.yml, and load it through
# hook_config.load_extensions() directly (bypassing the hook subprocess,
# since PyYAML is an optional dependency). If the template's example ever
# drifts out of sync with what hook_config.py actually parses, this fails.
TEMPLATE="$REPO_ROOT/templates/hook-config.yml.template"
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "  skip [live-schema-example] PyYAML not importable — .yml loading is optional, not exercised here"
else
  sed -n '/LIVE-SCHEMA-EXAMPLE-BEGIN/,/LIVE-SCHEMA-EXAMPLE-END/p' "$TEMPLATE" \
    | sed -e '/LIVE-SCHEMA-EXAMPLE-BEGIN/d' -e '/LIVE-SCHEMA-EXAMPLE-END/d' -e 's/^# \{0,1\}//' \
    > "$CONFIG_YML"

  LOAD_OUT=$(python3 - "$REPO_ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/core/hooks")
import hook_config
print(hook_config.load_extensions(sys.argv[1]))
PY
  )

  if [[ "$LOAD_OUT" == *"myservice_(live|test)_[a-zA-Z0-9_-]{32,}"* \
     && "$LOAD_OUT" == *"MyService API token"* \
     && "$LOAD_OUT" == *"vendor/fixtures/"* \
     && "$LOAD_OUT" == *"MYSERVICE_TOKEN"* ]]; then
    echo "  ok   [live-schema-example] template example round-trips through hook_config.load_extensions()"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [live-schema-example] template example did not load as expected :: $LOAD_OUT"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$CONFIG_YML"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
