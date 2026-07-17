#!/usr/bin/env bash
# manager-audit-test.sh — verify core/infra/manager-audit.sh (four meta-audit lanes).
#
# Fixture-driven: fake routing/audit JSONL, plan dir, and artifacts dir are
# injected through the script's env seams; no real logs or DB are touched.
# Contract under test: findings shape {lane, check, severity, evidence,
# proposal_hint}, per-lane detection, --json envelope, and ALWAYS exit 0
# (the audit reports; it never blocks).
#
# Usage: bash core/tests/manager-audit-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/manager-audit.sh"

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

PLANS="$WORK/plans"          # plan .md files
ARTS="$WORK/artifacts"       # .agent/plans/<slug>/ equivalents
LOGS="$WORK/logs"
mkdir -p "$PLANS" "$ARTS/good" "$ARTS/bad" "$LOGS"

REG="$WORK/registry.json"
cat > "$REG" <<'EOF'
{"agents": [{"id": "code-reviewer", "model": "sonnet"}, {"id": "security-reviewer", "model": "opus"}]}
EOF

run() { # run <slug> [extra args...] -> OUT, RC (always --json for assertions)
    local slug="$1"; shift
    OUT="$(env \
        AGENT_MODEL_ROUTING_SINK="$LOGS/routing.jsonl" \
        AGENT_GOAL_AUDIT_LOG="$LOGS/goal-audit.jsonl" \
        AGENT_PLANS_DIR="$PLANS" \
        AGENT_PLAN_ARTIFACTS_DIR="$ARTS" \
        AGENT_GOAL_DB="$WORK/absent.db" \
        AGENT_REGISTRY_PATH="$REG" \
        bash "$SCRIPT" "$slug" --json "$@" 2>/dev/null)"
    RC=$?
}
has_finding() { # has_finding <lane> <check> <severity>
    jq -e --arg l "$1" --arg c "$2" --arg s "$3" \
        '[.findings[] | select(.lane==$l and .check==$c and .severity==$s)] | length > 0' \
        <<< "$OUT" >/dev/null 2>&1
}

# ---------- fixtures ----------

# plan: 2 waves, code-touching
cat > "$PLANS/good.md" <<'EOF'
# Plan: good

## Wave 1: extend the observer script
- edit core/hooks/example.py → verify: bash core/tests/example-test.sh

## Wave 2: document the observer change
- edit docs/example.md → verify: grep -q observer docs/example.md
EOF
cp "$PLANS/good.md" "$PLANS/bad.md"

# restatement: complete for good/, absent for bad/
cat > "$ARTS/good/RESTATEMENT.md" <<'EOF'
## Original ask

Extend the observer script and document the change.

## Interpreted goal

Extend the observer script in core/hooks/ and document the observer change in docs/.

## Assumptions

- None

## Out of scope

- No new hooks are added.

## Success criteria (measurable)

- bash core/tests/example-test.sh exits 0

## Open questions

None
EOF
touch "$ARTS/good/RECORD.md"

