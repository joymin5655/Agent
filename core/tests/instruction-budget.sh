#!/usr/bin/env bash
# instruction-budget.sh — byte ceiling on the instruction files every runtime
# loads into context: skills/*/SKILL.md, agents/*.md, rules/**/*.md.
#
# A skill or rule only grows; nothing pushes back until a prompt is too big to
# read. This gate is that push-back: a file over its class ceiling fails with
# its path, size and ceiling, so the fix (split into a reference file the skill
# loads on demand, or trim) happens at review time instead of after the bloat.
#
# ponytail: one flat ceiling per class, set ~10% above today's largest file
# (SKILL.md 18530, rules 9265, agents 3781 on 2026-10-12). Upgrade path: a
# per-file allowlist with ratchet-down ceilings if one class needs an outlier.
#
# INSTRUCTION_BUDGET_ROOT overrides the scanned root (used by the test battery).
#
# Usage: bash core/tests/instruction-budget.sh
set -euo pipefail

ROOT="${INSTRUCTION_BUDGET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SKILL_MAX=20000
AGENT_MAX=8000
RULE_MAX=12000

over=0
checked=0

# check_class <ceiling> <file>... — report every file over <ceiling> bytes.
check_class() {
  local max="$1" f size; shift
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    size=$(wc -c < "$f" | tr -d ' ')
    checked=$((checked + 1))
    if (( size > max )); then
      echo "FAIL ${f#"$ROOT"/}: ${size} bytes > ${max} ceiling"
      over=$((over + 1))
    fi
  done
}

shopt -s nullglob
check_class "$SKILL_MAX" "$ROOT"/skills/*/SKILL.md "$ROOT"/extras/skills/*/SKILL.md
check_class "$AGENT_MAX" "$ROOT"/agents/*.md "$ROOT"/extras/agents/*.md
# rules nest (rules/policy/…); find instead of globstar, which bash 3.2 lacks.
rules=()
if [[ -d "$ROOT/rules" ]]; then
  while IFS= read -r -d '' f; do rules+=("$f"); done < <(find "$ROOT/rules" -name '*.md' -print0)
fi
check_class "$RULE_MAX" ${rules[@]+"${rules[@]}"}

if (( over > 0 )); then
  echo "instruction-budget: ${over} file(s) over budget (${checked} checked)" >&2
  exit 1
fi
echo "PASS — ${checked} instruction file(s) within budget (SKILL.md ≤ ${SKILL_MAX}, agents ≤ ${AGENT_MAX}, rules ≤ ${RULE_MAX} bytes)"
