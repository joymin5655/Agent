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
sed -n '2p' "$F" | grep -qE $'^abc1234\t11\\.0\t42\tkeep\tbaseline run$'; check "row-content" $?

echo
echo "=== (b) second append adds a row; header NOT duplicated (append-only) ==="
bash "$LEDGER" append --file "$F" --commit def5678 --score 10.5 --duration 30 --status discard --desc "regressed silent-drop"
[[ "$(wc -l < "$F" | tr -d ' ')" -eq 3 ]]; check "three-lines-after-second" $?
[[ "$(grep -c $'^commit\t' "$F")" -eq 1 ]]; check "header-once" $?
grep -qE $'^def5678\t10\\.5\t30\tdiscard\t' "$F"; check "keep-and-discard-both-recorded" $?

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
echo "=== (i) crash window self-heal: append landed, witness stale -> next append OK ==="
# Simulates: `>>` append succeeded, process was killed before write_witness
# (P2-4 kills runs on timeout — this window is real). The extra row is an
# append-only EXTENSION of the witnessed prefix, not tampering: the next
# sanctioned append must accept it and refresh the witness, not brick the ledger.
FC="$TMP_ROOT/crash.tsv"
bash "$LEDGER" append --file "$FC" --commit aaa111 --score 3.0 --duration 1 --status keep --desc one
printf 'bbb222\t4.0\t1\tkeep\tcrashed-before-witness\n' >> "$FC"   # landed row, stale witness
bash "$LEDGER" append --file "$FC" --commit ccc333 --score 5.0 --duration 1 --status keep --desc two; rc=$?
[[ $rc -eq 0 ]]; check "stale-witness-extension-accepted" $?
[[ "$(wc -l < "$FC" | tr -d ' ')" -eq 4 ]]; check "all-rows-preserved" $?
w_lines="$(awk '{print $2}' "$FC.witness")"
[[ "$w_lines" -eq 4 ]]; check "witness-healed-to-current" $?
# TRUNCATION is still refused: drop the last row below the witnessed line count
sed -i.bak '$d' "$FC" && rm -f "$FC.bak"
bash "$LEDGER" append --file "$FC" --commit ddd444 --score 6.0 --duration 1 --status keep --desc three 2>"$TMP_ROOT/i.err"; rc=$?
[[ $rc -ne 0 ]]; check "truncation-still-refused" $?
grep -q "truncated" "$TMP_ROOT/i.err"; check "truncation-named" $?

echo
echo "=== (j) witness forgery/bypass refused: want_lines=0, symlink, non-regular (sec C5) ==="
# want_lines=0 forgery: empty-prefix hash pairs with the empty-string sha256, which
# would "match" ANY ledger content — must die, never treat as a valid witness.
FJ="$TMP_ROOT/forge.tsv"
bash "$LEDGER" append --file "$FJ" --commit aaa111 --score 3.0 --duration 1 --status keep --desc one
printf '%s 0\n' "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" > "$FJ.witness"
bash "$LEDGER" append --file "$FJ" --commit bbb222 --score 9.9 --duration 1 --status keep --desc forged 2>"$TMP_ROOT/j.err"; rc=$?
[[ $rc -ne 0 ]]; check "want-lines-0-refused" $?
grep -q "empty prefix" "$TMP_ROOT/j.err"; check "want-lines-0-named" $?
# symlinked witness (e.g. -> /dev/null): the old -f gate skipped the tamper block
# entirely AND write_witness landed in /dev/null — permanent disarm. Must die.
FS="$TMP_ROOT/sym.tsv"
bash "$LEDGER" append --file "$FS" --commit aaa111 --score 3.0 --duration 1 --status keep --desc one
rm -f "$FS.witness"; ln -s /dev/null "$FS.witness"
bash "$LEDGER" append --file "$FS" --commit bbb222 --score 1.0 --duration 1 --status keep --desc two 2>"$TMP_ROOT/j2.err"; rc=$?
[[ $rc -ne 0 ]]; check "symlink-witness-refused" $?
grep -q "symlink" "$TMP_ROOT/j2.err"; check "symlink-witness-named" $?
# symlinked ledger is refused the same way
FS2="$TMP_ROOT/sym2.tsv"
printf 'x\n' > "$TMP_ROOT/elsewhere.txt"; ln -s "$TMP_ROOT/elsewhere.txt" "$FS2"
bash "$LEDGER" append --file "$FS2" --commit aaa111 --score 1.0 --duration 1 --status keep --desc x 2>"$TMP_ROOT/j3.err"; rc=$?
[[ $rc -ne 0 ]]; check "symlink-ledger-refused" $?
# non-regular witness (a directory) is refused
FD="$TMP_ROOT/dirw.tsv"
bash "$LEDGER" append --file "$FD" --commit aaa111 --score 1.0 --duration 1 --status keep --desc x
rm -f "$FD.witness"; mkdir "$FD.witness"
bash "$LEDGER" append --file "$FD" --commit bbb222 --score 1.0 --duration 1 --status keep --desc y 2>"$TMP_ROOT/j4.err"; rc=$?
[[ $rc -ne 0 ]]; check "non-regular-witness-refused" $?

echo
echo "=== (k) extension rows are schema-checked before re-notarization (sec C6) ==="
# A hand-appended row past the CLI (byte-pure append) must NOT be laundered into
# notarized history by the next sanctioned append unless it matches the row schema.
FK="$TMP_ROOT/laundry.tsv"
bash "$LEDGER" append --file "$FK" --commit aaa111 --score 3.0 --duration 1 --status keep --desc one
printf 'not-a-sha\tNaN\t-1\tPROMOTED\tforged\textra\tcols\n' >> "$FK"
bash "$LEDGER" append --file "$FK" --commit bbb222 --score 5.0 --duration 1 --status keep --desc two 2>"$TMP_ROOT/k.err"; rc=$?
[[ $rc -ne 0 ]]; check "forged-extension-row-refused" $?
grep -q "row schema" "$TMP_ROOT/k.err"; check "forged-extension-named" $?
# a schema-VALID extension row is still accepted (crash-window self-heal intact —
# section (i) proves the positive path; this asserts the refusal did not overreach)
FK2="$TMP_ROOT/laundry2.tsv"
bash "$LEDGER" append --file "$FK2" --commit aaa111 --score 3.0 --duration 1 --status keep --desc one
printf 'bbb222\t4.0\t1\tdiscard\tvalid-crash-row\n' >> "$FK2"
bash "$LEDGER" append --file "$FK2" --commit ccc333 --score 5.0 --duration 1 --status keep --desc two; rc=$?
[[ $rc -eq 0 ]]; check "valid-extension-still-accepted" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