# routing log: healthy mix for good; leaks/violations exercised via same file
cat > "$LOGS/routing.jsonl" <<'EOF'
{"gate":"model-routing-observer","subagent_type":"executor","model":"sonnet","verdict":"override","prompt_chars":400,"total_tokens":1000,"session_id":"s1","wave_hint":1,"ts":"2026-07-17T01:00:00Z"}
{"gate":"model-routing-observer","subagent_type":"code-reviewer","model":"","verdict":"pinned_specialist","prompt_chars":200,"total_tokens":500,"session_id":"s1","ts":"2026-07-17T01:05:00Z"}
{"gate":"model-routing-observer","subagent_type":"Explore","model":"","verdict":"inherit_top","prompt_chars":800,"total_tokens":null,"session_id":"s1","ts":"2026-07-17T01:10:00Z"}
{"gate":"model-routing-observer","subagent_type":"verify-worker","model":"haiku","verdict":"override","prompt_chars":100,"total_tokens":300,"session_id":"s1","ts":"2026-07-17T01:15:00Z"}
{"gate":"model-routing-observer","subagent_type":"fanout-worker","model":"opus","verdict":"override","prompt_chars":50,"total_tokens":9000,"session_id":"s1","ts":"2026-07-17T01:20:00Z"}
{"gate":"model-routing-observer","subagent_type":"fanout-worker","model":"opus","verdict":"override","prompt_chars":50,"total_tokens":9000,"session_id":"s1","ts":"2026-07-17T01:21:00Z"}
{"gate":"model-routing-observer","subagent_type":"fanout-worker","model":"opus","verdict":"override","prompt_chars":50,"total_tokens":9000,"session_id":"s1","ts":"2026-07-17T01:22:00Z"}
{"gate":"other-gate","subagent_type":"noise","model":"","verdict":"inherit_top","session_id":"s1","ts":"2026-07-17T01:23:00Z"}
{"gate":"model-routing-observer","subagent_type":"other-session","model":"","verdict":"inherit_top","prompt_chars":10,"session_id":"s2","ts":"2026-07-17T01:24:00Z"}
{"gate":"model-routing-observer","subagent_type":"mixed-worker","model":"sonnet","verdict":"override","prompt_chars":20,"total_tokens":50,"session_id":"s1","ts":"2026-07-17T01:25:00Z"}
{"gate":"model-routing-observer","subagent_type":"mixed-worker","model":"opus","verdict":"override","prompt_chars":20,"total_tokens":50,"session_id":"s1","ts":"2026-07-17T01:26:00Z"}
{"gate":"model-routing-observer","subagent_type":"mixed-worker","model":"opus","verdict":"override","prompt_chars":20,"total_tokens":50,"session_id":"s1","ts":"2026-07-17T01:27:00Z"}
{"gate":"model-routing-observer","subagent_type":"Explore","model":"sonnet","verdict":"override","prompt_chars":30,"total_tokens":60,"session_id":"s1","ts":"2026-07-17T01:28:00Z"}
{"gate":"model-routing-observer","subagent_type":"Explore","model":"sonnet","verdict":"override","prompt_chars":30,"total_tokens":60,"session_id":"s1","ts":"2026-07-17T01:29:00Z"}
EOF

# goal-audit log: wave 1 audited PASS for good; wave 2 missing.
# For slug "retry": wave 1 FAILed, wave 2 ran anyway.
cat > "$LOGS/goal-audit.jsonl" <<'EOF'
{"ts":"2026-07-17T01:30:00Z","plan_slug":"good","wave":1,"all_pass":true,"verdict":"strong"}
{"ts":"2026-07-17T01:31:00Z","plan_slug":"good","wave":1,"mode":"score-only","verdict":"strong"}
{"ts":"2026-07-17T01:32:00Z","plan_slug":"retry","wave":1,"all_pass":false,"verdict":"mixed"}
{"ts":"2026-07-17T01:33:00Z","plan_slug":"retry","wave":2,"all_pass":true,"verdict":"strong"}
{"ts":"2026-07-17T01:34:00Z","plan_slug":"remedy","wave":1,"all_pass":false,"verdict":"mixed"}
{"ts":"2026-07-17T01:35:00Z","plan_slug":"remedy","wave":1,"all_pass":true,"verdict":"strong"}
{"ts":"2026-07-17T01:36:00Z","plan_slug":"remedy","wave":2,"all_pass":true,"verdict":"strong"}
EOF
cp "$PLANS/good.md" "$PLANS/retry.md"
cp "$PLANS/good.md" "$PLANS/remedy.md"

echo "=== contract: --json envelope, exit 0 always ==="
run good
if [[ "$RC" -eq 0 ]]; then ok "j1-exit-0"; else bad "j1-exit-0" "rc=$RC"; fi
if jq -e '.plan_slug == "good" and (.findings | type == "array")' <<< "$OUT" >/dev/null 2>&1; then
    ok "j2-envelope-shape"
else bad "j2-envelope" "$OUT"; fi
if jq -e '.findings[0] | has("lane") and has("check") and has("severity") and has("evidence") and has("proposal_hint")' <<< "$OUT" >/dev/null 2>&1; then
    ok "j3-finding-fields"
else bad "j3-finding-fields" "$(jq -c '.findings[0]' <<< "$OUT")"; fi
run nonexistent-slug
if [[ "$RC" -eq 0 ]]; then ok "j4-unknown-slug-exit-0"; else bad "j4-unknown-slug" "rc=$RC"; fi
run "../evil'; DROP TABLE x;--"
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then ok "j5-unsafe-slug-rejected-cleanly"; else bad "j5-unsafe-slug" "rc=$RC out=$OUT"; fi

