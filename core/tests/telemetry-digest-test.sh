#!/usr/bin/env bash
# telemetry-digest-test.sh — verify core/infra/telemetry-digest.sh (P1-5, revised spec).
#
# Feeds a synthetic supervisor.jsonl fixture (never the real .agent/logs/supervisor.jsonl)
# to the digest script via a positional path arg and asserts the rendered report.
#
# Fixture covers every action type + one malformed line + one record outside the
# default 30-day window:
#   code-reviewer:    1 match (keyword "review this diff") + 1 ask-intent + 1 dispatched
#                     (ask=1 < 3, must NOT trigger NO-ACCEPT)
#   never-dispatched: 1 match (keyword "foo bar") + 3 ask-intent + 0 dispatched
#                     (ask=3 >= 3, dispatched=0 -> NO-ACCEPT candidate)
#   phantom-agent:    1 match (keyword "foo bar") + 1 ghost -> GHOST candidate
#   keyword-magnet:   8 match, all keyword "generic term" -> 8/11 (~73%) of all matches
#                     -> OVER-GENERAL candidate (total matches 11 >= min-sample 3)
#   old-specialist:   1 ask-intent dated 40 days ago (default window is 30 days)
#                     -> must be excluded entirely from all counts/candidates
#   + 1 line of garbage (not valid JSON) -> counted as skipped, never fatal
#
# Covers: (a) action-count table accuracy, (b) specialist funnel conversion notation,
# (c) NO-ACCEPT rule candidate, (d) GHOST rule candidate, (e) malformed-line skip count
# reported, (f) window filter excludes the old record, (g) missing log file -> exit 0 +
# inactive message, (h) --json output is valid, parseable JSON.
#
# Usage: bash core/tests/telemetry-digest-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/telemetry-digest.sh"

PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then
    echo "  ok   [$name]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name]"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Timestamps generated via python3 (never bash `date`, to stay portable across
# BSD date on macOS and GNU date on Linux — this repo runs on both).
NOW_TS="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat())')"
OLD_TS="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)).isoformat())')"

SAMPLE="$TMP_DIR/sample.jsonl"
{
  printf '{"ts":"%s","event":"UserPromptSubmit","session_id":"s1","action":"match","specialist":"code-reviewer","keyword":"review this diff"}\n' "$NOW_TS"
  printf '{"ts":"%s","event":"PreToolUse","session_id":"s1","action":"ask-intent","specialist":"code-reviewer"}\n' "$NOW_TS"
  printf '{"ts":"%s","event":"PostToolUse","session_id":"s1","action":"dispatched","specialist":"code-reviewer"}\n' "$NOW_TS"

  printf '{"ts":"%s","event":"UserPromptSubmit","session_id":"s2","action":"match","specialist":"never-dispatched","keyword":"foo bar"}\n' "$NOW_TS"
  printf '{"ts":"%s","event":"PreToolUse","session_id":"s2","action":"ask-intent","specialist":"never-dispatched"}\n' "$NOW_TS"
  printf '{"ts":"%s","event":"PreToolUse","session_id":"s3","action":"ask-intent","specialist":"never-dispatched"}\n' "$NOW_TS"
  printf '{"ts":"%s","event":"PreToolUse","session_id":"s4","action":"ask-intent","specialist":"never-dispatched"}\n' "$NOW_TS"

  printf '{"ts":"%s","event":"UserPromptSubmit","session_id":"s5","action":"match","specialist":"phantom-agent","keyword":"foo bar"}\n' "$NOW_TS"
  printf '{"ts":"%s","event":"UserPromptSubmit","session_id":"s5","action":"ghost","specialist":"phantom-agent","keyword":"foo bar"}\n' "$NOW_TS"

  for i in 1 2 3 4 5 6 7 8; do
    printf '{"ts":"%s","event":"UserPromptSubmit","session_id":"s6-%s","action":"match","specialist":"keyword-magnet","keyword":"generic term"}\n' "$NOW_TS" "$i"
  done

  printf '{"ts":"%s","event":"PreToolUse","session_id":"s7","action":"ask-intent","specialist":"old-specialist"}\n' "$OLD_TS"

  # Legacy v0.1 stub-format record: valid JSON object, but no action/specialist
  # fields at all (the real pre-P1-4 log is full of these). Must land in the
  # "unknown" bucket — never skipped, never a rule candidate.
  printf '{"ts":"%s","event":"PreToolUse","tool_name":"Edit","intent":"","session_id":"legacy1"}\n' "$NOW_TS"

  echo '{ this is not valid json ]'
} > "$SAMPLE"

echo "=== (a) action-count table accuracy ==="
OUT_A="$(bash "$SCRIPT" "$SAMPLE" 2>&1)"
RC_A=$?
[[ $RC_A -eq 0 ]]
check "exit-0-sample" $?
[[ "$OUT_A" == *"match: 11"* ]]
check "action-count-match" $?
[[ "$OUT_A" == *"ask-intent: 4"* ]]
check "action-count-ask-intent" $?
[[ "$OUT_A" == *"dispatched: 1"* ]]
check "action-count-dispatched" $?
[[ "$OUT_A" == *"ghost: 1"* ]]
check "action-count-ghost" $?

echo
echo "=== (b) specialist funnel notation (match -> ask -> dispatched) ==="
[[ "$OUT_A" == *"code-reviewer"* && "$OUT_A" == *"match=1"* && "$OUT_A" == *"ask=1"* && "$OUT_A" == *"dispatched=1"* ]]
check "funnel-code-reviewer" $?
[[ "$OUT_A" == *"never-dispatched"* && "$OUT_A" == *"ask=3"* ]]
check "funnel-never-dispatched" $?

echo
echo "=== (c) NO-ACCEPT rule candidate (asked>=3, dispatched=0) ==="
[[ "$OUT_A" == *"NO-ACCEPT"* && "$OUT_A" == *"never-dispatched"* ]]
check "rule-candidate-no-accept" $?
if [[ "$OUT_A" == *"NO-ACCEPT"*"code-reviewer"* ]]; then
  check "code-reviewer-not-flagged-no-accept" 1
else
  check "code-reviewer-not-flagged-no-accept" 0
fi

echo
echo "=== (d) GHOST rule candidate ==="
[[ "$OUT_A" == *"GHOST"* && "$OUT_A" == *"phantom-agent"* ]]
check "rule-candidate-ghost" $?

echo
echo "=== also: OVER-GENERAL keyword concentration candidate (8/11 ~73% > 70%) ==="
[[ "$OUT_A" == *"OVER-GENERAL"* && "$OUT_A" == *"generic term"* ]]
check "rule-candidate-over-general" $?

echo
echo "=== (e) malformed line is skipped, count reported ==="
[[ "$OUT_A" == *"skipped"*"1"* || "$OUT_A" == *"1"*"skipped"* ]]
check "malformed-line-skip-count-reported" $?

echo
echo "=== (f) window filter excludes the 40-day-old record ==="
if [[ "$OUT_A" == *"old-specialist"* ]]; then
  check "old-record-excluded-from-funnel" 1
else
  check "old-record-excluded-from-funnel" 0
fi
# Total ask-intent count must be 4 (code-reviewer=1 + never-dispatched=3), NOT 5 —
# proves the old-specialist's ask-intent didn't leak into the in-window stats.
[[ "$OUT_A" == *"ask-intent: 4"* ]]
check "window-filter-excludes-old-record-from-counts" $?

echo
echo "=== legacy v0.1 record (object without action field) -> unknown bucket, no candidate ==="
[[ "$OUT_A" == *"unknown: 1"* ]]
check "legacy-record-lands-in-unknown-bucket" $?
# Still exactly 1 skipped line (the garbage one) — the legacy record is valid JSON.
[[ "$OUT_A" == *"skipped malformed: 1"* ]]
check "legacy-record-not-counted-as-skipped" $?
# And it must not surface as any rule candidate.
if [[ "$OUT_A" == *"legacy1"* ]]; then
  check "legacy-record-no-rule-candidate" 1
else
  check "legacy-record-no-rule-candidate" 0
fi

echo
echo "=== (g) missing log file -> exit 0, inactive message ==="
OUT_G="$(bash "$SCRIPT" "$TMP_DIR/no-such-file.jsonl" 2>&1)"
RC_G=$?
[[ $RC_G -eq 0 ]]
check "exit-0-missing-log" $?
[[ "$OUT_G" == *"미가동"* || "$OUT_G" == *"inactive"* || "$OUT_G" == *"--doctor"* ]]
check "missing-log-inactive-message" $?

echo
echo "=== (h) --json output is valid, parseable JSON ==="
OUT_H="$(bash "$SCRIPT" "$SAMPLE" --json 2>&1)"
RC_H=$?
[[ $RC_H -eq 0 ]]
check "exit-0-json-mode" $?
printf '%s' "$OUT_H" | python3 -c "import json,sys; json.loads(sys.stdin.read())" >/dev/null 2>&1
check "json-output-parses" $?

echo
echo "=== (i) --gates mode: DEAD / FATIGUE / STALE / UNINSTRUMENTED classification ==="
# A tiny synthetic registry + logs dir. Four gates, one of each class:
#   fresh-hot   -> security-violations.jsonl, 3 in-window firings, fatigue=2  -> FATIGUE
#   fresh-cold  -> security-violations.jsonl, 0 firings                       -> DEAD
#   old-ok      -> security-violations.jsonl, 1 firing, reviewed 200d ago     -> STALE
#   no-log      -> sink '-'                                                    -> UNINSTRUMENTED
GATE_DIR="$TMP_DIR/gates"
mkdir -p "$GATE_DIR/logs"
OLD_REVIEW="$(python3 -c 'import datetime; print((datetime.date.today() - datetime.timedelta(days=200)).isoformat())')"
NEW_REVIEW="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
cat > "$GATE_DIR/registry.md" <<EOF
# fixture registry
<!-- gate-registry:begin -->
GATE fresh-hot | h.sh | ask | security-violations.jsonl | fresh-hot | $NEW_REVIEW | assumes a hot failure mode.
GATE fresh-cold | h.sh | deny | security-violations.jsonl | fresh-cold | $NEW_REVIEW | assumes an extinct failure mode.
GATE old-ok | h.sh | ask | security-violations.jsonl | old-ok | $OLD_REVIEW | assumes a rare but real failure mode.
GATE no-log | h.py | deny | - | * | $NEW_REVIEW | emits a decision but writes no log.
<!-- gate-registry:end -->
EOF
# firing log: 3 fresh-hot (in-window), 1 old-ok, 1 reproduce_test fresh-hot (must be IGNORED)
{
  printf '{"ts":"%s","guard":"fresh-hot","reproduce_test":false}\n' "$NOW_TS"
  printf '{"ts":"%s","guard":"fresh-hot","reproduce_test":false}\n' "$NOW_TS"
  printf '{"ts":"%s","guard":"fresh-hot","reproduce_test":false}\n' "$NOW_TS"
  printf '{"ts":"%s","guard":"fresh-hot","reproduce_test":true}\n'  "$NOW_TS"
  printf '{"ts":"%s","guard":"old-ok","reproduce_test":false}\n'    "$NOW_TS"
} > "$GATE_DIR/logs/security-violations.jsonl"

OUT_I="$(bash "$SCRIPT" --gates --registry "$GATE_DIR/registry.md" --logs-dir "$GATE_DIR/logs" --fatigue 2 --stale-days 90 --json 2>&1)"
RC_I=$?
[[ $RC_I -eq 0 ]]; check "gates-exit-0" $?
printf '%s' "$OUT_I" | python3 -c "import json,sys; json.loads(sys.stdin.read())" >/dev/null 2>&1
check "gates-json-parses" $?
# fresh-hot fired == 3 (reproduce_test line excluded)
printf '%s' "$OUT_I" | python3 -c "import json,sys; d=json.load(sys.stdin); r={x['id']:x for x in d['reports']}; sys.exit(0 if r['fresh-hot']['fired']==3 else 1)"
check "gates-reproduce-test-excluded" $?
printf '%s' "$OUT_I" | python3 -c "import json,sys; d=json.load(sys.stdin); r={x['id']:x for x in d['reports']}; sys.exit(0 if 'FATIGUE' in r['fresh-hot']['flags'] else 1)"
check "gates-fatigue-flagged" $?
printf '%s' "$OUT_I" | python3 -c "import json,sys; d=json.load(sys.stdin); r={x['id']:x for x in d['reports']}; sys.exit(0 if 'DEAD' in r['fresh-cold']['flags'] else 1)"
check "gates-dead-flagged" $?
printf '%s' "$OUT_I" | python3 -c "import json,sys; d=json.load(sys.stdin); r={x['id']:x for x in d['reports']}; sys.exit(0 if 'STALE' in r['old-ok']['flags'] else 1)"
check "gates-stale-flagged" $?
printf '%s' "$OUT_I" | python3 -c "import json,sys; d=json.load(sys.stdin); r={x['id']:x for x in d['reports']}; sys.exit(0 if r['no-log']['flags']==['UNINSTRUMENTED'] else 1)"
check "gates-uninstrumented-flagged" $?
# old-ok is STALE but NOT dead (it fired once) — STALE and DEAD are independent axes
printf '%s' "$OUT_I" | python3 -c "import json,sys; d=json.load(sys.stdin); r={x['id']:x for x in d['reports']}; sys.exit(0 if 'DEAD' not in r['old-ok']['flags'] else 1)"
check "gates-stale-not-dead" $?

echo
echo "=== (j) --gates human mode: summary line + missing registry fail-safe ==="
OUT_J="$(bash "$SCRIPT" --gates --registry "$GATE_DIR/registry.md" --logs-dir "$GATE_DIR/logs" --fatigue 2 2>&1)"
[[ "$OUT_J" == *"gate-digest: 4 gate(s)"* ]]; check "gates-human-summary" $?
# missing registry -> still exit 0, 0 gates, no crash (observer contract)
OUT_J2="$(bash "$SCRIPT" --gates --registry "$GATE_DIR/nonexistent.md" --logs-dir "$GATE_DIR/logs" 2>&1)"
RC_J2=$?
[[ $RC_J2 -eq 0 ]]; check "gates-missing-registry-exit-0" $?
[[ "$OUT_J2" == *"gate-digest: 0 gate(s)"* || "$OUT_J2" == *"registry error"* ]]; check "gates-missing-registry-reported" $?
# the SHIPPED registry parses to a non-zero gate count (real-file smoke)
OUT_J3="$(bash "$SCRIPT" --gates 2>&1)"
[[ "$OUT_J3" == *"gate-digest: "* ]] && ! [[ "$OUT_J3" == *"gate-digest: 0 gate(s)"* ]]
check "shipped-registry-parses-nonzero" $?

echo
echo "=== (k) --gates: a traversal sink is confined to logs-dir (never reads outside) ==="
# A registry line whose sink escapes logs_dir with ../ must not read that file.
# Plant a would-be-counted record OUTSIDE logs_dir; the gate must report fired=n/a
# (DEAD, sink treated as absent), not the outside count.
TRAV_DIR="$TMP_DIR/trav"
mkdir -p "$TRAV_DIR/logs"
printf '{"ts":"%s","guard":"escapee","reproduce_test":false}\n' "$NOW_TS" > "$TRAV_DIR/outside.jsonl"
cat > "$TRAV_DIR/registry.md" <<EOF
<!-- gate-registry:begin -->
GATE escapee | h.sh | deny | ../outside.jsonl | escapee | $NEW_REVIEW | traversal sink.
<!-- gate-registry:end -->
EOF
OUT_K="$(bash "$SCRIPT" --gates --registry "$TRAV_DIR/registry.md" --logs-dir "$TRAV_DIR/logs" --json 2>&1)"
printf '%s' "$OUT_K" | python3 -c "import json,sys; d=json.load(sys.stdin); r=d['reports'][0]; sys.exit(0 if (r['fired'] in (0,None)) and 'DEAD' in r['flags'] else 1)"
check "traversal-sink-not-read" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
