#!/usr/bin/env bash
# plan-lint-test.sh — prove core/infra/plan-lint.sh is NON-VACUOUS: a clean
# plan+spec exits 0, and each defect class exits 1 naming the offending line.
#
# Each case gets a FRESH fixture (mktemp -d) so a mutation never leaks.
#
# Usage: bash core/tests/plan-lint-test.sh
# shellcheck disable=SC2016
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$REPO_ROOT/core/infra/plan-lint.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# new_fixture — a clean plan+spec dir; echoes its path.
new_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  cat > "$fx/plan.md" <<'PLAN'
# demo — plan

## Wave 1: build
- Write `widget.sh` first
  → verify: `bash widget-test.sh`
- Wire it up -> verify: `grep -q widget main.sh`
PLAN
  cat > "$fx/spec.md" <<'SPEC'
# demo — spec

## Decisions
- none (fixture)

## Success criteria
- `widget.sh` exits 0 on a clean input.
- A human-readable criterion with no code term.
SPEC
  printf '%s' "$fx"
}

LINT_OUT=""; LINT_RC=0
run_lint() { LINT_OUT="$(bash "$LINT" "$@" 2>&1)"; LINT_RC=$?; }
# rc_is <n> — echo 0 if the last lint exit code was <n>, else 1 (check input).
rc_is() { if [[ $LINT_RC -eq $1 ]]; then echo 0; else echo 1; fi; }
out_has() { printf '%s\n' "$LINT_OUT" | grep -qF -- "$1"; }

echo "=== (0) clean plan+spec -> exit 0 ==="
FX=$(new_fixture)
run_lint "$FX"
check "clean-passes" "$(rc_is 0)"
out_has 'PASS'; check "clean-prints-pass" $?

echo
echo "=== (1) no Wave header -> exit 1 ==="
FX=$(new_fixture)
printf '# demo\n\n- step -> verify: `true`\n' > "$FX/plan.md"
run_lint "$FX"
check "no-wave-fails" "$(rc_is 1)"
out_has 'Wave'; check "no-wave-named" $?

echo
echo "=== (1b) malformed ## header -> exit 1 ==="
FX=$(new_fixture)
printf '\n## Notes\n' >> "$FX/plan.md"
run_lint "$FX"
check "bad-header-fails" "$(rc_is 1)"
out_has 'plan.md:8'; check "bad-header-line" $?

echo
echo "=== (2) step without verify -> exit 1 + line ==="
FX=$(new_fixture)
printf -- '- Orphan step with no check\n' >> "$FX/plan.md"
run_lint "$FX"
check "no-verify-fails" "$(rc_is 1)"
out_has 'plan.md:7'; check "no-verify-names-line" $?

echo
echo "=== (3) prose verify without reason -> exit 1 ==="
FX=$(new_fixture)
printf -- '- Prose step\n  → verify: looks fine to me\n' >> "$FX/plan.md"
run_lint "$FX"
check "prose-verify-fails" "$(rc_is 1)"
out_has 'plan.md:7'; check "prose-verify-names-line" $?

echo
echo "=== (4) prose verify WITH reason: -> exit 0 ==="
FX=$(new_fixture)
printf -- '- Prose step\n  → verify: reason: purely visual, no command applies\n' >> "$FX/plan.md"
run_lint "$FX"
check "prose-with-reason-passes" "$(rc_is 0)"

echo
echo "=== (5) unreferenced backticked criterion -> exit 1 + named ==="
FX=$(new_fixture)
printf -- '- `ghost-term` must be handled\n' >> "$FX/spec.md"
run_lint "$FX"
check "unref-criterion-fails" "$(rc_is 1)"
out_has 'ghost-term'; check "unref-criterion-named" $?
out_has 'criterion not referenced by plan'; check "unref-criterion-reason" $?

echo
echo "=== (6) slug resolution from CWD ==="
FX=$(new_fixture)
mkdir -p "$FX/root/.agent/plans/demo"
cp "$FX/plan.md" "$FX/spec.md" "$FX/root/.agent/plans/demo/"
LINT_OUT="$(cd "$FX/root" && bash "$LINT" demo 2>&1)"; LINT_RC=$?
check "slug-resolves" "$(rc_is 0)"

echo
echo "=== (7) missing plan.md -> exit 2 ==="
FX="$(mktemp -d "$TMP_ROOT/emptyXXXXXX")"
run_lint "$FX"
check "missing-plan-exit2" "$(rc_is 2)"
echo
echo "=== (8) fix1: verify marker is the last one outside backticks ==="
FX=$(new_fixture)
printf -- '- Document `→ verify:` format → verify: looks fine\n' >> "$FX/plan.md"
run_lint "$FX"
check "quoted-marker-prose-fails" "$(rc_is 1)"
out_has 'plan.md:7'; check "quoted-marker-prose-line" $?
out_has 'no backticked command'; check "quoted-marker-prose-reason" $?
FX=$(new_fixture)
printf -- '- Teach lint about `→ verify:` markers\n' >> "$FX/plan.md"
run_lint "$FX"
check "quoted-marker-only-fails" "$(rc_is 1)"
out_has 'step has no'; check "quoted-marker-only-no-verify" $?
FX=$(new_fixture)
printf -- '- Parent step → verify: looks fine\n  - sub-bullet with `cmd`\n' >> "$FX/plan.md"
run_lint "$FX"
check "subbullet-no-rescue-fails" "$(rc_is 1)"