echo
echo "=== lane: restatement-quality ==="
run good --session s1
if ! has_finding restatement-quality restatement-missing FAIL; then ok "r1-present-not-flagged"; else bad "r1" "flagged present file"; fi
run bad
if has_finding restatement-quality restatement-missing FAIL; then ok "r2-missing-is-FAIL"; else bad "r2" "$OUT"; fi
# empty/placeholder section fixture
mkdir -p "$ARTS/hollow"
sed 's/^Extend the observer script and document.*$/<placeholder>/' "$ARTS/good/RESTATEMENT.md" > "$ARTS/hollow/RESTATEMENT.md"
cp "$PLANS/good.md" "$PLANS/hollow.md"
run hollow
if has_finding restatement-quality section-empty WARN; then ok "r3-placeholder-section-WARN"; else bad "r3" "$OUT"; fi
# non-measurable criteria fixture
mkdir -p "$ARTS/vague"
sed 's/^- bash core.*$/- it works well and feels fast/' "$ARTS/good/RESTATEMENT.md" > "$ARTS/vague/RESTATEMENT.md"
cp "$PLANS/good.md" "$PLANS/vague.md"
run vague
if has_finding restatement-quality criteria-not-measurable WARN; then ok "r4-vague-criteria-WARN"; else bad "r4" "$OUT"; fi
# scope-drift fixture: plan wave about something the restatement never mentions
mkdir -p "$ARTS/drift"
cp "$ARTS/good/RESTATEMENT.md" "$ARTS/drift/RESTATEMENT.md"
{ cat "$PLANS/good.md"; printf '\n## Wave 3: migrate billing pipeline\n- unrelated\n'; } > "$PLANS/drift.md"
run drift
if has_finding restatement-quality scope-drift-candidate WARN; then ok "r5-scope-drift-WARN"; else bad "r5" "$OUT"; fi
# whitespace-only section must count as empty (BSD grep has no \s class)
mkdir -p "$ARTS/blankish"
awk '{print} /^## Assumptions$/{print "   "; skip=2} skip>0 && !/^## Assumptions$/{skip--; next}' \
    "$ARTS/good/RESTATEMENT.md" | grep -v '^- None$' > "$ARTS/blankish/RESTATEMENT.md"
cp "$PLANS/good.md" "$PLANS/blankish.md"
run blankish
if has_finding restatement-quality section-empty WARN; then ok "r6-whitespace-only-section-WARN"; else bad "r6" "$OUT"; fi
# non-ASCII wave title: word extraction strips it — whole-title fallback, no false flag
mkdir -p "$ARTS/hangul"
{ cat "$ARTS/good/RESTATEMENT.md"; printf '\n관측 훅 확장 작업이 목표에 포함된다.\n'; } > "$ARTS/hangul/RESTATEMENT.md"
{ cat "$PLANS/good.md"; printf '\n## Wave 3: 관측 훅 확장\n- edit core/hooks/example.py\n'; } > "$PLANS/hangul.md"
run hangul
if ! has_finding restatement-quality scope-drift-candidate WARN; then
    ok "r7-nonascii-title-fallback-no-false-flag"
else bad "r7" "$(jq -c '.findings[] | select(.check=="scope-drift-candidate")' <<< "$OUT")"; fi

echo
echo "=== lane: routing-waste (session-filtered) ==="
run good --session s1
if has_finding routing-waste top-inherit-leak WARN; then ok "w1-inherit-top-leak-WARN"; else bad "w1" "$OUT"; fi
if jq -e '.findings[] | select(.check=="top-inherit-leak") | .evidence | contains("Explore") and (contains("other-session") | not)' <<< "$OUT" >/dev/null 2>&1; then
    ok "w2-session-filter-applied"
else bad "w2-session-filter" "$(jq -c '.findings[] | select(.check=="top-inherit-leak")' <<< "$OUT")"; fi
if has_finding routing-waste verify-floor-violation FAIL; then ok "w3-verify-below-MID-FAIL"; else bad "w3" "$OUT"; fi
if has_finding routing-waste fanout-not-low WARN; then ok "w4-fanout-not-low-WARN"; else bad "w4" "$OUT"; fi
if jq -e '.findings[] | select(.check=="fanout-not-low") | .evidence | select(contains("mixed-worker")) | contains("MID/TOP")' <<< "$OUT" >/dev/null 2>&1; then
    ok "w5-mixed-tier-batch-reported-accurately"
else bad "w5-mixed-tier" "$(jq -c '.findings[] | select(.check=="fanout-not-low")' <<< "$OUT")"; fi
# Explore-at-MID is a documented fan-out exception (docs/model-routing.md) — never flagged
if ! jq -e '.findings[] | select(.check=="fanout-not-low") | .evidence | contains("Explore")' <<< "$OUT" >/dev/null 2>&1; then
    ok "w7-explore-mid-exception-not-flagged"
