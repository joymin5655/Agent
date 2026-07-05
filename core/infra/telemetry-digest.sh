#!/usr/bin/env bash
# telemetry-digest.sh — pillar④ janitor step 1 (P1-5): summarize
# core/hooks/supervisor.py's .agent/logs/supervisor.jsonl into action counts, a
# per-specialist funnel (match -> ask -> dispatched), top keywords, and a
# rule-candidate report. Read-only — never mutates the log or any other file,
# and never re-derives ghost status or re-reads the registry; it only
# aggregates what supervisor.py already logged.
#
# Dependencies: bash + python3 ONLY. No jq — jq is a WARN-tier (optional) tool
# per `setup.sh --doctor` (P1-7), so a janitor script cannot hard-depend on it.
# bash 3.2 compatible (macOS ships 3.2; no associative arrays, no `${var,,}`).
#
# Usage:
#   bash core/infra/telemetry-digest.sh [path] [--window <days>] [--json]
#     path            log file to read (default: $AGENT_TELEMETRY_LOG, else
#                     <repo-root>/.agent/logs/supervisor.jsonl)
#     --window <days> only consider records within the last N days (default 30)
#     --json          machine-readable JSON on stdout instead of the human report
#
# Rule candidates (heuristics derived ONLY from already-logged actions — never
# re-reads the registry or re-derives ghost status):
#   - NO-ACCEPT     a specialist was asked (ask-intent + ask-security) >= 3
#                   times but was never dispatched — matches.keywords and/or
#                   matches.file_globs may be over-matching (P1-4 Lesson 1).
#   - GHOST         a specialist logged action=="ghost" >=1 time — the registry
#                   references an agent id with no sibling agents/<id>.md.
#   - OVER-GENERAL  a single keyword accounts for >70% of all `match` records
#                   (only evaluated once total matches >= 3, to avoid flagging
#                   tiny samples where one keyword trivially dominates).
#   - INACTIVE      zero in-window records (or the log file is missing) —
#                   telemetry isn't flowing yet; check supervisor wiring
#                   (see setup.sh --doctor). Not an error: exit is still 0.
#
# Known limitation: NO-ACCEPT only counts ask-intent/ask-security. A repo
# running with AGENT_SUPERVISOR_MODE=observe logs observe-intent/observe-security
# instead, so NO-ACCEPT cannot fire in that mode (GHOST is unaffected — ghost
# logging isn't mode-gated).
#
# Exit code: ALWAYS 0. This is an observer, not a gate — a malformed log, a
# missing file, or an internal parse hiccup must never fail a session or CI.
# Every line that isn't valid-JSON-object is skipped and counted, never fatal.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

LOG_PATH=""
WINDOW_DAYS=30
JSON_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window)
            WINDOW_DAYS="${2:-30}"
            shift 2
            ;;
        --json)
            JSON_MODE=1
            shift
            ;;
        -h|--help)
            echo "usage: telemetry-digest.sh [path] [--window <days>] [--json]" >&2
            exit 0
            ;;
        *)
            LOG_PATH="$1"
            shift
            ;;
    esac
done

if [[ -z "$LOG_PATH" ]]; then
    LOG_PATH="${AGENT_TELEMETRY_LOG:-$REPO_ROOT/.agent/logs/supervisor.jsonl}"
fi

python3 - "$LOG_PATH" "$WINDOW_DAYS" "$JSON_MODE" <<'PY'
import sys
import json
import datetime
import collections

MIN_KEYWORD_SAMPLE = 3     # OVER-GENERAL is only evaluated once matches >= this
NO_ACCEPT_THRESHOLD = 3     # ask-intent + ask-security >= this, dispatched == 0
OVER_GENERAL_RATIO = 0.70   # a single keyword's share of all matches, exclusive


