#!/usr/bin/env bash
# codex-template-currency-test.sh — verify the shipped Codex profile templates
# do not pin a sunset model ID.
#
# OpenAI retired the legacy Codex model family (gpt-5.2 / gpt-5.3 / gpt-5.4,
# incl. -mini/-codex variants) on 2026-07-23; a template pinning one of those
# IDs installs a config that fails on every dispatch. This battery checks only
# `model = "..."` assignment lines (comments may reference dead IDs when
# documenting the sunset itself) against a DENYLIST of retired IDs — a
# denylist of known-dead IDs rots slower than an allowlist of live ones.
#
# Usage: bash core/tests/codex-template-currency-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/adapters/codex"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

# Retired model-ID stems (matched as gpt-5.X with optional -suffix). Kept in
# sync with docs/runtime-registry.json codex.retired_model_patterns (SSOT, also
# enforced over pin files by core/tests/runtime-currency.sh): gpt-5.5/5.6 are
# retired pre-emptively ahead of the 2026-10-14 sunset.
DENY_REGEX='gpt-5\.[2-6]([^0-9]|$)'

echo "=== sunset model IDs are absent from template model assignments ==="
found=0
for tpl in "$TEMPLATE_DIR"/*.template; do
  [[ -f "$tpl" ]] || continue
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*model[[:space:]]*= ]] && \
       printf '%s\n' "$line" | grep -Eq "$DENY_REGEX"; then
      echo "  FAIL [sunset-model-pinned] ${tpl#"$REPO_ROOT"/}: $line"
      found=1
    fi
  done < "$tpl"
done
check "no-sunset-model-in-templates" "$found"

echo
echo "=== profile templates still pin an explicit model (regression guard) ==="
for name in quick deep; do
  tpl="$TEMPLATE_DIR/$name.config.toml.template"
  grep -Eq '^[[:space:]]*model[[:space:]]*=[[:space:]]*"[^"]+"' "$tpl"
  check "$name-pins-a-model" $?
  grep -Eq '^[[:space:]]*model_reasoning_effort[[:space:]]*=' "$tpl"
  check "$name-sets-reasoning-effort" $?
done

echo
echo "=== default (unprefixed) template pins a model + effort (regression guard) ==="
DEFAULT_TPL="$TEMPLATE_DIR/codex-config.toml.template"
grep -Eq '^[[:space:]]*model[[:space:]]*=[[:space:]]*"[^"]+"' "$DEFAULT_TPL"
check "default-pins-a-model" $?
grep -Eq '^[[:space:]]*model_reasoning_effort[[:space:]]*=' "$DEFAULT_TPL"
check "default-sets-reasoning-effort" $?

echo
echo "=== deep profile's effort is at least high (TOP tier, regression guard) ==="
# Codex accepts low|medium|high|xhigh (docs/runtime-registry.json notes an
# effort ceiling above high — the deep profile already uses xhigh; guard
# against a future edit silently dropping to medium/low, which would defeat
# the point of a TOP-tier profile).
DEEP_TPL="$TEMPLATE_DIR/deep.config.toml.template"
grep -Eq '^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"(high|xhigh|max)"' "$DEEP_TPL"
check "deep-effort-is-high-or-above" $?

echo
echo "=== global AGENTS.md template (regression guard) ==="
# adapters/codex/AGENTS.global.md.template pins no model (it's a portable
# rules file, not a profile — see quick/deep above for the model-pin check),
# so its currency invariant is simpler: it must exist, and it is already
# swept by the sunset-model-ID loop above via the *.template glob. This is
# a plain existence guard so a future refactor can't silently drop it.
GLOBAL_AGENTS_TPL="$TEMPLATE_DIR/AGENTS.global.md.template"
[[ -f "$GLOBAL_AGENTS_TPL" ]]
check "global-agents-template-exists" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
