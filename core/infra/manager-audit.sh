#!/usr/bin/env bash
# manager-audit.sh — meta-audit over a /supervise run: is the supervisor doing its job?
#
# Four lanes, each reading artifacts the run already produced (zero runtime
# overhead — this script only ever runs after the fact):
#
#   restatement-quality — .agent/plans/<slug>/RESTATEMENT.md exists, all six
#                         sections present and filled, success criteria measurable
#   routing-waste       — .agent/logs/model-routing.jsonl: inherit_top leaks,
#                         verify/judge dispatches below the MID floor, fan-out
#                         batches not at LOW (docs/model-routing.md conventions)
#   token-spend         — relative dispatch cost = tokens × tier multiplier;
#                         ranks top spend sources. Multipliers LOW=0.15 MID=1
#                         TOP=3.5 are midpoints of the RELATIVE ranges published
#                         in docs/model-routing.md — they are NOT prices; no
#                         price constants exist in this repo (M-2 decision)
#   role-compliance     — one audit verdict per plan wave, never-auto-retry
#                         honored, RECORD.md written, goal-mode DB consistent,
#                         review lane dispatched after code waves
#
# Usage: bash core/infra/manager-audit.sh <plan-slug> [--json] [--session <id>] [--since <ISO-ts>]
#   --since scopes routing records to one run (the observer log accumulates
#   across sessions; /supervise Step 0 records the run start ts to pass here)
#
# Findings: {lane, check, severity(FAIL|WARN|INFO|PASS), evidence, proposal_hint}.
# proposal_hint targets conventions/templates/docs only — this script never
# edits anything and never blocks: ALWAYS exits 0 (audit reports, humans decide;
# runtime model-switching is explicitly rejected, docs/model-routing.md).
#
# Seams (test injection): AGENT_MODEL_ROUTING_SINK, AGENT_GOAL_AUDIT_LOG,
# AGENT_PLANS_DIR, AGENT_PLAN_ARTIFACTS_DIR, AGENT_GOAL_DB, AGENT_REGISTRY_PATH,
# AGENT_TIER_ALIASES ("model-prefix=TIER,..." extras for other vendors' names).
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROUTING_LOG="${AGENT_MODEL_ROUTING_SINK:-$REPO_ROOT/.agent/logs/model-routing.jsonl}"
GOAL_AUDIT_LOG="${AGENT_GOAL_AUDIT_LOG:-$REPO_ROOT/.agent/logs/supervisor-goal-audit.jsonl}"
PLANS_DIR="${AGENT_PLANS_DIR:-$HOME/.agent/plans}"
ARTIFACTS_DIR="${AGENT_PLAN_ARTIFACTS_DIR:-$REPO_ROOT/.agent/plans}"
GOAL_DB="${AGENT_GOAL_DB:-$REPO_ROOT/.agent/locks/goal-state.db}"
REGISTRY="${AGENT_REGISTRY_PATH:-$REPO_ROOT/agents/master-registry.json}"
TIER_ALIASES="${AGENT_TIER_ALIASES:-}"

