#!/usr/bin/env bash
# supervisor-goal-log-test.sh — the append-only decision log and completion cross-check in
# core/infra/supervisor-goal-log.sh: pointer-only evidence, supersede-not-edit, CSV-injection
# neutralization, secret redaction, the "## Attention" cross-check, and that
# `supervisor-goal.sh complete` prints it to stderr without disturbing the stdout contract.
#
# Each case runs in a fresh throwaway git repo.
#
# Usage: bash core/tests/supervisor-goal-log-test.sh
# shellcheck disable=SC2016,SC2319  # literal $ in fixtures; `[[ ]]; check … $?` passes the test result on purpose
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v sqlite3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: supervisor-goal-log-test.sh requires sqlite3 + jq + python3; not installed"
  exit 2
fi

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

build_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  (cd "$fx" && git init -q && git config user.email t@example.com && git config user.name t)
  mkdir -p "$fx/core/infra/sql"
  cp "$REPO_ROOT/core/infra/supervisor-goal.sh" "$REPO_ROOT/core/infra/supervisor-goal-log.sh" "$fx/core/infra/"
  cp "$REPO_ROOT/core/infra/sql/001_supervisor_goals.sql" "$fx/core/infra/sql/"
  printf 'hello\n' > "$fx/real.txt"
  (cd "$fx" && git add real.txt && git commit -q -m init)
  printf '%s' "$fx"
}

