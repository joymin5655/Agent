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
#   - cross-company review: every backend names its vendor (the author-vendor exclusion
#     matches on it); `cross-review` is codex with a claude fallback on ANOTHER vendor;
#     the review/verify roles are `readonly` (a boolean) and carry no sandbox argument of
#     their own, the codex argv sets none either, and the claude lane is limited to the
#     Read/Grep/Glob tools with no MCP servers and no permission bypass, and runs with
#     --safe-mode and --restricted (no project/user settings, no auto-run hooks), never --bare;
#     the implementer
#     keeps only flags `codex exec` accepts (no --ask-for-approval); codex gets >= 600 s
#
# Usage: bash core/tests/backends-schema-test.sh
set -u
# keep call-worker.sh evidence/lane rows out of the real ~/.agent logs
ISO_TMP="$(mktemp -d)"
trap 'rm -rf "$ISO_TMP"' EXIT
export AGENT_LOGS_DIR="$ISO_TMP/agent-logs"
export AGENT_WORKERS_DIR="${AGENT_WORKERS_DIR:-$ISO_TMP/agent-workers}"

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
# the moment a role points at it. No shipped backend carries a gateway since the
# kiro lanes were retired (2026-10, legacy/lanes-2026-10/), so the loop below is
# empty and the check passes vacuously; it stays so a re-added gateway lane is
# held to the same contract.
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
# No shipped backend is disabled since the 2026-10-08 lane retirement, so this passes on an
# empty set; it stays as the contract for a lane re-added with enabled:false.
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
echo "=== agy/antigravity lane pins Google-vendor models only (vendor independence) ==="
# agy also serves Claude models, so the council's google lane must stay
# gemini-* — a comment saying so is the guard against a future edit quietly
# pinning a non-Google model into that lane's tiers file.
jq -e '.backends.gemini.comment // "" | test("(?i)google-vendor|gemini-\\*")' \
  "$REGISTRY" >/dev/null 2>&1
check "gemini-lane-vendor-independence-comment" $?

echo
echo "=== cross-company review: roles, read-only pins, the claude lane ==="
# Sandbox-setting arguments of the codex CLI. call-worker.sh refuses a readonly role whose argv
# carries one (a later flag would win and un-pin `--sandbox read-only`); the registry must not.
SANDBOX_ARG_JQ='. == "-s" or . == "--sandbox" or startswith("--sandbox=") or . == "--full-auto"
                or . == "--approve-for-me" or . == "--dangerously-bypass-approvals-and-sandbox"'
# The author-vendor exclusion matches on "vendor", so every backend must carry one.
jq -e '.backends | to_entries | all(.value.vendor | type == "string" and length > 0)' \
  "$REGISTRY" >/dev/null 2>&1
check "every-backend-names-its-vendor" $?
# cross-review: codex first, claude as the fallback — on purpose another vendor, unlike the
# voting lanes; call-worker.sh's author exclusion keeps the author's own company out.
jq -e '.roles["cross-review"] | .backend == "codex" and .fallback == "claude"
       and .tier == "TOP" and .readonly == true' "$REGISTRY" >/dev/null 2>&1
check "cross-review-role-shape" $?
jq -e '.backends as $b | .roles["cross-review"] | $b[.backend].vendor != $b[.fallback].vendor' \
  "$REGISTRY" >/dev/null 2>&1
check "cross-review-fallback-is-another-vendor" $?
# The claude lane: anthropic, print mode, exactly Read/Grep/Glob, no MCP servers, no bypass.
jq -e '.backends.claude | .vendor == "anthropic" and (.cmd | index("-p")) != null
       and ((.cmd | index("--tools")) as $i
            | $i != null and ((.cmd[$i + 1] // "") | split(",") | sort) == ["Glob", "Grep", "Read"])
       and (.cmd | index("--strict-mcp-config")) != null
       and ((.cmd | map(select(startswith("--dangerously") or startswith("--allow-dangerously")
                               or . == "--allowedTools" or . == "--allowed-tools"
                               or startswith("--permission-mode"))) | length) == 0)' \
  "$REGISTRY" >/dev/null 2>&1
check "claude-lane-read-only-tools" $?
# The reviewed repository is untrusted and `claude -p` reads its ./.claude/settings.json: a
# planted SessionStart command ran without these two flags and was stopped by each (measured on
# 2.1.312). Both stay, ahead of the tool list.
jq -e '.backends.claude.cmd | (index("--safe-mode")) != null and (index("--restricted")) != null
       and index("--safe-mode") < index("--tools") and index("--restricted") < index("--tools")' \
  "$REGISTRY" >/dev/null 2>&1
check "claude-lane-safe-mode-and-restricted" $?
# --bare skips the subscription login (OAuth), so the lane would not authenticate.
jq -e '.backends.claude.cmd | index("--bare") == null' "$REGISTRY" >/dev/null 2>&1
check "claude-lane-not-bare" $?
# Review, verify and advisor roles never write; the implementer is the one role that does.
jq -e '.roles as $r | ["cross-review", "second-opinion-review", "second-opinion-verify",
                       "third-opinion-review", "advisor"] | all($r[.].readonly == true)' \
  "$REGISTRY" >/dev/null 2>&1
check "review-roles-are-readonly" $?
jq -e '.roles.implementer | (.readonly // false) == false' "$REGISTRY" >/dev/null 2>&1
check "implementer-is-not-readonly" $?
jq -e '.roles | to_entries | all(.value | ((has("readonly") | not) or (.readonly | type == "boolean")))' \
  "$REGISTRY" >/dev/null 2>&1
check "readonly-is-a-boolean" $?
jq -e "[.roles | to_entries[] | select(.value.readonly == true) | (.value.args_extra // [])[]]
       | map(select($SANDBOX_ARG_JQ)) | length == 0" "$REGISTRY" >/dev/null 2>&1
check "readonly-roles-carry-no-sandbox-arg" $?
jq -e "[.backends.codex.cmd[], (.backends.codex.tier_args | .[][])]
       | map(select($SANDBOX_ARG_JQ)) | length == 0" "$REGISTRY" >/dev/null 2>&1
check "codex-argv-carries-no-sandbox-arg" $?
# codex 0.161 `exec` has no --ask-for-approval; the implementer used to pass it and failed.
jq -e '.roles.implementer.args_extra == ["--sandbox", "workspace-write"]' "$REGISTRY" >/dev/null 2>&1
check "implementer-args-are-ones-codex-exec-accepts" $?
grep -q -- '--ask-for-approval' "$REGISTRY"
[[ $? -ne 0 ]]; check "no-ask-for-approval-flag" $?
# 26 of 163 local codex runs were cut at the old 300 s cap.
jq -e '.backends.codex.timeout_s >= 600' "$REGISTRY" >/dev/null 2>&1
check "codex-timeout-at-least-600s" $?
# docs/model-routing.md names the advisor role, so it stays.
jq -e '.roles.advisor.backend == "codex"' "$REGISTRY" >/dev/null 2>&1
check "advisor-role-kept" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