SLUG="${1:-}"
shift || true
JSON_OUT=false
SESSION_FILTER=""
SINCE_FILTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_OUT=true; shift ;;
        --session)
            if [[ $# -ge 2 ]]; then SESSION_FILTER="$2"; shift 2
            else echo "ERROR: --session needs a value" >&2; shift; fi ;;
        --since)
            if [[ $# -ge 2 ]]; then SINCE_FILTER="$2"; shift 2
            else echo "ERROR: --since needs an ISO timestamp" >&2; shift; fi ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 0 ;;
    esac
done

if [[ -z "$SLUG" ]]; then
    echo "usage: manager-audit.sh <plan-slug> [--json] [--session <id>] [--since <ISO-ts>]" >&2
    exit 0
fi
# slug reaches filesystem paths and a sqlite WHERE clause — keep it to a safe charset
if [[ ! "$SLUG" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: slug must match [A-Za-z0-9._-]+ (got: $SLUG)" >&2
    exit 0
fi

FINDINGS='[]'
add() { # add <lane> <check> <severity> <evidence> <proposal_hint>
    FINDINGS=$(jq -c \
        --arg lane "$1" --arg check "$2" --arg sev "$3" \
        --arg ev "$4" --arg hint "$5" \
        '. + [{lane:$lane, check:$check, severity:$sev, evidence:$ev, proposal_hint:$hint}]' \
        <<< "$FINDINGS")
}
lane_pass_if_clean() { # lane_pass_if_clean <lane>
    local n
    n=$(jq --arg lane "$1" '[.[] | select(.lane==$lane and (.severity=="FAIL" or .severity=="WARN"))] | length' <<< "$FINDINGS")
    [[ "$n" -eq 0 ]] && add "$1" "lane-clean" "PASS" "no findings" ""
}

# ---------- lane: restatement-quality ----------
RESTATEMENT="$ARTIFACTS_DIR/$SLUG/RESTATEMENT.md"
SECTIONS=("Original ask" "Interpreted goal" "Assumptions" "Out of scope" "Success criteria" "Open questions")
if [[ ! -f "$RESTATEMENT" ]]; then
    add restatement-quality restatement-missing FAIL \
        "no $RESTATEMENT — the run dispatched without an intake restatement" \
        "run /supervise Step 0 (skills/supervise/templates/prompt-restatement.md) before wave dispatch"
else
    for sec in "${SECTIONS[@]}"; do
        if ! grep -q "^## $sec" "$RESTATEMENT"; then
            add restatement-quality "section-missing" FAIL \
                "section '## $sec' absent from RESTATEMENT.md" \
                "restore the six-section structure from the prompt-restatement template"
        else
            body=$(awk -v sec="^## $sec" '
                $0 ~ sec {grab=1; next}
                /^## / {grab=0}
                grab {print}' "$RESTATEMENT" | grep -v '^[[:space:]]*$' | grep -cv '^<' || true)
            if [[ "${body:-0}" -eq 0 ]]; then
                add restatement-quality "section-empty" WARN \
                    "section '## $sec' has no filled content (placeholder or blank)" \
                    "fill '$sec' — an unfilled intake section hides an interpretation the audit cannot check"
            fi
        fi
    done
    if grep -q "^## Success criteria" "$RESTATEMENT"; then
        crit=$(awk '/^## Success criteria/{grab=1; next} /^## /{grab=0} grab{print}' "$RESTATEMENT")
        if ! grep -qE '[0-9]|`|\.(sh|md|py|json|ts)|/' <<< "$crit"; then
            add restatement-quality criteria-not-measurable WARN \
                "Success criteria contain no numbers, paths, or commands — adjectives only" \
                "restate criteria as runnable commands or checkable artifacts (delegation-contract discipline)"
        fi
    fi
    # scope-drift heuristic: a plan wave whose title shares no content word with
    # the restatement is a drift CANDIDATE — semantic confirmation is the
    # manager-audit skill's half, not this script's.
    PLAN_FILE="$PLANS_DIR/$SLUG.md"
    if [[ -f "$PLAN_FILE" ]]; then
        rest_lc=$(tr '[:upper:]' '[:lower:]' < "$RESTATEMENT")
        while IFS= read -r title; do
            hit=false
            candidates=false
            stripped=$(sed -E 's/^## Wave [0-9]+:? *//' <<< "$title")
            for w in $(sed -E 's/[^[:alnum:] ]/ /g' <<< "$stripped" | tr '[:upper:]' '[:lower:]'); do
                [[ ${#w} -le 4 ]] && continue
                candidates=true
                grep -q "$w" <<< "$rest_lc" && { hit=true; break; }
            done
            # word extraction can strip a non-ASCII title to nothing — fall back
            # to a whole-title substring check instead of flagging unconditionally
            if [[ "$candidates" == false && -n "$stripped" ]]; then
                grep -qF "$(tr '[:upper:]' '[:lower:]' <<< "$stripped")" <<< "$rest_lc" && hit=true
            fi
            [[ "$hit" == false ]] && add restatement-quality scope-drift-candidate WARN \
                "plan wave '$title' shares no content word with the restatement" \
                "confirm the wave serves a goal in 'Interpreted goal' — else amend the restatement or drop the wave"
        done < <(grep -E '^## Wave [0-9]+' "$PLAN_FILE" || true)
    fi
fi
lane_pass_if_clean restatement-quality

# ---------- shared: routing records enriched with tier + relative score ----------
RECORDS='[]'
if [[ -f "$ROUTING_LOG" ]]; then
    REG_JSON='{}'
    [[ -f "$REGISTRY" ]] && REG_JSON=$(jq -c '(.agents // .) | map({(.id): (.model // "")}) | add // {}' "$REGISTRY" 2>/dev/null || echo '{}')
    ALIAS_JSON=$(jq -cRn --arg s "$TIER_ALIASES" \
        '[$s | split(",")[] | select(contains("=")) | split("=") | {(.[0]): .[1]}] | add // {}')
    RECORDS=$(jq -cs \
        --arg session "$SESSION_FILTER" \
        --arg since "$SINCE_FILTER" \
        --argjson reg "$REG_JSON" \
        --argjson aliases "$ALIAS_JSON" '
        def tier_of($m):
            if   ($m | startswith("haiku"))  then "LOW"
            elif ($m | startswith("sonnet")) then "MID"
            elif ($m | startswith("opus"))   then "TOP"
            elif ($aliases[$m] // "") != ""  then $aliases[$m]
            else "TOP" end;                       # unknown/inherit = session top
        def mult($t): {LOW: 0.15, MID: 1, TOP: 3.5}[$t] // 1;
        [ .[]
          | select(.gate == "model-routing-observer")
          | select($session == "" or .session_id == $session)
          | select($since == "" or ((.ts // "") >= $since))
          | .resolved_model = (if .model != "" then .model
                               elif .verdict == "pinned_specialist"
                               then ($reg[(.subagent_type | split(":") | last)] // "")
                               else "" end)
          | .tier = (if .verdict == "inherit_top" then "TOP" else tier_of(.resolved_model) end)
          | .rel_cost = (((.total_tokens // ((.prompt_chars // 0) / 4)) ) * mult(.tier))
        ]' "$ROUTING_LOG" 2>/dev/null || echo '[]')
else
    add routing-waste routing-log-missing WARN \
        "no routing log at $ROUTING_LOG — model-routing-observer hook not firing?" \
        "verify the PostToolUse Task|Agent hook chain (hooks/hooks.json) is installed"
fi

# ---------- lane: routing-waste ----------
if [[ "$(jq 'length' <<< "$RECORDS")" -gt 0 ]]; then
    leaks=$(jq '[.[] | select(.verdict == "inherit_top")]' <<< "$RECORDS")
    n_leaks=$(jq 'length' <<< "$leaks")
    if [[ "$n_leaks" -gt 0 ]]; then
        types=$(jq -r '[.[].subagent_type] | unique | join(", ")' <<< "$leaks")
        add routing-waste top-inherit-leak WARN \
            "$n_leaks dispatch(es) silently inherit the session top model: $types" \
            "add an explicit low/mid model override to these dispatch lanes (delegation-contract model field, docs/model-routing.md tier table)"
    fi
    floor=$(jq '[.[] | select((.subagent_type | test("verif|judge|review"; "i")) and .tier == "LOW")]' <<< "$RECORDS")
    if [[ "$(jq 'length' <<< "$floor")" -gt 0 ]]; then
        ev=$(jq -r '[.[].subagent_type] | join(", ")' <<< "$floor")
        add routing-waste verify-floor-violation FAIL \
            "verify/judge-lane dispatch(es) below the MID floor: $ev" \
            "verify and judge work never runs below MID (docs/model-routing.md floor) — raise the override"
    fi
    while IFS= read -r grp; do
        [[ -z "$grp" ]] && continue
        add routing-waste fanout-not-low WARN \
            "$grp" \
            "fan-out worker batches default to LOW tier (docs/model-routing.md) — add model: low to the batch contract"
    done < <(jq -r '[.[] | select(.verdict != "pinned_specialist")
          # Explore at MID is a documented exception to the fan-out-LOW default
          # (docs/model-routing.md § Built-in agents) — never a fan-out finding
          | select((.subagent_type == "Explore" and .tier == "MID") | not)]
        | group_by(.subagent_type) | .[]
        | select(length >= 3 and ([.[] | select(.tier != "LOW")] | length) == length)
        | "\(length)× \(.[0].subagent_type) at \([.[].tier] | unique | join("/")) — looks like a fan-out batch not at LOW"' <<< "$RECORDS")
fi
lane_pass_if_clean routing-waste

# ---------- lane: token-spend ----------
if [[ "$(jq 'length' <<< "$RECORDS")" -gt 0 ]]; then
    top3=$(jq -r 'sort_by(-.rel_cost) | .[:3] | map("\(.subagent_type) [\(.tier)] rel_cost=\(.rel_cost | floor)") | join("; ")' <<< "$RECORDS")
    add token-spend top-spend-sources INFO \
        "top dispatches by relative cost (tokens × tier multiplier): $top3" \
        ""
    total=$(jq '[.[].rel_cost] | add // 0' <<< "$RECORDS")
    top_share=$(jq --argjson t "$total" \
        'if $t <= 0 then 0 else (([.[] | select(.tier == "TOP") | .rel_cost] | add // 0) / $t * 100 | floor) end' <<< "$RECORDS")
    n_rec=$(jq 'length' <<< "$RECORDS")
    if [[ "$n_rec" -gt 1 && "$top_share" -gt 50 ]]; then
        add token-spend top-tier-dominates WARN \
            "TOP-tier dispatches carry ${top_share}% of relative spend across $n_rec dispatches" \
            "route execution/fan-out lanes to MID/LOW via explicit overrides; keep TOP for judgment only (docs/model-routing.md)"
    fi
    if [[ -f "$GOAL_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
        used=$(sqlite3 "$GOAL_DB" "SELECT tokens_used FROM supervisor_goals WHERE plan_slug='$SLUG';" 2>/dev/null || true)
        [[ -n "$used" ]] && add token-spend goal-budget-crosscheck INFO \
            "goal-state tokens_used=$used for this slug (relative dispatch cost total=$(printf '%.0f' "$total"))" \
            ""
    fi
fi
lane_pass_if_clean token-spend

# ---------- lane: role-compliance ----------
PLAN_FILE="$PLANS_DIR/$SLUG.md"
if [[ ! -f "$PLAN_FILE" ]]; then
    add role-compliance plan-missing WARN \
        "no plan at $PLAN_FILE — cannot check wave coverage" \
        ""
else
    N=$(grep -cE '^## Wave [0-9]+' "$PLAN_FILE" || true)
    AUDITS='[]'
    [[ -f "$GOAL_AUDIT_LOG" ]] && AUDITS=$(jq -cs --arg slug "$SLUG" \
        '[.[] | select(.plan_slug == $slug and has("all_pass"))]' "$GOAL_AUDIT_LOG" 2>/dev/null || echo '[]')
    if [[ "$N" -gt 0 ]]; then
        missing=$(jq -r --argjson n "$N" \
            '([.[].wave] | unique) as $seen | [range(1; $n + 1) | select(. as $w | $seen | index($w) | not)] | join(", ")' <<< "$AUDITS")
        [[ -n "$missing" ]] && add role-compliance wave-audit-missing FAIL \
            "wave(s) $missing of $N have no audit verdict in supervisor-goal-audit.jsonl" \
            "every wave must pass 'supervisor-goal-audit.sh <slug> <i>' before advancing (/supervise hard rule: never skip the audit)"
        # a FAIL later re-audited to PASS is remediated, not a violation —
        # only downstream waves that ran (by ts) after an UNremediated FAIL count
        retry=$(jq -r '
            sort_by(.ts) as $r
            | [ range(0; ($r | length)) as $i
                | select($r[$i].all_pass == false)
                | $r[$i].wave as $fw
                | $r[($i + 1):] as $after
                | select(($after | map(select(.wave == $fw and .all_pass == true)) | length) == 0)
                | ($after | map(select(.wave > $fw) | .wave)) ]
            | flatten | unique | join(", ")' <<< "$AUDITS")
        [[ -n "$retry" ]] && add role-compliance never-auto-retry-violated FAIL \
            "wave(s) $retry ran after an earlier wave's audit FAIL" \
            "a FAIL stops the loop and hands to the user (/supervise hard rule: never auto-retry a failed audit)"
    fi
    [[ ! -f "$ARTIFACTS_DIR/$SLUG/RECORD.md" ]] && add role-compliance record-missing WARN \
        "no $ARTIFACTS_DIR/$SLUG/RECORD.md execution ledger" \
        "write the RECORD.md completion ledger (/supervise Step 5 discipline; goal-mode drops a stub automatically)"
    if [[ -f "$GOAL_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
        row=$(sqlite3 "$GOAL_DB" "SELECT status || '|' || current_wave || '|' || total_waves FROM supervisor_goals WHERE plan_slug='$SLUG';" 2>/dev/null || true)
        if [[ -n "$row" ]]; then
            status="${row%%|*}"
            [[ "$status" != "complete" ]] && add role-compliance goal-not-complete WARN \
                "goal-state row for '$SLUG' is '$status' (current|total = ${row#*|})" \
                "if the run finished, close it: core/infra/supervisor-goal.sh complete $SLUG"
        fi
    fi
    if grep -qE '\.(py|sh|ts|js)([^[:alnum:]_]|$)|core/hooks/' "$PLAN_FILE"; then
        n_rev=$(jq '[.[] | select(.verdict == "pinned_specialist" and (.subagent_type | test("code-reviewer")))] | length' <<< "$RECORDS")
        [[ "$n_rev" -eq 0 ]] && add role-compliance review-lane-missing WARN \
            "plan touches code but no code-reviewer dispatch appears in the routing log" \
            "code-touching waves get a code-reviewer pass after execution (/supervise Step 2b)"
    fi
fi
lane_pass_if_clean role-compliance

# ---------- output ----------
if [[ "$JSON_OUT" == true ]]; then
    jq --arg slug "$SLUG" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{ts: $ts, plan_slug: $slug, findings: .}' <<< "$FINDINGS"
else
    echo "manager-audit: $SLUG"
    echo
    jq -r 'group_by(.lane)[] | "── " + .[0].lane + " ──",
        (.[] | "  [" + .severity + "] " + .check + " — " + .evidence
             + (if .proposal_hint != "" then "\n         ↳ " + .proposal_hint else "" end))' \
        <<< "$FINDINGS"
    echo
    jq -r '"summary: \([.[] | select(.severity=="FAIL")] | length) FAIL / \([.[] | select(.severity=="WARN")] | length) WARN / \([.[] | select(.severity=="INFO")] | length) INFO"' \
        <<< "$FINDINGS"
fi

exit 0