echo
echo "=== (9) fix2: criteria match step text only; boilerplate ignored ==="
FX=$(new_fixture)
printf -- '- `demo` is mentioned only in the plan title\n' >> "$FX/spec.md"
run_lint "$FX"
check "title-only-term-fails" "$(rc_is 1)"
FX=$(new_fixture)
printf -- '- `build` is mentioned only in a Wave header\n' >> "$FX/spec.md"
run_lint "$FX"
check "header-only-term-fails" "$(rc_is 1)"
FX=$(new_fixture)
printf -- '- Every step carries `→ verify:` and `## Wave N:`\n' >> "$FX/spec.md"
run_lint "$FX"
check "boilerplate-only-skipped" "$(rc_is 0)"
FX=$(new_fixture)
printf -- '- `ghost-term` or `widget.sh` (any-hit)\n' >> "$FX/spec.md"
run_lint "$FX"
check "any-hit-passes" "$(rc_is 0)"

echo
echo "=== (10) fix3: fenced lines are neither headers nor steps ==="
FX=$(new_fixture)
printf '\n```\n## Not a header\n- fenced step with no verify\n```\n' >> "$FX/plan.md"
run_lint "$FX"
check "plan-fence-ignored" "$(rc_is 0)"
FX=$(new_fixture)
printf '\n```\n- `ghost-term` fenced criterion\n```\n' >> "$FX/spec.md"
run_lint "$FX"
check "spec-fence-ignored" "$(rc_is 0)"

echo
echo "=== (11) fix4: bullet styles; empty wave ==="
for marker in '*' '+' '1.' '2)'; do
  FX=$(new_fixture)
  printf -- '%s Styled step with no check\n' "$marker" >> "$FX/plan.md"
  run_lint "$FX"
  check "style-${marker}-fails" "$(rc_is 1)"
  FX=$(new_fixture)
  printf -- '%s Styled step -> verify: `true`\n' "$marker" >> "$FX/plan.md"
  run_lint "$FX"
  check "style-${marker}-passes" "$(rc_is 0)"
done
FX=$(new_fixture)
printf '\n## Wave 2: empty\n' >> "$FX/plan.md"
run_lint "$FX"
check "empty-wave-fails" "$(rc_is 1)"
out_has 'wave has no steps'; check "empty-wave-named" $?

echo
echo "=== (12) fix5: H1 resets wave context; Wave 10 accepted ==="
FX=$(new_fixture)
printf '\n# Appendix\n- loose bullet without verify\n' >> "$FX/plan.md"
run_lint "$FX"
check "h1-resets-wave" "$(rc_is 0)"
FX=$(new_fixture)
printf '\n## Wave 10: ten\n- Step -> verify: `true`\n' >> "$FX/plan.md"
run_lint "$FX"
check "wave-10-accepted" "$(rc_is 0)"

echo
echo "=== (13) fix6: plan and spec defects both reported on separate lines ==="
FX=$(new_fixture)
printf -- '- Orphan step\n' >> "$FX/plan.md"
printf -- '- `ghost-term` unreferenced\n' >> "$FX/spec.md"
run_lint "$FX"
check "both-fail" "$(rc_is 1)"
NFAIL=$(printf "%s\n" "$LINT_OUT" | grep -c "^FAIL " || true)
check "both-two-lines" "$(if [[ $NFAIL -eq 2 ]]; then echo 0; else echo 1; fi)"

echo
echo "=== (14) fix7: argument resolution ==="
run_lint "bad slug"
check "slug-space-exit2" "$(rc_is 2)"
run_lint ".."
check "slug-dotdot-exit2" "$(rc_is 2)"
run_lint 'a;b'
check "slug-meta-exit2" "$(rc_is 2)"
FX=$(new_fixture)
LINT_OUT="$(cd "$FX" && bash "$LINT" . 2>&1)"; LINT_RC=$?
check "dot-is-dir" "$(rc_is 0)"

echo
echo "=== (15) fix8: spec without ## Decisions -> FAIL ==="
FX=$(new_fixture)
printf '# demo\n\n## Success criteria\n- `widget.sh` ok\n' > "$FX/spec.md"
run_lint "$FX"
check "no-decisions-fails" "$(rc_is 1)"
out_has 'spec has no ## Decisions section'; check "no-decisions-named" $?

echo
echo "=== (16) fix9: no spec.md -> spec checks skipped ==="
FX=$(new_fixture)
rm "$FX/spec.md"
run_lint "$FX"
check "no-spec-passes" "$(rc_is 0)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
