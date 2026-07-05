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
#                times but was never actually dispatched — matches.keywords
#                and/or matches.file_globs may be over-matching
#                (rules/policy/specialist-routing.md Lesson 1).
#
# Known limitation: NO-ACCEPT only counts ask-intent/ask-security. A repo
# running with AGENT_SUPERVISOR_MODE=observe (supervisor.py's escape hatch)
# logs observe-intent/observe-security instead, so NO-ACCEPT cannot fire in
# that mode regardless of how noisy the matching is (GHOST is unaffected —
# ghost logging isn't mode-gated).
#
# A malformed line in the log is skipped, never fatal — this tool degrades
# gracefully and never crashes on a corrupt log. A single `jq .` pass over the
# whole file would abort on the first parse error and silently drop every line
# after it, so lines are parsed with `fromjson? // empty` instead (jq's `-R`
# raw-input mode treats each line as an independent parse — one bad line
# can't affect any other). Lines that parse but aren't a JSON object (a bare
# string/number/array — still syntactically valid JSON) are also dropped,
# since only objects can carry the `action`/`specialist` fields this script reads.
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

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq not found — telemetry-digest.sh requires jq to parse supervisor.jsonl." >&2
    exit 2
fi

VALID_JSON="$(jq -R -c 'fromjson? // empty | select(type == "object")' "$LOG_PATH")"

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
                | (.by_action["ask-intent"] // 0) as $intent_asks
                | (.by_action["ask-security"] // 0) as $security_asks
                | ($intent_asks + $security_asks) as $asked
                | select($asked >= $min_asks and ((.by_action.dispatched // 0) == 0))
                | {
                    type: "NO-ACCEPT",
                    specialist: .specialist,
                    message: (
                        "specialist \(.specialist) asked \($asked) time(s) (\($intent_asks) intent + \($security_asks) security), dispatched 0 — "
                        + (
                            if $intent_asks > 0 and $security_asks > 0 then
                                "matches.keywords and/or matches.file_globs may be over-matching; consider narrowing both"
                            elif $security_asks > 0 then
                                "matches.file_globs may be over-matching; consider narrowing it"
                            else
                                "matches.keywords may be over-matching; consider narrowing it"
                            end
                          )
                        + " (specialist-routing.md Lesson 1)"
                    )
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
