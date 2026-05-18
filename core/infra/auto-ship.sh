#!/usr/bin/env bash
# auto-ship.sh — automated ship helper (push + CI watch + risk-area grep + admin merge + main pull)
#
# Usage:
#   bash core/infra/auto-ship.sh <pr-number> [--watch-timeout SECONDS]
#
# Policy (consumer project defines risk areas in hook-config.yml — see docs/customization.md):
#   1. CI all SUCCESS — or secret-scan billing-fail branch (Layer 1 leak detection still required)
#   2. Risk-area grep on PR diff (data / secrets / deploy / payment / domain-output)
#   3. Explicit user invocation (caller responsibility — supervisor / direct invoke)
#   4. (Optional) Actions billing-hit signal
#
# Risk areas (configurable via hook-config.yml `risk_areas:` block; defaults below):
#   data            — production data migration files (e.g., supabase/migrations/*.sql)
#   secrets         — secret keyword diff (sk-*, JWT, KEY= literals)
#   deploy          — deploy bundle files (e.g., supabase/functions/*/index.ts)
#   payment         — billing/payment-related paths (stripe, polar, iap, billing/)
#   domain-output   — domain-output uncertainty fields (project-specific net-removal check)
#
# Abort exit codes:
#   2  usage / arg error
#   3  PR fetch fail
#   4  PR not OPEN
#   5  PR base != main
#   6  CI secret-scan real leak (not billing)
#   7  Local gitleaks fail (billing branch)
#   8  CI gitleaks fail, branch unclear
#   9  Secret Scan run_id not extracted
#   10 CI fail (non-secret-scan)
#   11 PR diff fetch fail
#   12 risk-area `data` violated
#   13 risk-area `deploy` violated
#   14 risk-area `payment` violated
#   15 risk-area `secrets` violated
#   16 risk-area `domain-output` violated (net removal)
#   17 admin merge fail
#
# Evidence: $REPO_ROOT/.agent/logs/admin-merge.jsonl (admin-merge-track.py hook).

set -euo pipefail

PR_NUM="${1:-}"
WATCH_TIMEOUT="${2:-600}"

