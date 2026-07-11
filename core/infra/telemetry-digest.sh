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
#   bash core/infra/telemetry-digest.sh --gates [--registry <md>] [--logs-dir <d>]
#                                       [--window <days>] [--fatigue <N>]
#                                       [--stale-days <N>] [--json]
#     Gate-registry mode (T-2). Cross-references docs/gate-registry.md against the
#     runtime firing logs (.agent/logs/*.jsonl) and reports per gate:
#       DEAD (0 in-window firings) / FATIGUE (firings >= --fatigue, default 50) /
#       STALE (last_reviewed + --stale-days, default 90, is past) /
#       UNINSTRUMENTED (gate emits a decision but writes no log — sink '-').
#     Still an OBSERVER (exit 0 always). --registry default: docs/gate-registry.md;
#     --logs-dir default: <repo-root>/.agent/logs. Env seams: AGENT_GATE_REGISTRY,
#     AGENT_GATE_LOGS_DIR.
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
GATES_MODE=0
REGISTRY_PATH=""
LOGS_DIR=""
FATIGUE_THRESHOLD=50
STALE_DAYS=90

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gates)
            GATES_MODE=1
            shift
            ;;
        --registry)
            REGISTRY_PATH="${2:-}"
            shift 2
            ;;
        --logs-dir)
            LOGS_DIR="${2:-}"
            shift 2
            ;;
        --fatigue)
            FATIGUE_THRESHOLD="${2:-50}"
            shift 2
            ;;
        --stale-days)
            STALE_DAYS="${2:-90}"
            shift 2
            ;;
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
            echo "       telemetry-digest.sh --gates [--registry <md>] [--logs-dir <d>] [--window <days>] [--fatigue <N>] [--stale-days <N>] [--json]" >&2
            exit 0
            ;;
        *)
            LOG_PATH="$1"
            shift
            ;;
    esac
done

if [[ "$GATES_MODE" -eq 1 ]]; then
    [[ -z "$REGISTRY_PATH" ]] && REGISTRY_PATH="${AGENT_GATE_REGISTRY:-$REPO_ROOT/docs/gate-registry.md}"
    [[ -z "$LOGS_DIR" ]] && LOGS_DIR="${AGENT_GATE_LOGS_DIR:-$REPO_ROOT/.agent/logs}"
    python3 - "$REGISTRY_PATH" "$LOGS_DIR" "$WINDOW_DAYS" "$FATIGUE_THRESHOLD" "$STALE_DAYS" "$JSON_MODE" <<'PY'
import sys, os, json, datetime, collections

registry_path, logs_dir = sys.argv[1], sys.argv[2]
try:
    window_days = int(sys.argv[3])
except Exception:
    window_days = 30
try:
    fatigue = int(sys.argv[4])
except Exception:
    fatigue = 50
try:
    stale_days = int(sys.argv[5])
except Exception:
    stale_days = 90
json_mode = sys.argv[6] == "1"

now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=window_days)


def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


# --- parse the registry machine block ---------------------------------------
gates = []
registry_error = None
try:
    with open(registry_path, encoding="utf-8") as f:
        text = f.read()
    in_block = False
    for line in text.splitlines():
        s = line.strip()
        if s == "<!-- gate-registry:begin -->":
            in_block = True
            continue
        if s == "<!-- gate-registry:end -->":
            in_block = False
            continue
        if not in_block or not s.startswith("GATE "):
            continue
        parts = [p.strip() for p in s[len("GATE "):].split("|")]
        if len(parts) < 7:
            continue
        gid, hook, decision, sink, match, last_reviewed = parts[:6]
        assumption = "|".join(parts[6:]).strip() if len(parts) > 6 else parts[6]
        gates.append({
            "id": gid, "hook": hook, "decision": decision, "sink": sink,
            "match": match, "last_reviewed": last_reviewed, "assumption": assumption,
        })
except Exception as e:
    registry_error = str(e)


