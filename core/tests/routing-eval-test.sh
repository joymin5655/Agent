#!/usr/bin/env bash
# routing-eval-test.sh — the deterministic skill-routing eval (evals/routing) passes its
# floors on the repo skills, and is load-bearing: it fails on lint violations (with exact
# length/line thresholds), on floor breaches, on coverage gaps and on zero skills; Hangul
# n-grams, zero-overlap ranking and disable-model-invocation exclusion are exercised; a
# near-duplicate pair is listed as a collision (report-only); --json is parseable.
# shellcheck disable=SC2319  # `[[ ]]; check $?` is the battery idiom (see evals-test.sh)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/evals/routing/run_routing_eval.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OUT=""; RC=0
run() { OUT="$(python3 "$RUNNER" "$@" 2>&1)"; RC=$?; }

echo "=== (a) repo skills clear the committed floors ==="
run --floors "$REPO_ROOT/evals/routing/floors.json"
[[ $RC -eq 0 ]]; check "repo-floors-pass" $?
printf '%s' "$OUT" | grep -q 'ROUTING EVAL PASS'; check "emits-pass" $?

echo "=== (b) an impossible floor fails ==="
run --min-rank1 100
[[ $RC -ne 0 ]]; check "floor-breach-exits-nonzero" $?
printf '%s' "$OUT" | grep -q 'ROUTING EVAL FAIL'; check "emits-fail" $?

echo "=== (c) lint catches a bad skill (name mismatch, no description, >500 lines) ==="
mkdir -p "$TMP/skills/alpha" "$TMP/skills/beta"
printf -- '---\nname: wrong\ndescription: Does alpha things.\n---\n# alpha\n' > "$TMP/skills/alpha/SKILL.md"
{ printf -- '---\nname: beta\n---\n'; for _ in $(seq 1 510); do echo line; done; } > "$TMP/skills/beta/SKILL.md"
printf '%s\n' '{"cases":[]}' > "$TMP/cases.json"
run --skills-dir "$TMP/skills" --cases "$TMP/cases.json"
[[ $RC -ne 0 ]]; check "lint-error-fails" $?
printf '%s' "$OUT" | grep -q "does not match directory"; check "lint-name-mismatch" $?
printf '%s' "$OUT" | grep -q "description missing"; check "lint-missing-description" $?
printf '%s' "$OUT" | grep -q "lines > 500"; check "lint-too-long" $?

echo "=== (c2) lint thresholds: exact boundaries ==="
mk() { # mk <dir> <description> [when_to_use] [extra-lines]
  mkdir -p "$TMP/$1/$1"
  { printf -- '---\nname: %s\ndescription: %s\n' "$1" "$2"
    [[ -n "${3:-}" ]] && printf 'when_to_use: %s\n' "$3"
    printf -- '---\n'
    for _ in $(seq 1 "${4:-0}"); do echo line; done; } > "$TMP/$1/$1/SKILL.md"
}
rep() { python3 -c 'import sys; print((sys.argv[1]*int(sys.argv[2]))[:int(sys.argv[2])])' "$1" "$2"; }
mk d1024 "$(rep 'x' 1024)"
run --skills-dir "$TMP/d1024" --cases "$TMP/cases.json"
! printf '%s' "$OUT" | grep -q 'lint error'; check "desc-1024-ok" $?
mk d1025 "$(rep 'x' 1025)"
run --skills-dir "$TMP/d1025" --cases "$TMP/cases.json"
[[ $RC -ne 0 ]]; check "desc-1025-fails" $?
printf '%s' "$OUT" | grep -q '1025 chars > 1024'; check "desc-1025-msg" $?
mk w1537 "$(rep 'x' 800)" "$(rep 'y' 737)"
run --skills-dir "$TMP/w1537" --cases "$TMP/cases.json"
[[ $RC -eq 0 ]]; check "combined-1537-warns-exit0" $?
printf '%s' "$OUT" | grep -q 'lint warn.*1537'; check "combined-1537-warn-msg" $?
# frontmatter is 4 lines + the filler; 500 total lines pass, 501 fail
mk l500 "ok" "" 496
[[ "$(wc -l < "$TMP/l500/l500/SKILL.md" | tr -d ' ')" == 500 ]]; check "fixture-500-lines" $?
run --skills-dir "$TMP/l500" --cases "$TMP/cases.json"
[[ $RC -eq 0 ]]; check "lines-500-pass" $?
mk l501 "ok" "" 497
run --skills-dir "$TMP/l501" --cases "$TMP/cases.json"
[[ $RC -ne 0 ]]; check "lines-501-fail" $?