if [[ -z "$PR_NUM" || ! "$PR_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: usage: bash core/infra/auto-ship.sh <pr-number> [--watch-timeout SECONDS]" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# Load risk-area config (consumer project may override defaults via hook-config.yml).
HOOK_CONFIG="${HOOK_CONFIG_PATH:-$REPO_ROOT/hook-config.yml}"

# Default risk-area patterns (overridable via env vars or hook-config.yml).
RISK_DATA_PATTERN="${RISK_DATA_PATTERN:-^.*/migrations/.*\.sql$}"
RISK_DEPLOY_PATTERN="${RISK_DEPLOY_PATTERN:-^.*/functions/.*/index\.ts$}"
RISK_PAYMENT_PATTERN="${RISK_PAYMENT_PATTERN:-(billing/|stripe|polar|iap|revenue-cat)}"
RISK_SECRETS_PATTERN="${RISK_SECRETS_PATTERN:-(SERVICE_ROLE_KEY|API_TOKEN|API_KEY|STRIPE_SECRET|sk-[a-zA-Z0-9]{20,}|eyJ[a-zA-Z0-9]{30,})}"
# Empty = skip domain-output check (project-specific).
RISK_DOMAIN_OUTPUT_PATTERN="${RISK_DOMAIN_OUTPUT_PATTERN:-}"

echo "=== auto-ship PR #${PR_NUM} ==="
echo

# ---------- 1. PR status ----------
echo "[1/6] PR status..."
PR_INFO=$(gh pr view "$PR_NUM" --json state,mergeable,headRefName,headRefOid,baseRefName 2>&1) || {
    echo "ERROR: PR #${PR_NUM} fetch fail: $PR_INFO" >&2
    exit 3
}
PR_STATE=$(echo "$PR_INFO" | jq -r '.state')
PR_MERGEABLE=$(echo "$PR_INFO" | jq -r '.mergeable')
PR_HEAD=$(echo "$PR_INFO" | jq -r '.headRefName')
PR_BASE=$(echo "$PR_INFO" | jq -r '.baseRefName')

echo "  state=$PR_STATE / mergeable=$PR_MERGEABLE / head=$PR_HEAD / base=$PR_BASE"

if [[ "$PR_STATE" == "MERGED" ]]; then
    echo "  → already merged. exit 0 (no-op)."
    exit 0
fi
if [[ "$PR_STATE" != "OPEN" ]]; then
    echo "ERROR: PR state=$PR_STATE (not OPEN). abort." >&2
    exit 4
fi
if [[ "$PR_BASE" != "main" ]]; then
    echo "ERROR: PR base=$PR_BASE (expected main). abort." >&2
    exit 5
fi

# ---------- 2. CI watch ----------
echo
echo "[2/6] CI watch (timeout=${WATCH_TIMEOUT}s)..."
CI_OUTPUT=$(timeout "$WATCH_TIMEOUT" gh pr checks "$PR_NUM" --watch --interval 15 2>&1) || CI_EXIT=$?
CI_EXIT="${CI_EXIT:-0}"
echo "$CI_OUTPUT" | tail -20
echo "  CI exit=$CI_EXIT"

# ---------- 3. CI result branching ----------
echo
echo "[3/6] CI result branching (secret-scan billing-fail vs real leak)..."
if [[ "$CI_EXIT" -eq 0 ]]; then
    echo "  → all CI SUCCESS."
else
    FAILED_CHECKS=$(echo "$CI_OUTPUT" | grep -E "^X\s" | awk '{print $2}' || true)
    SECRET_SCAN_ONLY_FAIL=true
    for check in $FAILED_CHECKS; do
        if [[ ! "$check" =~ (gitleaks|Secret|secret-scan) ]]; then
            SECRET_SCAN_ONLY_FAIL=false
            break
        fi
    done

    if [[ "$SECRET_SCAN_ONLY_FAIL" == "true" && -n "$FAILED_CHECKS" ]]; then
        echo "  → secret-scan only FAIL — verifying (billing-fail vs real-leak)..."
        RUN_ID=$(gh run list --branch="$PR_HEAD" --workflow='Secret Scan' --limit=1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
        if [[ -n "$RUN_ID" ]]; then
            RUN_LOG=$(gh run view "$RUN_ID" 2>&1 | tail -50)
            if echo "$RUN_LOG" | grep -q "leaks found"; then
                echo "ERROR: real leak detected — abort. (risk-area `secrets` violated)" >&2
                echo "$RUN_LOG" | grep -A 2 "leaks found" >&2
                exit 6
            elif echo "$RUN_LOG" | grep -qE "(spending limit|account payments|billing)"; then
                echo "  → secret-scan billing-fail confirmed — running local gitleaks fallback..."
                if command -v gitleaks &>/dev/null; then
                    if ! gitleaks detect --no-git --source=. --config=gitleaks.toml --no-banner -v &>/dev/null; then
                        echo "ERROR: local gitleaks FAIL — abort. (risk-area `secrets` violated)" >&2
                        exit 7
                    fi
                    echo "    ✓ local gitleaks 0 leaks"
                else
                    echo "    ⚠ gitleaks CLI missing — skip (caller responsibility)"
                fi
            else
                echo "ERROR: secret-scan FAIL — branch unclear (billing vs leak). abort." >&2
                echo "$RUN_LOG" | tail -10 >&2
                exit 8
            fi
        else
            echo "ERROR: Secret Scan run_id not extracted. abort." >&2
            exit 9
        fi
    else
        echo "ERROR: non-secret-scan CI FAIL — abort. failed=$FAILED_CHECKS" >&2
        exit 10
    fi
fi

# ---------- 4. Risk-area grep (PR diff) ----------
echo
echo "[4/6] Risk-area grep (PR diff)..."
DIFF_FILES=$(gh pr diff "$PR_NUM" --name-only 2>/dev/null) || {
    echo "ERROR: gh pr diff fail." >&2
    exit 11
}

# data — production data migration
if [[ -n "$RISK_DATA_PATTERN" ]]; then
    DATA_FILES=$(echo "$DIFF_FILES" | { grep -E "$RISK_DATA_PATTERN" || true; })
    if [[ -n "$DATA_FILES" ]]; then
        echo "BLOCK: risk-area 'data' violated. abort admin merge." >&2
        echo "  matched: $DATA_FILES" >&2
        echo "  → manual user review + merge required." >&2
        exit 12
    fi
    echo "  ✓ data — 0 file"
fi

# deploy — function/worker deploy bundle
if [[ -n "$RISK_DEPLOY_PATTERN" ]]; then
    DEPLOY_FILES=$(echo "$DIFF_FILES" | { grep -E "$RISK_DEPLOY_PATTERN" || true; })
    if [[ -n "$DEPLOY_FILES" ]]; then
        echo "BLOCK: risk-area 'deploy' violated. abort admin merge." >&2
        echo "  matched: $DEPLOY_FILES" >&2
        echo "  → resource-mutex claim + explicit user deploy required." >&2
        exit 13
    fi
    echo "  ✓ deploy — 0 file"
fi

# payment — billing/payment code
if [[ -n "$RISK_PAYMENT_PATTERN" ]]; then
    PAYMENT_FILES=$(echo "$DIFF_FILES" | { grep -iE "$RISK_PAYMENT_PATTERN" || true; })
    if [[ -n "$PAYMENT_FILES" ]]; then
        echo "BLOCK: risk-area 'payment' violated. abort admin merge." >&2
        echo "  matched: $PAYMENT_FILES" >&2
        exit 14
    fi
    echo "  ✓ payment — 0 file"
fi

# secrets — diff content scan
# Optional helper: $REPO_ROOT/core/infra/auto-ship-guard-scan.py (EXEMPT-aware chunk splitter).
GUARD_SCAN="$REPO_ROOT/core/infra/auto-ship-guard-scan.py"
if [[ -x "$GUARD_SCAN" ]] && command -v python3 >/dev/null 2>&1; then
    if ! gh pr diff "$PR_NUM" 2>/dev/null | python3 "$GUARD_SCAN"; then
        exit 15
    fi
    echo "  ✓ secrets — 0 hit (EXEMPT-aware scan)"
else
    SECRET_HITS=$(gh pr diff "$PR_NUM" 2>/dev/null | { grep -iE "^\+.*${RISK_SECRETS_PATTERN}" || true; })
    if [[ -n "$SECRET_HITS" ]]; then
        echo "BLOCK: risk-area 'secrets' violated — secret keyword in diff (fallback grep). abort." >&2
        echo "  hits: $(echo "$SECRET_HITS" | head -3)" >&2
        exit 15
    fi
    echo "  ✓ secrets — 0 hit (fallback grep — helper missing)"
fi

# domain-output — uncertainty/quality field net-removal (project-specific, skip if unset)
if [[ -n "$RISK_DOMAIN_OUTPUT_PATTERN" ]]; then
    REMOVAL=$(gh pr diff "$PR_NUM" 2>/dev/null | { grep -E "^-.*${RISK_DOMAIN_OUTPUT_PATTERN}" || true; } | wc -l | tr -d ' ')
    if [[ "$REMOVAL" -gt 0 ]]; then
        ADDITION=$(gh pr diff "$PR_NUM" 2>/dev/null | { grep -E "^\+.*${RISK_DOMAIN_OUTPUT_PATTERN}" || true; } | wc -l | tr -d ' ')
        NET_REMOVAL=$((REMOVAL - ADDITION))
        if [[ "$NET_REMOVAL" -gt 0 ]]; then
            echo "BLOCK: risk-area 'domain-output' violated — net removal=$NET_REMOVAL. abort." >&2
            echo "  → uncertainty/quality field removal requires explicit user merge." >&2
            exit 16
        fi
    fi
    echo "  ✓ domain-output — net removal=0"
fi

echo
echo "Risk-area checks PASS — proceeding with admin merge."

# ---------- 5. admin merge ----------
echo
echo "[5/6] admin merge..."
MERGE_OUTPUT=$(gh pr merge "$PR_NUM" --admin --squash 2>&1) || {
    echo "ERROR: gh pr merge fail: $MERGE_OUTPUT" >&2
    exit 17
}
echo "$MERGE_OUTPUT"

sleep 2
MERGED_STATE=$(gh pr view "$PR_NUM" --json state,mergeCommit --jq '.state + " / " + .mergeCommit.oid')
echo "  → merged: $MERGED_STATE"

# ---------- 6. main pull ----------
echo
echo "[6/6] main pull..."
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" == "main" ]]; then
    git pull --ff-only 2>&1 | tail -5
else
    echo "  cwd branch=$CURRENT_BRANCH (not main). skip pull — pull in main checkout separately."
fi

echo
echo "=== ✅ auto-ship PR #${PR_NUM} done ==="
echo "  branch: $PR_HEAD → merged into main"
echo "  evidence: .agent/logs/admin-merge.jsonl (admin-merge-track.py hook)"
echo "  worktree cleanup: bash core/infra/agent-session.sh stop  (or git worktree remove)"