# --- count in-window firings per sink, once per distinct sink ----------------
def count_sink(sink, match):
    """Return in-window firing count for (sink, match). match '*' counts every
    valid JSON-object line; otherwise counts lines whose guard field == match.
    The sink is confined to logs_dir: a registry line with a '../' traversal
    resolves outside and is refused (returns None — treated like an absent sink),
    so a bad registry entry can never make the digest read arbitrary files."""
    path = os.path.join(logs_dir, sink)
    real_logs = os.path.realpath(logs_dir)
    real_path = os.path.realpath(path)
    if real_path != real_logs and not real_path.startswith(real_logs + os.sep):
        return None
    n = 0
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if not isinstance(rec, dict):
                    continue
                # Test-reproduction records (batteries feeding synthetic events
                # to a hook) carry reproduce_test:true — they are not real gate
                # firings, so they must never inflate fire-rate / FATIGUE.
                if rec.get("reproduce_test") is True:
                    continue
                ts = parse_ts(rec.get("ts"))
                if ts is not None and ts < cutoff:
                    continue
                if match == "*" or rec.get("guard") == match:
                    n += 1
    except FileNotFoundError:
        return None            # sink absent — distinct from 0 firings
    except Exception:
        return None
    return n


reports = []
for g in gates:
    classes = []
    fired = None
    if g["sink"] == "-":
        classes.append("UNINSTRUMENTED")
    else:
        fired = count_sink(g["sink"], g["match"])
        if fired is None:
            classes.append("DEAD")          # sink never created == never fired
            fired = 0
        elif fired == 0:
            classes.append("DEAD")
        elif fired >= fatigue:
            classes.append("FATIGUE")
    lr = parse_ts(g["last_reviewed"] + "T00:00:00")
    if lr is not None and (now - lr).days > stale_days:
        classes.append("STALE")
    reports.append({
        "id": g["id"], "hook": g["hook"], "decision": g["decision"],
        "sink": g["sink"], "fired": fired, "last_reviewed": g["last_reviewed"],
        "flags": classes, "assumption": g["assumption"],
    })

flag_counts = collections.Counter(fl for r in reports for fl in r["flags"])
result = {
    "registry": registry_path,
    "registry_error": registry_error,
    "logs_dir": logs_dir,
    "window_days": window_days,
    "fatigue_threshold": fatigue,
    "stale_days": stale_days,
    "gates": len(gates),
    "flag_counts": dict(flag_counts),
    "reports": reports,
}

if json_mode:
    print(json.dumps(result))
else:
    print("=== Gate Registry Digest ===")
    print("registry: {}".format(registry_path))
    if registry_error:
        print("  registry error: {} (0 gates parsed)".format(registry_error))
    print("logs dir: {}".format(logs_dir))
    print("window: last {} day(s) | fatigue >= {} | stale > {} day(s)".format(
        window_days, fatigue, stale_days))
    print("gates: {}".format(len(gates)))
    print()
    print("-- per gate (fired-in-window / flags) --")
    if not reports:
        print("  (none — registry empty or unparseable)")
    for r in reports:
        fired = "n/a" if r["fired"] is None else r["fired"]
        flags = ", ".join(r["flags"]) if r["flags"] else "ok"
        print("  {:<20} {:<26} fired={:<5} reviewed={} [{}]".format(
            r["id"], r["hook"], str(fired), r["last_reviewed"], flags))
    print()
    print("-- flag summary --")
    if not flag_counts:
        print("  (all gates ok)")
    for fl in ("DEAD", "FATIGUE", "STALE", "UNINSTRUMENTED"):
        if flag_counts.get(fl):
            print("  {}: {}".format(fl, flag_counts[fl]))
    print()
    print("gate-digest: {} gate(s), {} DEAD, {} FATIGUE, {} STALE, {} UNINSTRUMENTED".format(
        len(gates), flag_counts.get("DEAD", 0), flag_counts.get("FATIGUE", 0),
        flag_counts.get("STALE", 0), flag_counts.get("UNINSTRUMENTED", 0)))
PY
    exit 0
fi

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