echo "=== (c3) coverage and empty pool ==="
run --skills-dir "$TMP/empty" --cases "$TMP/cases.json"
[[ $RC -ne 0 ]]; check "zero-skills-fails" $?
printf '%s' "$OUT" | grep -q 'no model-invocable skills'; check "zero-skills-msg" $?
printf '%s\n' '{"cases":[{"skill":"ghost","positive":["x"]}]}' > "$TMP/ghost.json"
run --skills-dir "$TMP/d1024" --cases "$TMP/ghost.json" --strict-coverage
[[ $RC -ne 0 ]]; check "strict-absent-skill-fails" $?
run --cases "$TMP/ghost.json"
[[ $RC -ne 0 ]]; check "default-run-skipped-case-fails" $?
printf '%s' "$OUT" | grep -q 'not in the pool'; check "default-run-skipped-msg" $?
printf '%s\n' '{"cases":[{"skill":"wrap","positive":["wrap up and open a PR"]}]}' > "$TMP/partial.json"
run --cases "$TMP/partial.json"
printf '%s' "$OUT" | grep -q 'ranked skills without cases'; check "default-run-uncovered-skill-fails" $?

echo "=== (c4) floor gates ==="
run --floors "$REPO_ROOT/evals/routing/floors.json" --max-negative-violations 0
[[ $RC -ne 0 ]]; check "neg-violations-0-fails" $?
printf '%s' "$OUT" | grep -q 'negative violation'; check "neg-violations-msg" $?
run --floors "$REPO_ROOT/evals/routing/floors.json" --min-top3 99
[[ $RC -ne 0 ]]; check "top3-breach-fails" $?
printf '%s' "$OUT" | grep -q 'top-3'; check "top3-breach-msg" $?

echo "=== (c5) Hangul n-grams, zero-overlap rank, disabled skills ==="
mkdir -p "$TMP/ko/deploy" "$TMP/ko/backup"
printf -- '---\nname: deploy\ndescription: 서버에 배포하고 롤백 절차를 실행한다\n---\n' > "$TMP/ko/deploy/SKILL.md"
printf -- '---\nname: backup\ndescription: 데이터베이스 백업을 만들고 복원을 검증한다\n---\n' > "$TMP/ko/backup/SKILL.md"
printf '%s\n' '{"cases":[{"skill":"deploy","positive":["서버 배포해줘"]},{"skill":"backup","positive":["백업 복원 검증"]}]}' > "$TMP/ko.json"
run --skills-dir "$TMP/ko" --cases "$TMP/ko.json" --min-rank1 100 --json
[[ $RC -eq 0 ]]; check "hangul-rank1-100" $?
printf '%s\n' '{"cases":[{"skill":"deploy","positive":["zzqx qqzz"]}]}' > "$TMP/zero.json"
run --skills-dir "$TMP/ko" --cases "$TMP/zero.json" --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["positive_misses"]; assert m and m[0]["rank"]==2 and d["rank1_pct"]==0'; check "zero-overlap-ranks-last" $?
run --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["skills_ranked"]==d["skills_linted"]-1'; check "harness-help-not-ranked" $?
! grep -q '"skill": "harness-help"' "$REPO_ROOT/evals/routing/cases.json"; check "harness-help-has-no-cases" $?

echo "=== (d) identical descriptions are listed as a near-collision (report-only) ==="
mkdir -p "$TMP/c/one" "$TMP/c/two"
for n in one two; do
  printf -- '---\nname: %s\ndescription: Rotates the deployment credentials for staging clusters nightly.\n---\n# x\n' "$n" > "$TMP/c/$n/SKILL.md"
done
run --skills-dir "$TMP/c" --cases "$TMP/cases.json"
printf '%s' "$OUT" | grep -q 'one <-> two'; check "collision-listed" $?

echo "=== (e) --json is valid and carries the metrics ==="
run --json
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "rank1_pct" in d and "collisions" in d'; check "json-valid" $?

echo
echo "routing-eval-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
