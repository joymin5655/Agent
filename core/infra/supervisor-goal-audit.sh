#!/usr/bin/env bash
# supervisor-goal-audit.sh — Wave verification + 5-dimension goal scoring.
#
# Two modes:
#   1. audit (default)  — bash core/infra/supervisor-goal-audit.sh <plan-slug> <wave-num>
#                          Runs verification commands in the plan's Wave N section,
#                          collects exit codes, writes JSONL audit + dimension scores.
#   2. score-only       — bash core/infra/supervisor-goal-audit.sh score --plan <slug> --wave <num>
#                          Does NOT run commands. Just scores the goal definition + stderr advisory.
#
# 5 Dimensions (each 0-5, total 25):
#   - target_state        (observable behavior, target files exist)
#   - acceptance_criteria (positive / negative / regression / domain-output)
#   - validation_evidence (richness of verification commands)
#   - boundaries          (editable / off-limits / preserve / risk-areas)
#   - stop_conditions     (abort / turn-cap / safeguards)
#
# Verdict thresholds: >=18 strong / 12-17 mixed / <12 weak (advisory only — does NOT block)
#
# Domain-output keywords are configurable via AGENT_DOMAIN_OUTPUT_KEYWORDS env var
# (default: 'uncertainty|confidence|tolerance'). Set to override per project.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AUDIT_LOG="$REPO_ROOT/.agent/logs/supervisor-goal-audit.jsonl"
GOAL_HELPER="$REPO_ROOT/core/infra/supervisor-goal.sh"
PLANS_DIR="${AGENT_PLANS_DIR:-$HOME/.agent/plans}"

# Project-tunable scoring keywords (override via env vars).
DOMAIN_OUTPUT_KEYWORDS="${AGENT_DOMAIN_OUTPUT_KEYWORDS:-uncertainty|confidence|tolerance}"
RISK_AREA_KEYWORDS="${AGENT_RISK_AREA_KEYWORDS:-risk-area|production|secret|migration|deploy|payment}"
SAFEGUARD_KEYWORDS="${AGENT_SAFEGUARD_KEYWORDS:-safeguard|mutex|gitleaks|test fail|type fail|user stop}"

mkdir -p "$(dirname "$AUDIT_LOG")"

MODE="audit"
PLAN_SLUG=""
WAVE_NUM=""

if [[ "${1:-}" == "score" ]]; then
    MODE="score"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --plan) PLAN_SLUG="${2:-}"; shift 2 ;;
            --wave) WAVE_NUM="${2:-}"; shift 2 ;;
            *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
        esac
    done
else
    PLAN_SLUG="${1:-}"
    WAVE_NUM="${2:-}"
fi

if [[ -z "$PLAN_SLUG" || -z "$WAVE_NUM" ]]; then
    echo "usage:" >&2
    echo "  supervisor-goal-audit.sh <plan-slug> <wave-num>                   # audit mode" >&2
    echo "  supervisor-goal-audit.sh score --plan <slug> --wave <num>          # score-only mode" >&2
    exit 2
fi

PLAN_FILE="$PLANS_DIR/${PLAN_SLUG}.md"
if [[ ! -f "$PLAN_FILE" ]]; then
    echo "ERROR: plan missing: $PLAN_FILE" >&2
    exit 3
fi

# ---------- Extract Wave N section ----------
WAVE_SECTION=$(awk -v n="$WAVE_NUM" '
    /^#{2,3}[[:space:]]+Wave[[:space:]]+/ {
        if (in_section) { exit }
        if ($0 ~ "Wave[[:space:]]+" n "([^0-9]|$)") {
            in_section = 1
            print
            next
        }
    }
    in_section { print }
' "$PLAN_FILE")

if [[ -z "$WAVE_SECTION" ]]; then
    echo "ERROR: Wave $WAVE_NUM section missing in $PLAN_FILE" >&2
    exit 4
fi

# ---------- Extract verification commands ----------
declare -a CHECKS=()
while IFS= read -r cmd; do
    cmd="$(echo "$cmd" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$cmd" ]] && continue
    CHECKS+=("$cmd")
