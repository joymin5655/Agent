#!/usr/bin/env bash
# telemetry-digest.sh — pillar④ janitor step 1 (P1-5): summarize
# core/hooks/supervisor.py's .agent/logs/supervisor.jsonl into action/specialist
# statistics and a rule-candidate report. Read-only — never mutates the log or
# any other file, and never re-derives ghost status or re-reads the registry;
# it only aggregates what supervisor.py already logged.
#
# Usage:
#   bash core/infra/telemetry-digest.sh                # reads $AGENT_TELEMETRY_LOG or
#                                                       # <repo-root>/.agent/logs/supervisor.jsonl
#   bash core/infra/telemetry-digest.sh <path-to-log>  # reads an explicit file (e.g. a
#                                                       # sample/fixture log for testing)
#
# Env:
#   AGENT_TELEMETRY_LOG       — override the default log path (ignored if a path arg is given)
#   AGENT_TELEMETRY_MIN_ASKS  — ask-count threshold for the NO-ACCEPT rule candidate
#                               below (default 3)
#
# Rule candidates (heuristics derived ONLY from already-logged actions):
#   - GHOST      a specialist logged action=="ghost" >=1 time — the registry
#                references an agent id with no sibling agents/<id>.md.
#   - NO-ACCEPT  a specialist was asked (ask-intent + ask-security) >= threshold
#                times but was never actually dispatched — the keyword may be
#                over-matching (rules/policy/specialist-routing.md Lesson 1).
#
# A malformed line in the log is skipped, never fatal — this tool degrades
# gracefully and never crashes on a corrupt log (a single `jq .` pass over the
# whole file would abort on the first parse error and silently drop every
# line after it, so lines are validated one at a time instead).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_PATH="${1:-${AGENT_TELEMETRY_LOG:-$REPO_ROOT/.agent/logs/supervisor.jsonl}}"
MIN_ASKS="${AGENT_TELEMETRY_MIN_ASKS:-3}"

echo "=== Telemetry Digest — supervisor.jsonl ==="
echo "source: $LOG_PATH"
echo

if [[ ! -f "$LOG_PATH" ]]; then
    echo "(no log file — no supervisor events recorded yet)"
    echo
    echo "digest: 0 events, 0 specialists, 0 rule candidate(s)"
    exit 0
fi

VALID_JSON="$(
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        echo "$line" | jq -c . 2>/dev/null || true
    done < "$LOG_PATH"
)"

if [[ -z "$VALID_JSON" ]]; then
    echo "(log file present but empty / no valid JSON lines)"
    echo
    echo "digest: 0 events, 0 specialists, 0 rule candidate(s)"
    exit 0
fi

SUMMARY_JSON="$(printf '%s\n' "$VALID_JSON" | jq -s --argjson min_asks "$MIN_ASKS" '
    {
        total: length,
        actions: (
            group_by(.action // "unknown")
            | map({key: (.[0].action // "unknown"), value: length})
            | sort_by(.key)
            | from_entries
        ),
        specialists: (
            [.[] | select(.specialist != null and .specialist != "")]
            | group_by(.specialist)
            | map({
                specialist: .[0].specialist,
                total: length,
                by_action: (
                    group_by(.action // "unknown")
                    | map({key: (.[0].action // "unknown"), value: length})
                    | from_entries
                )
              })
            | sort_by(.specialist)
        )
    }
    | . + {
        rule_candidates: (
            [.specialists[] | select((.by_action.ghost // 0) >= 1) | {
                type: "GHOST",
                specialist: .specialist,
                message: "specialist \(.specialist) matched as ghost \(.by_action.ghost) time(s) — no sibling agents/\(.specialist).md; add the agent or remove the registry entry"
            }]
            +
            [.specialists[]
                | ((.by_action["ask-intent"] // 0) + (.by_action["ask-security"] // 0)) as $asked
                | select($asked >= $min_asks and ((.by_action.dispatched // 0) == 0))
                | {
                    type: "NO-ACCEPT",
                    specialist: .specialist,
                    message: "specialist \(.specialist) asked \($asked) time(s), dispatched 0 — keyword may be over-matching; consider narrowing matches.keywords (specialist-routing.md Lesson 1)"
                  }]
        )
    }
')"

echo "-- by action --"
echo "$SUMMARY_JSON" | jq -r '.actions | to_entries[] | "  \(.key): \(.value)"'
echo
echo "-- by specialist --"
echo "$SUMMARY_JSON" | jq -r '.specialists[] | "  \(.specialist): " + ([.by_action | to_entries[] | "\(.key)=\(.value)"] | join(" "))'
echo
echo "-- rule candidates --"
N_CANDIDATES=$(echo "$SUMMARY_JSON" | jq '.rule_candidates | length')
if [[ "$N_CANDIDATES" -eq 0 ]]; then
    echo "  (none)"
else
    echo "$SUMMARY_JSON" | jq -r '.rule_candidates[] | "  [\(.type)] \(.message)"'
fi
echo

TOTAL=$(echo "$SUMMARY_JSON" | jq '.total')
N_SPECIALISTS=$(echo "$SUMMARY_JSON" | jq '.specialists | length')
echo "digest: $TOTAL events, $N_SPECIALISTS specialists, $N_CANDIDATES rule candidate(s)"
