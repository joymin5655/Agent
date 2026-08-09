#!/usr/bin/env bash
# loop-ledger-test.sh — battery for core/infra/loop-ledger.sh (P2-3).
#
# Verifies the results ledger is append-only, has the 5-column schema, validates its
# inputs (status enum, numeric score/duration — no silent coercion), sanitizes free
# text, and records both keep and discard rows (the backlog's dry-run condition).
#
# Usage: bash core/tests/loop-ledger-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER="$REPO_ROOT/core/infra/loop-ledger.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

F="$TMP_ROOT/results.tsv"

echo "=== (a) first append creates file with header + one data row ==="
bash "$LEDGER" append --file "$F" --commit abc1234 --score 11.0 --duration 42 --status keep --desc "baseline run"; rc=$?
[[ $rc -eq 0 ]]; check "append-exit-0" $?
[[ -f "$F" ]]; check "file-created" $?
head -n1 "$F" | grep -qxF $'commit\tharness_score\tduration_s\tstatus\tdescription'; check "header-schema" $?
[[ "$(wc -l < "$F" | tr -d ' ')" -eq 2 ]]; check "one-header-one-row" $?
sed -n '2p' "$F" | grep -qE '^abc1234\t11\.0\t42\tkeep\tbaseline run$'; check "row-content" $?

echo
echo "=== (b) second append adds a row; header NOT duplicated (append-only) ==="
bash "$LEDGER" append --file "$F" --commit def5678 --score 10.5 --duration 30 --status discard --desc "regressed silent-drop"
[[ "$(wc -l < "$F" | tr -d ' ')" -eq 3 ]]; check "three-lines-after-second" $?
[[ "$(grep -c $'^commit\t' "$F")" -eq 1 ]]; check "header-once" $?
grep -qE '^def5678\t10\.5\t30\tdiscard\t' "$F"; check "keep-and-discard-both-recorded" $?

echo
echo "=== (c) status enum enforced (no silent accept of a bad status) ==="
bash "$LEDGER" append --file "$F" --score 1.0 --duration 1 --status bogus --desc x 2>/dev/null; rc=$?
[[ $rc -ne 0 ]]; check "bad-status-rejected" $?
[[ "$(wc -l < "$F" | tr -d ' ')" -eq 3 ]]; check "bad-status-no-write" $?

echo
echo "=== (d) numeric validation: score and duration are not silently coerced ==="
bash "$LEDGER" append --file "$F" --score "8.x" --duration 1 --status keep --desc x 2>/dev/null; rc=$?
[[ $rc -ne 0 ]]; check "non-numeric-score-rejected" $?
bash "$LEDGER" append --file "$F" --score 8.0 --duration "1.5" --status keep --desc x 2>/dev/null; rc=$?
[[ $rc -ne 0 ]]; check "non-integer-duration-rejected" $?

echo
echo "=== (e) missing --score is an error ==="
bash "$LEDGER" append --file "$TMP_ROOT/x.tsv" --duration 1 --status keep --desc x 2>/dev/null; rc=$?
[[ $rc -ne 0 ]]; check "missing-score-error" $?

echo
echo "=== (f) description sanitized: tabs/newlines stripped, capped at 80 chars ==="
F2="$TMP_ROOT/r2.tsv"
long="$(printf 'a%.0s' $(seq 1 200))"
bash "$LEDGER" append --file "$F2" --commit c --score 1.0 --duration 1 --status crash \
  --desc "$(printf 'tab\there\nnewline')"
sed -n '2p' "$F2" | grep -qvE $'\t.*\t.*\t.*\t.*\t'; check "no-extra-tab-columns" $?  # exactly 5 cols
bash "$LEDGER" append --file "$F2" --commit c2 --score 1.0 --duration 1 --status timeout --desc "$long"
desc_field="$(sed -n '3p' "$F2" | cut -f5)"
[[ "${#desc_field}" -le 80 ]]; check "desc-capped-80" $?

echo
echo "=== (g) 'path' subcommand prints a ledger path under .agent/loop/ ==="
AGENT_LOOP_LEDGER="$TMP_ROOT/custom.tsv" bash "$LEDGER" path | grep -qxF "$TMP_ROOT/custom.tsv"; check "path-honors-seam" $?
bash "$LEDGER" path | grep -qE '\.agent/loop/results\.tsv$'; check "default-path-shape" $?

echo
echo "=== (h) tamper evidence: witness written; delete-recreate and rewrite REFUSED ==="
FW="$TMP_ROOT/w.tsv"
bash "$LEDGER" append --file "$FW" --commit abc123 --score 9.0 --duration 3 --status keep --desc first
[[ -s "$FW.witness" ]]; check "witness-created-on-append" $?
# witness matches the ledger it notarizes (recompute)
w_sha="$(awk '{print $1}' "$FW.witness")"
have="$( (shasum -a 256 "$FW" 2>/dev/null || sha256sum "$FW") | awk '{print $1}')"
[[ -n "$w_sha" && "$w_sha" == "$have" ]]; check "witness-matches-ledger" $?
# delete-recreate: ledger gone, witness survives -> append must REFUSE, not re-header
rm -f "$FW"
bash "$LEDGER" append --file "$FW" --commit def456 --score 1.0 --duration 1 --status keep --desc recreated 2>"$TMP_ROOT/h.err"; rc=$?
[[ $rc -ne 0 ]]; check "delete-recreate-refused" $?
grep -q "delete-recreate" "$TMP_ROOT/h.err"; check "delete-recreate-named" $?
[[ ! -e "$FW" ]]; check "refused-append-writes-nothing" $?
# rewrite/truncate: restore a DIFFERENT ledger under the old witness -> refuse
printf 'commit\tharness_score\tduration_s\tstatus\tdescription\nfff\t9.9\t1\tkeep\tforged\n' > "$FW"
bash "$LEDGER" append --file "$FW" --commit abc999 --score 2.0 --duration 1 --status keep --desc after-forge 2>"$TMP_ROOT/h2.err"; rc=$?
[[ $rc -ne 0 ]]; check "rewritten-ledger-refused" $?
grep -q "witness" "$TMP_ROOT/h2.err"; check "rewrite-refusal-cites-witness" $?
# legacy adopt: pre-witness ledger (no witness file) -> append succeeds, witness starts
FL="$TMP_ROOT/legacy.tsv"
printf 'commit\tharness_score\tduration_s\tstatus\tdescription\naaa\t5.0\t1\tkeep\told\n' > "$FL"
bash "$LEDGER" append --file "$FL" --commit bbb --score 6.0 --duration 1 --status keep --desc new; rc=$?
[[ $rc -eq 0 && -s "$FL.witness" && "$(wc -l < "$FL" | tr -d ' ')" -eq 3 ]]; check "legacy-ledger-adopted" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
