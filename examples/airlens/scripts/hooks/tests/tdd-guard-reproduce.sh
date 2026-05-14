#!/usr/bin/env bash
# tdd-guard reproduce 12-case (frosted-mason Phase 4).
# Backs up real vitest cache, injects controlled fake cache, runs 12 cases,
# verifies (output + jsonl verdict) vs expected, restores real cache.
# Plan: ~/.claude/plans/tdd-guard-self-strengthen-frosted-mason.md §Phase 4

set -e

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PY="/usr/bin/python3"
HOOK="$ROOT/scripts/hooks/tdd-guard.py"
CACHE="$ROOT/.claude/state/vitest-last-run.json"
BACKUP="$ROOT/.claude/state/vitest-last-run.json.bak.reproduce"
TMP_SINK="$ROOT/.claude/logs/tdd-guard-reproduce-tmp.jsonl"

PASS=0
FAIL=0
FAILED_CASES=()

cleanup() {
    # Restore real cache + remove tmp sink
    if [[ -f "$BACKUP" ]]; then
        mv "$BACKUP" "$CACHE"
    fi
    rm -f "$TMP_SINK"
}
trap cleanup EXIT

# Backup real cache
[[ -f "$CACHE" ]] && cp "$CACHE" "$BACKUP"

# Build fake cache with controlled test state
build_fake_cache() {
    cat > "$CACHE" <<'EOF'
{
  "version": 1,
  "ts": "2026-05-12T07:00:00+00:00",
  "scope": "apps/web",
  "testResults": [
    {
      "file": "apps/web/src/components/Foo.test.tsx",
      "status": "failed",
      "assertionResults": [
        {"fullName": "Foo > renders", "status": "failed", "failureMessage": "expected true to be false"}
      ]
    },
    {
      "file": "apps/web/src/components/Bar.test.tsx",
      "status": "passed",
      "assertionResults": [
        {"fullName": "Bar > works", "status": "passed", "failureMessage": ""}
      ]
    },
    {
      "file": "apps/web/src/components/Qux.test.tsx",
      "status": "passed",
      "assertionResults": [
        {"fullName": "Qux > works", "status": "passed", "failureMessage": ""}
      ]
    }
  ],
  "failedFiles": ["apps/web/src/components/Foo.test.tsx"]
}
EOF
    # Fresh mtime (now)
    touch "$CACHE"
}

# Run one case. Args: name, file_path, expected_verdict
# expected_verdict ∈ {would_allow, would_block, mode_stale, guard_skip, silent_skip}
# "silent_skip" = no jsonl record AND no stdout
run_case() {
    local name="$1" path="$2" expected="$3"
    local input output actual

    : > "$TMP_SINK"  # clear sink

    input=$(printf '{"tool_input":{"file_path":"%s"}}' "$path")
    output=$(echo "$input" | AIRLENS_TDD_GUARD_SINK=".claude/logs/tdd-guard-reproduce-tmp.jsonl" $PY "$HOOK" 2>&1 || true)

    if [[ "$expected" == "silent_skip" ]]; then
        # Pass criteria: empty output + empty sink
        if [[ -z "$output" && ! -s "$TMP_SINK" ]]; then
            actual="silent_skip"
        elif [[ -n "$output" ]]; then
            actual="output_present"
        else
            actual=$(tail -1 "$TMP_SINK" | /usr/bin/jq -r '.verdict' 2>/dev/null || echo "parse_fail")
        fi
    else
        if [[ -s "$TMP_SINK" ]]; then
            actual=$(tail -1 "$TMP_SINK" | /usr/bin/jq -r '.verdict' 2>/dev/null || echo "parse_fail")
        else
            actual="(no record)"
        fi
    fi

    if [[ "$actual" == "$expected" ]]; then
        printf "  PASS  %-30s -> %s\n" "$name" "$actual"
        PASS=$((PASS+1))
    else
        printf "  FAIL  %-30s expected=%s got=%s\n" "$name" "$expected" "$actual"
        FAILED_CASES+=("$name")
        FAIL=$((FAIL+1))
    fi
}

echo "=== tdd-guard reproduce (12 cases) ==="
echo ""

# Fresh cache for cases 1-4, 6-12
build_fake_cache

# === Cases 1-4: cache-driven decisions ===
run_case "1-RGR-failing-allow" \
    "$ROOT/apps/web/src/components/Foo.tsx" \
    "would_allow"

run_case "2-green-only-block" \
    "$ROOT/apps/web/src/components/Bar.tsx" \
    "would_block"

run_case "3-no-test-block" \
    "$ROOT/apps/web/src/components/Baz.tsx" \
    "would_block"

run_case "4-test-file-edit-skip" \
    "$ROOT/apps/web/src/components/Qux.test.tsx" \
    "silent_skip"

# === Case 5: stale cache ===
# Set mtime to 1000s ago (> 600s TTL)
NOW=$(date +%s); PAST=$((NOW - 1000))
$PY -c "import os; os.utime('$CACHE', ($PAST, $PAST))"
run_case "5-stale-cache-allow" \
    "$ROOT/apps/web/src/components/Anything.tsx" \
    "mode_stale"
# Refresh mtime for remaining cases
build_fake_cache

# === Cases 6-9: 5-guard whitelist ===
run_case "6-guard-migration" \
    "$ROOT/supabase/migrations/00400_x.sql" \
    "guard_skip"

run_case "7-guard-secret" \
    "$ROOT/secrets/anthropic.txt" \
    "guard_skip"

run_case "8-guard-edge-fn" \
    "$ROOT/supabase/functions/notify/index.ts" \
    "guard_skip"

run_case "9-guard-billing" \
    "$ROOT/apps/web/src/lib/billing/stripe-client.ts" \
    "guard_skip"

# === Cases 10-12: silent skip (scope filter / skip patterns) ===
run_case "10-types-dir-skip" \
    "$ROOT/apps/web/src/types/api.ts" \
    "silent_skip"

run_case "11-locales-json-skip" \
    "$ROOT/apps/web/src/locales/en.json" \
    "silent_skip"

run_case "12-apps-app-scope-skip" \
    "$ROOT/apps/app/src/Home.tsx" \
    "silent_skip"

echo ""
echo "=== Result: $PASS/$((PASS+FAIL)) PASS ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failed cases:"
    for c in "${FAILED_CASES[@]}"; do echo "  - $c"; done
    exit 1
fi
exit 0
