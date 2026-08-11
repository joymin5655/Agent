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

# exit 2, not 0: exiting 0 made verify-all print `PASS backends-schema-test.sh`
# while this battery asserted NOTHING, and discard this SKIP line with it (the
# runner echoes a check's output on FAIL only). rc 2 + a lone SKIP line is the
# runner's declared inapplicable-check contract.
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 2; }

# AGENT_PIN_JQ — "backend $b's tier_args pins a profile at tier $t": the tier key
# must exist AND its value must be an array carrying "--agent" IMMEDIATELY
# followed by a nonempty string. Key presence alone was the old test, and it was
# vacuous: "tier_args": {"TOP": []} satisfied has("TOP") while call-worker.sh
# composed argv with NO --agent flag at all — default model, default (NOT
# read-only) tool set, which is precisely what these checks exist to prevent.
AGENT_PIN_JQ='
  .backends[$b].tier_args as $ta
  | (($ta | type) == "object") and ($ta | has($t))
    and ($ta[$t] | . as $a | ((type) == "array")
         and ([ range(0; ($a | length)) as $i
                | select($a[$i] == "--agent")
                | select(($i + 1) < ($a | length))
                | select(($a[$i + 1] | type) == "string")
                | select($a[$i + 1] != "") ] | length > 0))'

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
# Every role with a tier names a key of its backend's tier_args — and for a
# GATEWAY backend that key must actually pin a profile (see AGENT_PIN_JQ).
ok_tier=0
while IFS=$'\t' read -r role tier backend; do
  [[ "$tier" == "null" ]] && continue
  if [[ "$(jq -r --arg b "$backend" '.backends[$b].gateway // "" | tostring' "$REGISTRY")" != "" ]]; then
    jq -e --arg b "$backend" --arg t "$tier" "$AGENT_PIN_JQ" "$REGISTRY" >/dev/null 2>&1 \
      || { echo "       role '$role' tier '$tier' on GATEWAY backend '$backend' does not pin '--agent <profile>'"; ok_tier=1; }
  else
    jq -e --arg b "$backend" --arg t "$tier" '.backends[$b].tier_args | has($t)' \
      "$REGISTRY" >/dev/null 2>&1 || { echo "       role '$role' tier '$tier' missing from backend '$backend' tier_args"; ok_tier=1; }
  fi
done < <(jq -r '.roles | to_entries[] | [.key, (.value.tier // "null"), .value.backend] | @tsv' "$REGISTRY")
check "role-tier-in-backend-tier-args" "$ok_tier"
# ...and so does its FALLBACK. call-worker.sh resolves ROLE_TIER once, from the
# role, and reuses it for whichever backend it ends up running (run_backend
# looks up .backends[$name].tier_args[$ROLE_TIER] for the fallback too). A
# fallback missing that tier key does not fail loudly — jq yields an empty list,
# argv composes to the bare cmd, and the dispatch silently runs with NO profile
# flag: default model, default (not read-only) tool set. Only the primary's tier
# was guarded before, so that hole was one registry edit wide. And a tier key
# whose VALUE carries no "--agent <profile>" is the same hole with the key
# present, so gateway fallbacks get the AGENT_PIN_JQ treatment.
ok_fb_tier=0
while IFS=$'\t' read -r role tier fallback; do
  [[ "$tier" == "null" || "$fallback" == "null" ]] && continue
  if [[ "$(jq -r --arg b "$fallback" '.backends[$b].gateway // "" | tostring' "$REGISTRY")" != "" ]]; then
    jq -e --arg b "$fallback" --arg t "$tier" "$AGENT_PIN_JQ" "$REGISTRY" >/dev/null 2>&1 \
      || { echo "       role '$role' tier '$tier' on GATEWAY FALLBACK backend '$fallback' does not pin '--agent <profile>'"; ok_fb_tier=1; }
  else
    jq -e --arg b "$fallback" --arg t "$tier" '.backends[$b].tier_args | has($t)' \
      "$REGISTRY" >/dev/null 2>&1 || { echo "       role '$role' tier '$tier' missing from FALLBACK backend '$fallback' tier_args"; ok_fb_tier=1; }
  fi