def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.datetime.fromisoformat(value)
    except Exception:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def main():
    log_path = sys.argv[1]
    try:
        window_days = int(sys.argv[2])
    except Exception:
        window_days = 30
    json_mode = sys.argv[3] == "1"

    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(days=window_days)

    try:
        with open(log_path, "r", encoding="utf-8") as f:
            raw_lines = f.readlines()
        file_missing = False
    except Exception:
        raw_lines = []
        file_missing = True

    records = []
    skipped = 0
    excluded = 0

    for line in raw_lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            skipped += 1
            continue
        if not isinstance(rec, dict):
            skipped += 1
            continue
        ts = parse_ts(rec.get("ts"))
        if ts is not None and ts < cutoff:
            excluded += 1
            continue
        records.append(rec)

    action_counts = collections.Counter()
    specialist_stats = {}  # id -> {"match":N, "ask":N, "dispatched":N, "ghost":N}
    keyword_counts = collections.Counter()
    sessions = set()

    for rec in records:
        action = rec.get("action") or "unknown"
        action_counts[action] += 1

        sid = rec.get("session_id")
        if sid:
            sessions.add(sid)

        spec = rec.get("specialist")
        if not spec:
            continue
        st = specialist_stats.setdefault(
            spec, {"match": 0, "ask": 0, "dispatched": 0, "ghost": 0}
        )
        if action == "match":
            st["match"] += 1
            kw = rec.get("keyword")
            if kw:
                keyword_counts[kw] += 1
        elif action in ("ask-intent", "ask-security"):
            st["ask"] += 1
        elif action == "dispatched":
            st["dispatched"] += 1
        elif action == "ghost":
            st["ghost"] += 1

    total_matches = sum(st["match"] for st in specialist_stats.values())
    total_asks = sum(st["ask"] for st in specialist_stats.values())
    total_dispatched = sum(st["dispatched"] for st in specialist_stats.values())
    observe_count = action_counts.get("observe-intent", 0) + action_counts.get("observe-security", 0)

    rule_candidates = []
    for spec in sorted(specialist_stats):
        st = specialist_stats[spec]
        if st["ask"] >= NO_ACCEPT_THRESHOLD and st["dispatched"] == 0:
            rule_candidates.append({
                "type": "NO-ACCEPT",
                "specialist": spec,
                "message": (
                    "specialist {s} asked {a} time(s), dispatched 0 — "
                    "keyword anchoring may need review, or the agent isn't earning "
                    "trust once dispatched (P1-4 Lesson 1)"
                ).format(s=spec, a=st["ask"]),
            })
        if st["ghost"] >= 1:
            rule_candidates.append({
                "type": "GHOST",
                "specialist": spec,
                "message": (
                    "specialist {s} matched as ghost {g} time(s) — registry references "
                    "an agent with no sibling agents/{s}.md; add the agent or remove "
                    "the registry entry"
                ).format(s=spec, g=st["ghost"]),
            })

    if keyword_counts and total_matches >= MIN_KEYWORD_SAMPLE:
        top_kw, top_count = keyword_counts.most_common(1)[0]
        ratio = top_count / total_matches
        if ratio > OVER_GENERAL_RATIO:
            rule_candidates.append({
                "type": "OVER-GENERAL",
                "keyword": top_kw,
                "message": (
                    "keyword '{k}' accounts for {c}/{t} ({r:.0f}%) of all matches — "
                    "may be over-general; consider narrowing it"
                ).format(k=top_kw, c=top_count, t=total_matches, r=ratio * 100),
            })

    if not records:
        rule_candidates.append({
            "type": "INACTIVE",
            "message": "telemetry not active — no in-window records; check supervisor wiring (see setup.sh --doctor)",
        })

    result = {
        "source": log_path,
        "file_missing": file_missing,
        "window_days": window_days,
        "cutoff": cutoff.isoformat(),
        "records": len(records),
        "sessions": len(sessions),
        "excluded_by_window": excluded,
        "skipped_malformed": skipped,
        "action_counts": dict(action_counts),
        "observe_only_count": observe_count,
        "specialist_funnel": [
            {
                "specialist": spec,
                "match": specialist_stats[spec]["match"],
                "ask": specialist_stats[spec]["ask"],
                "dispatched": specialist_stats[spec]["dispatched"],
                "conversion_pct": (
                    round(100.0 * specialist_stats[spec]["dispatched"] / specialist_stats[spec]["ask"], 1)
                    if specialist_stats[spec]["ask"] > 0 else None
                ),
            }
            for spec in sorted(specialist_stats)
        ],
        "top_keywords": [
            {"keyword": kw, "count": cnt} for kw, cnt in keyword_counts.most_common(10)
        ],
        "rule_candidates": rule_candidates,
        "summary": {
            "records": len(records),
            "asks": total_asks,
            "dispatched": total_dispatched,
            "candidates": len(rule_candidates),
        },
    }

    if json_mode:
        print(json.dumps(result))
        return

    print("=== Telemetry Digest — supervisor.jsonl ===")
    print("source: {}".format(log_path))
    print("window: last {} day(s) (cutoff: {})".format(window_days, cutoff.isoformat()))
    print(
        "records: {} (excluded by window: {}, skipped malformed: {})".format(
            len(records), excluded, skipped
        )
    )
    print("sessions: {}".format(len(sessions)))
    print()

    print("-- by action --")
    for action in sorted(action_counts):
        print("  {}: {}".format(action, action_counts[action]))
    print("  observe (advisory-only, intent+security): {}".format(observe_count))
    print()

    print("-- specialist funnel (match -> ask -> dispatched) --")
    if not specialist_stats:
        print("  (none)")
    else:
        for spec in sorted(specialist_stats):
            st = specialist_stats[spec]
            conv = (
                "{:.0f}%".format(100.0 * st["dispatched"] / st["ask"])
                if st["ask"] > 0 else "n/a"
            )
            print(
                "  {}: match={} ask={} dispatched={} (conversion: {})".format(
                    spec, st["match"], st["ask"], st["dispatched"], conv
                )
            )
    print()

    print("-- top keywords --")
    if not keyword_counts:
        print("  (none)")
    else:
        for kw, cnt in keyword_counts.most_common(10):
            print('  "{}": {} match(es)'.format(kw, cnt))
    print()

    print("-- rule candidates --")
    if not rule_candidates:
        print("  (none)")
    else:
        for cand in rule_candidates:
            print("  [{}] {}".format(cand["type"], cand["message"]))
    print()

    print(
        "digest: {} records, {} asks, {} dispatched, {} candidates".format(
            len(records), total_asks, total_dispatched, len(rule_candidates)
        )
    )


try:
    main()
except Exception as exc:
    # Absolute fail-safe — the janitor is an observer, never a gate. An
    # unexpected internal error still reports something rather than crashing.
    print("telemetry-digest: internal error ({}) — treating as inactive".format(exc), file=sys.stderr)
    print("digest: 0 records, 0 asks, 0 dispatched, 0 candidates")
PY

# Always exit 0 regardless of the python3 process's own exit status — this
# tool is an observer, not a gate (see header).
exit 0