done < <({ echo "$WAVE_SECTION" | grep -oE '(npm run (build|lint|test|test:run|test:e2e|typecheck|test:a11y)|npx tsc[^[:space:]]*|pytest[^"]*|uv run pytest[^"]*|ruff check[^"]*|test -f [^[:space:]]+|test ! -f [^[:space:]]+|bash -n [^[:space:]]+|wc -l [^[:space:]]+|grep -c [^[:space:]]+|bash core/[^[:space:]]+\.sh|bash tests/[^[:space:]]+\.sh|tests/integration/[^[:space:]]+\.sh|jq [^"|]+\.(jsonl|json)|time bash [^[:space:]]+\.sh)' || true; } | sort -u)

# ---------- Scoring functions (deterministic — no LLM calls) ----------

score_target_state() {
    local section="$1"
    local score=0
    { grep -qE "Target state" <<< "$section" && score=$((score + 1)); } || true
    { grep -qE '(\.md|\.sh|\.py|\.json|\.ts|\.tsx|\.yaml|\.yml|\.sql)' <<< "$section" && score=$((score + 1)); } || true
    { grep -qE "(new|add|create|extend|wire-up|register)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qE "(observable|exists|render|display)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qE "(positive|negative|behavior|exit code|exit 0|>=|<=)" <<< "$section" && score=$((score + 1)); } || true
    echo "$score"
}