done < <(jq -r '.roles | to_entries[] | [.key, (.value.tier // "null"), (.value.fallback // "null")] | @tsv' "$REGISTRY")
check "role-tier-in-fallback-tier-args" "$ok_fb_tier"
# EVERY tier of EVERY gateway backend, not only the tiers some role happens to
# reference: an unpinned tier is a latent default-model, default-tools dispatch
# the moment a role points at it.
ok_gw_tier=0
while IFS=$'\t' read -r backend tier; do
  if [[ "$tier" == "<tier_args-not-an-object>" ]]; then
    echo "       gateway backend '$backend' has a non-object tier_args"; ok_gw_tier=1; continue
  fi
  jq -e --arg b "$backend" --arg t "$tier" "$AGENT_PIN_JQ" "$REGISTRY" >/dev/null 2>&1 \
    || { echo "       gateway backend '$backend' tier '$tier' does not pin '--agent <profile>'"; ok_gw_tier=1; }
done < <(jq -r '.backends | to_entries[]
                | select(.value.gateway != null) | .key as $b
                | (.value.tier_args // {})
                | if type == "object"
                  then (if length == 0 then [$b, "<no-tiers>"] else (to_entries[] | [$b, .key]) end)
                  else [$b, "<tier_args-not-an-object>"] end
                | @tsv' "$REGISTRY")
check "gateway-tiers-pin-an-agent-profile" "$ok_gw_tier"

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
echo "=== shipped kiro profile templates: read-only + model pin ==="
# These are the SHIPPED templates (adapters/kiro/*.json.template), not a fixture.
# The profile's tool list is the lane's real isolation boundary — it overrides
# even --trust-all-tools (adapters/kiro/README.md § Read-only by construction) —
# and until now nothing tested it: flipping every template to
# ["read","shell","write"] left the whole battery green. The registry forbids
# model IDs, so the model pin only exists here too; both properties are asserted
# on the shipped bytes.
KIRO_TPL_DIR="$REPO_ROOT/adapters/kiro"
kiro_tpls=()
for f in "$KIRO_TPL_DIR"/*.json.template; do
  [[ -e "$f" ]] || continue          # bash 3.2: unmatched glob stays literal
  kiro_tpls+=("$f")
done
[[ ${#kiro_tpls[@]} -gt 0 ]]; check "kiro-templates-exist" $?
# Read-only capability is an ALLOWLIST, not a denylist: an unrecognized tool name
# fails the check, so a future shell/write-equivalent capability cannot pass by
# not being on a blocklist. Both field names are checked — a permissive entry
# under either one grants the capability.
KIRO_RO_JQ='
  ["read", "fs_read", "@builtin/read"] as $ro
  | [ (.tools // "<missing>"), (.allowedTools // "<missing>") ]
  | map(if type == "array" then . else ["<not-an-array>"] end)
  | add
  | map(. as $e | select((($e | type) != "string") or (($ro | index($e)) == null)))
  | map(tostring) | unique | join(",")'
kiro_bad_json="" kiro_bad_tools="" kiro_bad_model="" kiro_empty_tools=""
for f in ${kiro_tpls[@]+"${kiro_tpls[@]}"}; do
  base="$(basename "$f")"
  if ! jq -e . "$f" >/dev/null 2>&1; then
    kiro_bad_json="${kiro_bad_json:+$kiro_bad_json, }$base"
    continue
  fi
  jq -e '(.model | type == "string") and (.model != "")' "$f" >/dev/null 2>&1 \
    || kiro_bad_model="${kiro_bad_model:+$kiro_bad_model, }$base"
  jq -e '((.tools // null) | type == "array" and length > 0)
         and ((.allowedTools // null) | type == "array" and length > 0)' "$f" >/dev/null 2>&1 \
    || kiro_empty_tools="${kiro_empty_tools:+$kiro_empty_tools, }$base"
  offenders="$(jq -r "$KIRO_RO_JQ" "$f" 2>/dev/null)"
  [[ -z "$offenders" ]] \
    || kiro_bad_tools="${kiro_bad_tools:+$kiro_bad_tools; }$base -> $offenders"
done
[[ -z "$kiro_bad_json" ]] || echo "       invalid JSON: $kiro_bad_json"
[[ -z "$kiro_bad_json" ]]; check "kiro-templates-valid-json" $?
[[ -z "$kiro_bad_model" ]] || echo "       no nonempty .model pin: $kiro_bad_model"
[[ -z "$kiro_bad_model" ]]; check "kiro-templates-pin-a-model" $?
[[ -z "$kiro_empty_tools" ]] || echo "       tools/allowedTools missing or empty: $kiro_empty_tools"
[[ -z "$kiro_empty_tools" ]]; check "kiro-templates-declare-both-tool-fields" $?
[[ -z "$kiro_bad_tools" ]] || echo "       non-read-only tool entries: $kiro_bad_tools"
[[ -z "$kiro_bad_tools" ]]; check "kiro-templates-are-read-only" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
