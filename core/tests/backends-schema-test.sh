#!/usr/bin/env bash
# backends-schema-test.sh — validate the SHIPPED core/infra/backends.json.
#
# The registry ships to every plugin consumer (plugin = the whole git tree),
# so this battery guards the invariants that keep it safe and coherent:
#   - version 2, parseable JSON
#   - referential integrity: every role's backend (and non-null fallback)
#     exists; a role's tier is a key of that backend's tier_args
#   - enabled backends carry a non-empty cmd and a preflight probe
#   - disabled backends carry a disabled_reason (loud-unavailable contract)
#   - NO model IDs anywhere (tier policy lives in vendor profiles, never here)
#   - NO credential-shaped keys or values (api keys, tokens, secrets)
#
# Usage: bash core/tests/backends-schema-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY="$REPO_ROOT/core/infra/backends.json"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

echo "=== shape ==="
jq -e . "$REGISTRY" >/dev/null 2>&1;            check "parseable-json" $?
[[ "$(jq -r '.version' "$REGISTRY")" == "2" ]]; check "version-2" $?
jq -e '.roles | length > 0' "$REGISTRY" >/dev/null 2>&1;    check "has-roles" $?
jq -e '.backends | length > 0' "$REGISTRY" >/dev/null 2>&1; check "has-backends" $?

echo
echo "=== referential integrity ==="
jq -e '.backends as $b | .roles | to_entries | all(.value.backend | in($b))' \
  "$REGISTRY" >/dev/null 2>&1
check "role-backends-exist" $?
jq -e '.backends as $b | .roles | to_entries
       | all(.value.fallback == null or (.value.fallback | in($b)))' \
  "$REGISTRY" >/dev/null 2>&1
check "role-fallbacks-exist-or-null" $?
# Every role with a tier names a key of its backend's tier_args.
ok_tier=0
while IFS=$'\t' read -r role tier backend; do
  [[ "$tier" == "null" ]] && continue
  jq -e --arg b "$backend" --arg t "$tier" '.backends[$b].tier_args | has($t)' \
    "$REGISTRY" >/dev/null 2>&1 || { echo "       role '$role' tier '$tier' missing from backend '$backend' tier_args"; ok_tier=1; }
done < <(jq -r '.roles | to_entries[] | [.key, (.value.tier // "null"), .value.backend] | @tsv' "$REGISTRY")
check "role-tier-in-backend-tier-args" "$ok_tier"

echo
echo "=== enabled/disabled contracts ==="
jq -e '.backends | to_entries | map(select(.value.enabled == true))
       | all((.value.cmd | length > 0) and (.value.preflight | length > 0))' \
  "$REGISTRY" >/dev/null 2>&1
check "enabled-have-cmd-and-preflight" $?
jq -e '.backends | to_entries | map(select(.value.enabled == false))
       | all(.value.disabled_reason | type == "string" and length > 0)' \
  "$REGISTRY" >/dev/null 2>&1
check "disabled-have-reason" $?

echo
echo "=== no model IDs, no credential-shaped content ==="
grep -Eq '(gpt|claude|sonnet|opus|haiku|fable|gemini|grok)-[0-9]' "$REGISTRY"
[[ $? -ne 0 ]]; check "no-model-ids" $?
grep -Eiq '(api[-_]?key|access[-_]?token|secret|password|bearer)' "$REGISTRY"
[[ $? -ne 0 ]]; check "no-credential-shaped-keys" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