OUT=""; RC=0
L() { local fx="$1"; shift; OUT="$(cd "$fx" && bash core/infra/supervisor-goal-log.sh "$@" 2>&1)"; RC=$?; }
rc_is() { if [[ $RC -eq $1 ]]; then echo 0; else echo 1; fi; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
TSV() { printf '%s/.agent/plans/demo/DECISIONS.tsv' "$1"; }

echo "=== (1) append writes header + row with a pointer ==="
FX=$(build_fixture)
SHA=$(cd "$FX" && git rev-parse --short HEAD)
L "$FX" append demo wave-1 "use sqlite" "need resumable state" "$SHA" pass
check "append-ok" "$(rc_is 0)"
[[ "$(head -n1 "$(TSV "$FX")")" == $'ts\tphase\tdecision\twhy\tevidence\tresult' ]]; check "header-first" $?
[[ "$(wc -l < "$(TSV "$FX")" | tr -d ' ')" == 2 ]]; check "two-lines" $?
awk -F'\t' 'NR==2 && NF==6 && $2=="wave-1" && $5=="'"$SHA"'"' "$(TSV "$FX")" | grep -q .; check "row-shape" $?
L "$FX" append demo wave-1 second why real.txt:1 pass
[[ "$(head -c 2 "$(TSV "$FX")")" == "ts" ]]; check "header-not-duplicated" $?

echo
echo "=== (2) evidence must be a pointer, not prose ==="
L "$FX" append demo plan "d" "w" "I checked it and it looks fine" pass
check "prose-evidence-rejected" "$(rc_is 2)"
has 'pointer'; check "prose-evidence-named" $?
[[ "$(wc -l < "$(TSV "$FX")" | tr -d ' ')" == 3 ]]; check "rejected-row-not-written" $?

echo
echo "=== (3) CSV/formula injection is neutralized; tabs and newlines flattened ==="
FX=$(build_fixture)
L "$FX" append demo plan '=HYPERLINK("http://x")' '+cmd' real.txt '@SUM(A1)'
check "inject-append-ok" "$(rc_is 0)"
ROW=$(sed -n 2p "$(TSV "$FX")")
IFS=$'\t' read -r _ts _ph DEC WHY _ev RES <<< "$ROW"
[[ "$DEC" == "'=HYPERLINK"* ]]; check "equals-neutralized" $?
[[ "$WHY" == "'+cmd" ]]; check "plus-neutralized" $?
[[ "$RES" == "'@SUM(A1)" ]]; check "at-neutralized" $?
L "$FX" append demo plan '-1+1' w real.txt $'multi\tcell\nline'
[[ "$(wc -l < "$(TSV "$FX")" | tr -d ' ')" == 3 ]]; check "newline-flattened-one-row" $?
sed -n 3p "$(TSV "$FX")" | awk -F'\t' '$3=="'"'"'-1+1" && NF==6' | grep -q .; check "minus-neutralized-six-cells" $?

echo
echo "=== (4) secret-shaped strings are redacted ==="
FX=$(build_fixture)
L "$FX" append demo plan "key sk-abcdefghijklmnopqrstuvwx" "password=hunter2 and ghp_abcdefghijklmnopqrstuvwxyz0123" real.txt pass
check "secret-append-ok" "$(rc_is 0)"
! grep -qE 'sk-abcdef|hunter2|ghp_abcdef' "$(TSV "$FX")"; check "secrets-not-on-disk" $?
grep -q 'REDACTED' "$(TSV "$FX")"; check "redaction-marker-present" $?

echo
echo "=== (5) supersede appends, never edits; double-supersede and bad lines refused ==="
FX=$(build_fixture)
L "$FX" append demo wave-1 "wrong call" why real.txt pass
BEFORE=$(sed -n 2p "$(TSV "$FX")")
L "$FX" supersede demo 2 wave-1 "right call" why real.txt pass
check "supersede-ok" "$(rc_is 0)"
[[ "$(sed -n 2p "$(TSV "$FX")")" == "$BEFORE" ]]; check "old-row-untouched" $?
sed -n 3p "$(TSV "$FX")" | awk -F'\t' '$6 ~ /^supersedes:L2/' | grep -q .; check "new-row-points-back" $?
L "$FX" supersede demo 2 wave-1 again why real.txt pass
check "double-supersede-refused" "$(rc_is 3)"
L "$FX" supersede demo 99 wave-1 x why real.txt pass
check "missing-line-refused" "$(rc_is 3)"
L "$FX" supersede demo 1 wave-1 x why real.txt pass
check "header-line-refused" "$(rc_is 2)"

echo
echo "=== (6) check: clean run prints Attention: none ==="
FX=$(build_fixture)
(cd "$FX" && bash core/infra/supervisor-goal.sh init demo 1 >/dev/null && bash core/infra/supervisor-goal.sh advance-wave demo 1 >/dev/null)
mkdir -p "$FX/.agent/plans/demo"; printf '# demo\n- waves: 1/1\n' > "$FX/.agent/plans/demo/RECORD.md"
SHA=$(cd "$FX" && git rev-parse --short HEAD)
L "$FX" append demo wave-1 "ship it" why "$SHA" pass
L "$FX" check demo
has '## Attention'; check "attention-header" $?
has '- none'; check "clean-is-none" $?
check "check-exit-0" "$(rc_is 0)"

echo
echo "=== (7) check: attention items ==="
FX=$(build_fixture)
(cd "$FX" && bash core/infra/supervisor-goal.sh init demo 2 >/dev/null \
  && bash core/infra/supervisor-goal.sh advance-wave demo 1 >/dev/null \
  && bash core/infra/supervisor-goal.sh advance-wave demo 2 >/dev/null \
  && bash core/infra/supervisor-goal.sh agent-spawn demo lingering 2 60 >/dev/null)
L "$FX" check demo
has 'no decision log'; check "no-log-flagged" $?
has 'RECORD.md missing'; check "no-record-flagged" $?
has 'wave 1 is recorded complete but has no decision row'; check "wave-without-decision" $?
has 'agent lingering is still running'; check "open-agent-flagged" $?
mkdir -p "$FX/.agent/plans/demo"; printf 'x <fill — prs>\n' > "$FX/.agent/plans/demo/RECORD.md"
L "$FX" append demo wave-1 "pending thing" why real.txt pending
L "$FX" append demo wave-2 "bad thing" why real.txt fail
L "$FX" append demo wave-2 "ghost evidence" why no/such/file.sh:3 pass
printf "2026-01-01T00:00:00Z\twave-2\thand edited\twhy\tverified\tpass\n" >> "$(TSV "$FX")"
L "$FX" check demo
has 'still pending'; check "pending-flagged" $?
has 'recorded as failed and never superseded'; check "failed-flagged" $?
has 'evidence pointer not found: no/such/file.sh:3'; check "dead-pointer-flagged" $?
has 'evidence is not a valid pointer: verified'; check "invalid-evidence-flagged" $?
has 'unfilled <fill'; check "record-fill-flagged" $?
L "$FX" check demo --strict
check "strict-exits-1" "$(rc_is 1)"
# a superseding row retires the failed one
L "$FX" supersede demo 3 wave-2 "fixed it" why real.txt pass
L "$FX" check demo
! has 'recorded as failed'; check "superseded-fail-no-longer-flagged" $?

echo
echo "=== (8) supervisor-goal.sh complete: Attention on stderr, JSON still last on stdout ==="
FX=$(build_fixture)
(cd "$FX" && bash core/infra/supervisor-goal.sh init demo 1 >/dev/null)
STDOUT=$(cd "$FX" && bash core/infra/supervisor-goal.sh complete demo 2>"$TMP_ROOT/err.txt")
printf '%s\n' "$STDOUT" | tail -1 | jq -e '.status == "complete"' >/dev/null; check "stdout-json-intact" $?
grep -q '## Attention' "$TMP_ROOT/err.txt"; check "attention-on-stderr" $?
! printf '%s' "$STDOUT" | grep -q 'Attention'; check "attention-not-on-stdout" $?

echo
echo "=== (8b) complete on a clean run prints '- none' (no stub noise, no missing-RECORD item) ==="
FX=$(build_fixture)
SHA=$(cd "$FX" && git rev-parse --short HEAD)
(cd "$FX" && bash core/infra/supervisor-goal.sh init demo 1 >/dev/null && bash core/infra/supervisor-goal.sh advance-wave demo 1 >/dev/null)
L "$FX" append demo wave-1 "ship it" why "$SHA" pass
(cd "$FX" && bash core/infra/supervisor-goal.sh complete demo >/dev/null 2>"$TMP_ROOT/err2.txt")
grep -q '^- none$' "$TMP_ROOT/err2.txt"; check "complete-clean-run-is-none" $?
! grep -q 'RECORD.md' "$TMP_ROOT/err2.txt"; check "complete-no-record-noise" $?
[[ -f "$FX/.agent/plans/demo/RECORD.md" ]]; check "complete-still-writes-stub" $?
# a RECORD.md the skill left with unfilled slots is still reported on complete
FX=$(build_fixture)
(cd "$FX" && bash core/infra/supervisor-goal.sh init demo 1 >/dev/null)
mkdir -p "$FX/.agent/plans/demo"; printf '<fill x>\n' > "$FX/.agent/plans/demo/RECORD.md"
(cd "$FX" && bash core/infra/supervisor-goal.sh complete demo >/dev/null 2>"$TMP_ROOT/err3.txt")
grep -q 'unfilled <fill' "$TMP_ROOT/err3.txt"; check "complete-reports-real-unfilled-record" $?

echo
echo "=== (8c) redaction: PEM span, sk_live_, AIza, JWT, URL credentials ==="
FX=$(build_fixture)
PEM=$'-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAabcdef\n-----END RSA PRIVATE KEY-----'
# built at runtime so gitleaks does not flag the fixture itself
SKL="sk_""live_abcdefghijklmnop1234"; JWT="ey""JhbGciOiJIUzI1NiJ9.ey""JzdWIiOiIxMjM0NTY3ODkw.SflKxwRJSMeKKF2QT4fwpM"
L "$FX" append demo plan "key $PEM tail" "$SKL" real.txt pass
L "$FX" append demo plan "AIzaSyA-abcdefghijklmnopqrstuvwxyz012345 x" "$JWT" real.txt pass
L "$FX" append demo plan "clone https://user:s3cr3tpass@example.com/x.git" w real.txt pass
for needle in MIIEowIBAAKC 'END RSA' sk_live_abcdef AIzaSyA-abcdef ey""JhbGciOiJ ey""JzdWIi s3cr3tpass; do
  ! grep -qF -- "$needle" "$(TSV "$FX")"; check "redacted-$needle" $?
done
grep -q 'tail' "$(TSV "$FX")"; check "text-after-pem-kept" $?
grep -q 'example.com' "$(TSV "$FX")"; check "url-host-kept" $?

echo
echo "=== (8d) evidence pointer shapes ==="
FX=$(build_fixture)
for ok in "$SHA" real.txt real.txt:3 real.txt:3-9 core/infra/x pr-12 https://example.com/a/b; do
  L "$FX" append demo plan d w "$ok" pass
  check "pointer-ok-$ok" "$(rc_is 0)"
done
for bad in verified - none done.. 12 abc "a b" ; do
  L "$FX" append demo plan d w "$bad" pass
  check "pointer-rejected-$bad" "$(rc_is 2)"
done

echo
echo "=== (9) bad slug / missing args ==="
FX=$(build_fixture)
L "$FX" append '../escape' plan d w real.txt pass
check "traversal-slug-rejected" "$(rc_is 2)"
L "$FX" append demo plan 'only-three' w
check "short-append-usage" "$(rc_is 2)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
