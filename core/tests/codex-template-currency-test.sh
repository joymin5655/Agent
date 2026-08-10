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

# Retired model-ID stems (matched as gpt-5.X with optional -suffix).
DENY_REGEX='gpt-5\.[234]([^0-9]|$)'

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
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