score_acceptance_criteria() {
    local section="$1"
    local score=0
    { grep -qE "Acceptance criteria" <<< "$section" && score=$((score + 1)); } || true
    { grep -qE "\(positive\)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qE "\(negative\)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qE "(regression|backward compat|persistence|persisted)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "($DOMAIN_OUTPUT_KEYWORDS)" <<< "$section" && score=$((score + 1)); } || true
    # Partial credit: numbered AC list when no strong template markers present.
    if [[ $score -le 1 ]]; then
        { grep -qE "^- \(([0-9]+)\)" <<< "$section" && score=$((score + 1)); } || true
    fi
    echo "$score"
}

score_validation_evidence() {
    local n_checks="$1"
    if [[ "$n_checks" -eq 0 ]]; then echo 0
    elif [[ "$n_checks" -eq 1 ]]; then echo 2
    elif [[ "$n_checks" -eq 2 ]]; then echo 3
    elif [[ "$n_checks" -le 4 ]]; then echo 4
    else echo 5
    fi
}

score_boundaries() {
    local section="$1"
    local score=0
    { grep -qE "Boundaries" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "(editable|may edit|allowed)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "(off-limits|do not edit|do not change|deferred)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "(preserve|keep)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "($RISK_AREA_KEYWORDS)" <<< "$section" && score=$((score + 1)); } || true
    echo "$score"
}

score_stop_conditions() {
    local section="$1"
    local score=0
    { grep -qE "Stop condition" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "(abort|stop|halt)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "(turn|after N minutes|timeout|N turns)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "(FAIL|fail|violation)" <<< "$section" && score=$((score + 1)); } || true
    { grep -qEi "($SAFEGUARD_KEYWORDS)" <<< "$section" && score=$((score + 1)); } || true
    echo "$score"
}

D_TARGET=$(score_target_state "$WAVE_SECTION")
D_AC=$(score_acceptance_criteria "$WAVE_SECTION")
D_VALIDATION=$(score_validation_evidence "${#CHECKS[@]}")
D_BOUNDARIES=$(score_boundaries "$WAVE_SECTION")
D_STOP=$(score_stop_conditions "$WAVE_SECTION")
TOTAL=$((D_TARGET + D_AC + D_VALIDATION + D_BOUNDARIES + D_STOP))

if [[ "$TOTAL" -ge 18 ]]; then
    VERDICT="strong"
elif [[ "$TOTAL" -ge 12 ]]; then
    VERDICT="mixed"
else
    VERDICT="weak"
fi

# ---------- score-only mode ----------
if [[ "$MODE" == "score" ]]; then
    SCORE_JSON=$(jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg slug "$PLAN_SLUG" \
        --argjson wave "$WAVE_NUM" \
        --argjson target "$D_TARGET" \
        --argjson ac "$D_AC" \
        --argjson validation "$D_VALIDATION" \
        --argjson boundaries "$D_BOUNDARIES" \
        --argjson stop "$D_STOP" \
        --argjson total "$TOTAL" \
        --arg verdict "$VERDICT" \
        --argjson n_checks "${#CHECKS[@]}" \
        '{ts:$ts, plan_slug:$slug, wave:$wave, dimension_scores:[$target,$ac,$validation,$boundaries,$stop], total:$total, verdict:$verdict, n_checks:$n_checks, mode:"score-only", audit_protocol:"strong_goal_v1"}')
    echo "$SCORE_JSON" >> "$AUDIT_LOG"
    echo "$SCORE_JSON"

    if [[ "$VERDICT" == "weak" ]]; then
        echo "[score advisory] Wave $WAVE_NUM weak (total=$TOTAL/25). Review strong-goal patterns (rules/policy/strong-goal-template.md)." >&2
    fi
    exit 0
fi

# ---------- audit mode: run commands + collect evidence ----------
if [[ "${#CHECKS[@]}" -eq 0 ]]; then
    echo "WARN: Wave $WAVE_NUM has 0 verification commands. Strengthen plan §verification." >&2
    RESULT_JSON=$(jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg slug "$PLAN_SLUG" \
        --argjson wave "$WAVE_NUM" \
        --argjson target "$D_TARGET" \
        --argjson ac "$D_AC" \
        --argjson validation "$D_VALIDATION" \
        --argjson boundaries "$D_BOUNDARIES" \
        --argjson stop "$D_STOP" \
        --argjson total "$TOTAL" \
        --arg verdict "$VERDICT" \
        '{ts:$ts, plan_slug:$slug, wave:$wave, requirements:[], evidence:[], all_pass:true, dimension_scores:[$target,$ac,$validation,$boundaries,$stop], total:$total, verdict:$verdict, note:"no check commands found", audit_protocol:"strong_goal_v1"}')
    echo "$RESULT_JSON" >> "$AUDIT_LOG"
    echo "$RESULT_JSON"
    [[ "$VERDICT" == "weak" ]] && echo "[audit advisory] Wave $WAVE_NUM weak (total=$TOTAL/25)." >&2
    exit 0
fi

EVIDENCE_JSON='[]'
ALL_PASS=true

for cmd in "${CHECKS[@]}"; do
    echo "[audit] running: $cmd" >&2
    LOG_FILE=$(mktemp)
    if eval "$cmd" > "$LOG_FILE" 2>&1; then
        PASS=true
        EXIT_CODE=0
    else
        PASS=false
        EXIT_CODE=$?
        ALL_PASS=false
    fi
    LOG_TAIL=$(tail -5 "$LOG_FILE" | head -c 500)
    rm -f "$LOG_FILE"
    EVIDENCE_JSON=$(echo "$EVIDENCE_JSON" | jq \
        --arg cmd "$cmd" \
        --argjson pass "$PASS" \
        --argjson code "$EXIT_CODE" \
        --arg tail "$LOG_TAIL" \
        '. + [{cmd:$cmd, pass:$pass, exit_code:$code, log_tail:$tail}]')
done

RESULT_JSON=$(jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg slug "$PLAN_SLUG" \
    --argjson wave "$WAVE_NUM" \
    --argjson evidence "$EVIDENCE_JSON" \
    --argjson all_pass "$ALL_PASS" \
    --argjson target "$D_TARGET" \
    --argjson ac "$D_AC" \
    --argjson validation "$D_VALIDATION" \
    --argjson boundaries "$D_BOUNDARIES" \
    --argjson stop "$D_STOP" \
    --argjson total "$TOTAL" \
    --arg verdict "$VERDICT" \
    '{ts:$ts, plan_slug:$slug, wave:$wave, requirements:($evidence|map(.cmd)), evidence:$evidence, all_pass:$all_pass, dimension_scores:[$target,$ac,$validation,$boundaries,$stop], total:$total, verdict:$verdict, audit_protocol:"strong_goal_v1"}')

echo "$RESULT_JSON" >> "$AUDIT_LOG"
echo "$RESULT_JSON"

[[ "$VERDICT" == "weak" ]] && echo "[audit advisory] Wave $WAVE_NUM weak (total=$TOTAL/25)." >&2

if [[ "$ALL_PASS" == "false" ]]; then
    if [[ -x "$GOAL_HELPER" ]]; then
        echo "[audit] FAIL — invoking supervisor-goal.sh abort" >&2
        bash "$GOAL_HELPER" abort "$PLAN_SLUG" "audit-fail wave-$WAVE_NUM" >/dev/null 2>&1 || true
    fi
    exit 1
fi

exit 0
