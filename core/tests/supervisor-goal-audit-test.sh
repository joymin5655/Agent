#!/usr/bin/env bash
# supervisor-goal-audit-test.sh — the audit-mode command extractor in
# core/infra/supervisor-goal-audit.sh. Focus: `grep -c PATTERN FILE` must be
# captured whole (quoted pattern + file) and stop at the end of the command,
# because the extracted text is eval'd.
#
# Runs inside a throwaway git repo (the script derives REPO_ROOT and its audit
# log from `git rev-parse --show-toplevel`), with AGENT_PLANS_DIR pinned, so the
# harness's own .agent/ is never touched.
#
# Usage: bash core/tests/supervisor-goal-audit-test.sh
# shellcheck disable=SC2016  # literal backticks in plan fixtures are intentional
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT="$REPO_ROOT/core/infra/supervisor-goal-audit.sh"

PASS=0
FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name] expected '$want', got '$got'"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM
export AGENT_PLANS_DIR="$TMP/plans"
mkdir -p "$AGENT_PLANS_DIR" "$TMP/repo"
cd "$TMP/repo" && git init -q . || exit 1
printf 'a b\nx\nx\n' > f.txt

# run_audit <wave-body>: prints the requirements array (one command per line).
run_audit() {
  printf '## Wave 1: t\n\n%s\n' "$1" > "$AGENT_PLANS_DIR/p.md"
  bash "$AUDIT" p 1 2>/dev/null | jq -r '.requirements[]' 2>/dev/null
}