else bad "w7-explore-mid" "$(jq -c '.findings[] | select(.check=="fanout-not-low")' <<< "$OUT")"; fi
# --since scopes the routing window: records before the ts drop out
run good --session s1 --since 2026-07-17T01:25:00Z
if ! has_finding routing-waste top-inherit-leak WARN; then
    ok "w8-since-window-excludes-old-records"
else bad "w8-since" "$(jq -c '.findings[] | select(.check=="top-inherit-leak")' <<< "$OUT")"; fi
# arg-parse regression: trailing --session with no value must terminate, not loop
( env AGENT_MODEL_ROUTING_SINK="$LOGS/routing.jsonl" AGENT_GOAL_AUDIT_LOG="$LOGS/goal-audit.jsonl" \
      AGENT_PLANS_DIR="$PLANS" AGENT_PLAN_ARTIFACTS_DIR="$ARTS" AGENT_GOAL_DB="$WORK/absent.db" \
      AGENT_REGISTRY_PATH="$REG" bash "$SCRIPT" good --json --session >/dev/null 2>&1 ) &
APID=$!
TERMINATED=false
for _ in $(seq 1 50); do kill -0 "$APID" 2>/dev/null || { TERMINATED=true; break; }; sleep 0.1; done
if [[ "$TERMINATED" == true ]]; then
    wait "$APID"; ARC=$?
    if [[ "$ARC" -eq 0 ]]; then ok "w6-dangling-session-flag-terminates"; else bad "w6" "rc=$ARC"; fi
else
    kill "$APID" 2>/dev/null; bad "w6-dangling-session-flag" "still running after 5s (infinite arg loop)"
fi

echo
echo "=== lane: token-spend ==="
run good --session s1
if has_finding token-spend top-spend-sources INFO; then ok "t1-top-spend-ranked"; else bad "t1" "$OUT"; fi
if jq -e '.findings[] | select(.check=="top-spend-sources") | .evidence | contains("fanout-worker")' <<< "$OUT" >/dev/null 2>&1; then
    ok "t2-costliest-is-top-tier-worker"
else bad "t2" "$(jq -c '.findings[] | select(.check=="top-spend-sources")' <<< "$OUT")"; fi
if has_finding token-spend top-tier-dominates WARN; then ok "t3-top-tier-share-WARN"; else bad "t3" "$OUT"; fi

echo
echo "=== lane: role-compliance ==="
run good --session s1
if has_finding role-compliance wave-audit-missing FAIL; then ok "c1-unaudited-wave-FAIL"; else bad "c1" "$OUT"; fi
if jq -e '.findings[] | select(.check=="wave-audit-missing") | .evidence | contains("2")' <<< "$OUT" >/dev/null 2>&1; then
    ok "c2-names-missing-wave"
else bad "c2" "$(jq -c '.findings[] | select(.check=="wave-audit-missing")' <<< "$OUT")"; fi
run retry
if has_finding role-compliance never-auto-retry-violated FAIL; then ok "c3-fail-then-continue-FAIL"; else bad "c3" "$OUT"; fi
run remedy
if ! has_finding role-compliance never-auto-retry-violated FAIL; then
    ok "c3b-remediated-fail-not-flagged"
else bad "c3b-remediated" "$(jq -c '.findings[] | select(.check=="never-auto-retry-violated")' <<< "$OUT")"; fi
run bad
if has_finding role-compliance record-missing WARN; then ok "c4-no-RECORD-WARN"; else bad "c4" "$OUT"; fi
run good
if ! has_finding role-compliance review-lane-missing WARN; then ok "c5-code-reviewer-trace-found"; else bad "c5" "flagged despite reviewer record"; fi

echo
echo "=== human output mode ==="
HOUT="$(env \
    AGENT_MODEL_ROUTING_SINK="$LOGS/routing.jsonl" \
    AGENT_GOAL_AUDIT_LOG="$LOGS/goal-audit.jsonl" \
    AGENT_PLANS_DIR="$PLANS" \
    AGENT_PLAN_ARTIFACTS_DIR="$ARTS" \
    AGENT_GOAL_DB="$WORK/absent.db" \
    AGENT_REGISTRY_PATH="$REG" \
    bash "$SCRIPT" good 2>/dev/null)"; HRC=$?
if [[ "$HRC" -eq 0 && "$HOUT" == *"summary:"* && "$HOUT" == *"restatement-quality"* ]]; then
    ok "h1-human-table-with-summary"
else bad "h1-human-mode" "rc=$HRC out=$(tail -1 <<< "$HOUT")"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
