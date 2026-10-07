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

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