echo "=== extractor: grep -c captured whole ==="
check "unquoted-pattern-and-file" 'grep -c x f.txt' "$(run_audit '- `grep -c x f.txt` -> 2')"
check "double-quoted-pattern-with-space" 'grep -c "a b" f.txt' "$(run_audit '- `grep -c "a b" f.txt` -> 1')"
check "single-quoted-pattern" "grep -c 'x' f.txt" "$(run_audit "- \`grep -c 'x' f.txt\` -> 2")"
check "stops-before-arrow-glyph" 'grep -c x f.txt' "$(run_audit 'Check: grep -c x f.txt → 2 lines')"
check "stops-before-ascii-arrow" 'grep -c x f.txt' "$(run_audit 'Check: grep -c x f.txt -> 2 lines')"
check "stops-before-backtick" 'grep -c x f.txt' "$(run_audit 'run `grep -c x f.txt`.')"

echo "=== extractor: executed command really sees the file ==="
ev="$(printf '## Wave 1: t\n\n%s\n' '- `grep -c "a b" f.txt`' > "$AGENT_PLANS_DIR/p.md"; bash "$AUDIT" p 1 2>/dev/null | jq -r '.evidence[0] | "\(.pass) \(.exit_code)"')"
check "grep-c-quoted-runs-and-passes" "true 0" "$ev"

echo "=== extractor: file token, escapes, option tokens ==="
check "file-with-plus" 'grep -c x f+bar.txt' "$(run_audit 'Check: grep -c x f+bar.txt -> 2')"
check "file-with-at-comma-equals" 'grep -c x a@b,c=d.txt' "$(run_audit 'Check: grep -c x a@b,c=d.txt -> 2')"
check "double-quoted-file" 'grep -c x "f.txt"' "$(run_audit 'Check: grep -c x "f.txt" -> 2')"
check "single-quoted-file" "grep -c x 'f.txt'" "$(run_audit "Check: grep -c x 'f.txt' -> 2")"
check "escaped-quote-in-pattern" 'grep -c "a\"b" f.txt' "$(run_audit 'Check: grep -c "a\"b" f.txt -> 1')"
check "double-dash-option" 'grep -c -- foo f.txt' "$(run_audit 'Check: grep -c -- foo f.txt -> 1')"
check "invert-option" 'grep -c -v x f.txt' "$(run_audit 'Check: grep -c -v x f.txt -> 1')"
check "stops-before-semicolon" 'grep -c x f.txt' "$(run_audit 'Check: grep -c x f.txt; then more')"
check "stops-before-pipe" 'grep -c x f.txt' "$(run_audit 'Check: grep -c x f.txt | wc -l')"

echo "=== extractor: command substitution is never extracted (the match is eval'd) ==="
rm -f PWNED
check "dollar-paren-pattern-skipped" "" "$(run_audit 'Check: grep -c "$(touch PWNED)" f.txt')"
check "dollar-paren-unquoted-skipped" "" "$(run_audit 'Check: grep -c $(touch PWNED) f.txt')"
check "dollar-paren-in-file-skipped" "" "$(run_audit 'Check: grep -c x "$(touch PWNED)"')"
check "backtick-pattern-skipped" "" "$(run_audit 'Check: grep -c "a`touch PWNED`" f.txt')"
check "nothing-was-executed" "no" "$([[ -e PWNED ]] && echo yes || echo no)"

echo "=== eval has stdin closed: a stdin-reading check can never hang the audit ==="
FIFO="$TMP/stdin.fifo"; mkfifo "$FIFO"; exec 9<>"$FIFO"
run_bounded() {  # run_bounded <wave-body> -> "done" if the audit finished within ~10s with stdin open and empty
  printf '## Wave 1: t\n\n%s\n' "$1" > "$AGENT_PLANS_DIR/p.md"
  bash "$AUDIT" p 1 <&9 >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || { echo "done"; return; }
    sleep 0.1
  done
  kill "$pid" 2>/dev/null; echo hung
}
check "stdin-dash-file-does-not-hang" "done" "$(run_bounded 'Check: grep -c x - -> 0')"
check "prose-grep-c-does-not-hang" "done" "$(run_bounded 'The grep -c matches in the file are counted')"
exec 9<&-

echo "=== other extractors unchanged ==="
check "bash-core-script-still-captured" 'bash core/tests/x.sh' "$(run_audit '- `bash core/tests/x.sh` -> exit 0')"
check "test-f-still-captured" 'test -f f.txt' "$(run_audit 'Check: test -f f.txt')"

echo "=== plan path: directory layout first, legacy flat file as fallback ==="
dir_plan() {  # dir_plan <path> <check-file>: write a one-wave plan whose check is `test -f <check-file>`
  mkdir -p "$(dirname "$1")"
  printf '## Wave 1: t\n\n- Check: test -f %s\n' "$2" > "$1"
}
req() { jq -r '.requirements[]' 2>/dev/null; }
dir_plan "$AGENT_PLANS_DIR/d/plan.md" dir.txt
check "env-root-directory-layout" 'test -f dir.txt' "$(bash "$AUDIT" d 1 2>/dev/null | req)"
dir_plan "$AGENT_PLANS_DIR/b/plan.md" dir.txt
dir_plan "$AGENT_PLANS_DIR/b.md" flat.txt
check "env-root-directory-beats-flat" 'test -f dir.txt' "$(bash "$AUDIT" b 1 2>/dev/null | req)"
dir_plan "$AGENT_PLANS_DIR/l.md" flat.txt
check "env-root-legacy-flat-still-read" 'test -f flat.txt' "$(bash "$AUDIT" l 1 2>/dev/null | req)"
dir_plan "$TMP/repo/.agent/plans/r/plan.md" repo.txt
check "repo-relative-directory-layout" 'test -f repo.txt' "$(env -u AGENT_PLANS_DIR bash "$AUDIT" r 1 2>/dev/null | req)"
mkdir -p "$TMP/home"
dir_plan "$TMP/home/.agent/plans/h.md" home.txt
check "home-legacy-flat-fallback" 'test -f home.txt' "$(env -u AGENT_PLANS_DIR HOME="$TMP/home" bash "$AUDIT" h 1 2>/dev/null | req)"
env -u AGENT_PLANS_DIR HOME="$TMP/home" bash "$AUDIT" nope 1 >/dev/null 2>&1
check "missing-plan-exits-3" "3" "$?"

echo "=== converge waves: full gate command kept, gap text never reaches eval ==="
check "converge-gate-keeps-slug-and-wave" 'bash core/infra/completion-gate.sh demo 2' \
  "$(run_audit '- fix: file widget.sh missing → verify: `bash core/infra/completion-gate.sh demo 2`')"
check "gate-without-args-still-captured" 'bash core/infra/completion-gate.sh' \
  "$(run_audit '- `bash core/infra/completion-gate.sh`')"
rm -f PWNED
check "fix-text-command-not-extracted" 'bash core/infra/completion-gate.sh demo 2' \
  "$(run_audit '- fix: pytest x failed $(touch PWNED) → verify: `bash core/infra/completion-gate.sh demo 2`')"
check "fix-text-shell-metachars-not-extracted" 'bash core/infra/completion-gate.sh demo 2' \
  "$(run_audit '- fix: pytest tests/ failed; touch PWNED → verify: `bash core/infra/completion-gate.sh demo 2`')"
check "plain-pytest-with-substitution-dropped" "" "$(run_audit 'Check: pytest x failed $(touch PWNED)')"
check "test-f-with-substitution-dropped" "" "$(run_audit 'Check: test -f $(touch PWNED)')"
check "bash-core-with-backtick-dropped" "" "$(run_audit 'Check: bash core/a`touch PWNED`.sh')"
check "backticked-pytest-stops-at-backtick" 'pytest tests/' "$(run_audit 'Run `pytest tests/` first')"
check "backticked-test-f-stops-at-backtick" 'test -f f.txt' "$(run_audit 'Check: `test -f f.txt`')"
check "backticked-wc-l-stops-at-backtick" 'wc -l f.txt' "$(run_audit 'Check: `wc -l f.txt`')"
check "nothing-was-executed-by-converge-cases" "no" "$([[ -e PWNED ]] && echo yes || echo no)"

echo "=== a converge wave's gate check runs as a dryrun even under an inherited block mode ==="
# The audit runs the harness's own gate (next to the script), not a copy in the project. This
# fixture has no claim file, so the real gate REFUTES: exit 1 in block mode, exit 0 in dryrun.
printf '## Wave 2: converge 1\n- fix: gap → verify: `bash core/infra/completion-gate.sh p 2`\n' > "$AGENT_PLANS_DIR/p.md"
OUT=$(AGENT_VERIFY_BLOCKING=block bash "$AUDIT" p 2 2>/dev/null)
check "inherited-block-gate-check-passes" "true" "$(jq -r '.evidence[0].pass' <<<"$OUT")"
check "inherited-block-gate-ran-dryrun" "dryrun" "$(tail -n 1 .agent/logs/completion-gate.jsonl | jq -r '.mode')"
printf '## Wave 1: t\n- `wc -l f.txt` -> 3\n' > "$AGENT_PLANS_DIR/p.md"
OUT=$(AGENT_VERIFY_BLOCKING=block bash "$AUDIT" p 1 2>/dev/null)
check "other-checks-keep-env" "true" "$(jq -r '.evidence[0].pass' <<<"$OUT")"
echo "=== an ASCII -> marker on a fix step also keeps gap text out ==="
check "ascii-arrow-fix-text-not-extracted" 'bash core/infra/completion-gate.sh demo 2' \
  "$(run_audit '- fix: pytest x; touch PWNED -> verify: `bash core/infra/completion-gate.sh demo 2`')"
echo "=== converge waves: a suffix on the gate command never reaches the shell the audit evals ==="
# These run the audit for real: the rewritten gate command executes, so a leaked suffix would
# create PWNED. The gate's sink gaining one record shows the command ran at all.
inject_case() { # inject_case <name> <suffix>: a wave-2 gate step carrying <suffix> inside the span
  local name="$1" suffix="$2" gate="bash core/infra/completion-gate.sh p 2" before
  rm -f PWNED
  mkdir -p .agent/logs && touch .agent/logs/completion-gate.jsonl
  before=$(wc -l < .agent/logs/completion-gate.jsonl)
  printf '## Wave 2: converge 1\n- fix: gap → verify: `%s%s`\n' "$gate" "$suffix" \
    > "$AGENT_PLANS_DIR/p.md"
  OUT=$(bash "$AUDIT" p 2 2>/dev/null)
  check "$name-suffix-gate-ran-as-rewritten" "$gate" "$(jq -r '.evidence[0].cmd' <<<"$OUT")"
  check "$name-suffix-gate-wrote-one-record" "1" \
    "$(( $(wc -l < .agent/logs/completion-gate.jsonl) - before ))"
  check "$name-suffix-not-executed" "no" "$([[ -e PWNED ]] && echo yes || echo no)"
}
inject_case "semicolon" ';touch PWNED'
inject_case "substitution" ' $(touch PWNED)'
echo "=== a dropped command is reported on stderr ==="
printf '## Wave 1: t\n\nCheck: test -f $(touch PWNED)\n' > "$AGENT_PLANS_DIR/p.md"
check "drop-is-logged" "1" "$(bash "$AUDIT" p 1 2>&1 >/dev/null | grep -c 'dropped (substitution)')"

echo "=== zero extracted checks is unverified (exit 4), not a pass ==="
printf '## Wave 1: t\n\nnothing runnable here\n' > "$AGENT_PLANS_DIR/p.md"
OUT=$(bash "$AUDIT" p 1 2>/dev/null); RC=$?
check "zero-checks-exit-4" "4" "$RC"
check "zero-checks-all-pass-null" "null" "$(jq -c '.all_pass' <<<"$OUT")"

echo "=== a denied check is recorded as denied: not run, neither pass nor fail ==="
# the pytest extractor takes everything up to a quote/backtick, so a plan line can smuggle a second command
: > f.txt
printf '## Wave 1: t\n\nCheck: pytest -q nothing ; rm -rf f.txt\n' > "$AGENT_PLANS_DIR/p.md"
OUT=$(bash "$AUDIT" p 1 2>/dev/null); RC=$?
check "denied-check-recorded" "true" "$(jq -r '.evidence[0].denied // false' <<<"$OUT")"
check "denied-check-exit-4" "4" "$RC"
check "denied-check-all-pass-null" "null" "$(jq -c '.all_pass' <<<"$OUT")"
check "denied-command-did-not-run" "yes" "$([[ -e f.txt ]] && echo yes || echo no)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
