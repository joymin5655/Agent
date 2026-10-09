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
#     AGENT_GATE_LOGS_DIR. Also reports a per-gate block-rate table (W1-5:
#     fired/blocked/rate%, blocked = records with decision=="deny").
#
#     X-5: --projects <p1:p2> adds each project root's .agent/logs (or a path already
#     ending in .agent/logs) to the sweep; per-gate firings are summed, JSON carries
#     by_project. The flag MERGES with env AGENT_GATE_PROJECTS (union, not override);
#     entries are deduped by realpath and a missing logs dir warns on stderr.
#     The report ends with fixture-rows-excluded: in-window rows dropped as
#     reproduce_test or origin!=session, counted once per distinct sink file.
#     Writers redirect test output with AGENT_GATE_SINK_DIR (see verify-all.sh).
#     AG9: runners also export AGENT_GATE_SINK_TEST_RUN=<same path>; AGENT_GATE_SINK_DIR set
#     WITHOUT that matching marker = live-config pollution -> one stderr WARN line (all modes),
#     a `sink-override:` line in the --gates report and "sink_override" in --json. Exit stays 0.
#
#     W1-5 origin filter (applies to --gates AND --model): both modes count only
#     records whose `origin` field is "session" or ABSENT (a legacy pre-W1-4
#     record — kept, not lost); origin=="test" (this repo's own
#     core/tests/verify-all.sh exports AGENT_LOG_ORIGIN=test) is test-battery
#     noise and is excluded entirely, so running the test suite never inflates
#     a gate's FATIGUE/block-rate or the model-routing spend report.
#
#   bash core/infra/telemetry-digest.sh --model [--routing-log <path>]
#                                       [--model-registry <path>] [--json]
#     Model-economics mode (W-B). Reads .agent/logs/model-routing.jsonl (the
#     same sink core/infra/manager-audit.sh's routing-waste/token-spend lanes
#     read) and reports a verdict distribution (override / pinned_specialist /
#     inherit_top) plus relative spend by tier, reusing manager-audit.sh's
#     tier-multiplier weighting (LOW=0.15 MID=1 TOP=3.5, docs/model-routing.md
#     midpoints — not prices). This is a global sweep (no --session/--since
#     scoping — that's manager-audit's job for a single run). Missing log ->
#     LOUD SKIP (stderr + skip:true/"SKIP" in the report), never a silent pass
#     (same discipline as this repo's gitleaks-absent convention). --routing-log
#     default: $AGENT_MODEL_ROUTING_SINK or <repo-root>/.agent/logs/model-routing.jsonl.
#     --model-registry default: $AGENT_REGISTRY_PATH or <repo-root>/agents/master-registry.json
#     (resolves pinned_specialist dispatches with no explicit model). Env seams:
#     AGENT_MODEL_ROUTING_SINK, AGENT_REGISTRY_PATH, AGENT_TIER_ALIASES (same
#     names manager-audit.sh uses — one routing log, one set of seams).
#
#   bash core/infra/telemetry-digest.sh --review [--window <days>] [--json]
#     Review-completeness mode (V-6): how often is a review Claude-only? Observer, exit 0.
#     Metrics (a source missing or empty in-window prints "no data"; JSON gives
#     null + "measured": false — unmeasured is never reported as 0%):
#       solo ratio  over ~/.agent/workers/<project-key>/reviews.jsonl rows with a
#                   non-null diff_key, group by (project dir, diff_key); a group is
#                   "solo" when it has no external-complete row. ratio = solo/groups.
#                   External complete = status=="complete", vendor not null/""/
#                   "anthropic", role not starting "advisor" (the rule of
#                   review-evidence.py has_external_complete; parity-tested).
#       lanes       per role from council-lanes.jsonl: complete/total, status
#                   breakdown, mean duration_s (complete rows, and all rows).
#       overrides   review-override.jsonl count + per project_key; reason/user are
#                   never printed.
#       context     Claude code-reviewer dispatches beside the external-complete
#                   lane-row count. One record kind is counted per dispatch: the
#                   PreToolUse gate row of model-routing.jsonl (`subagent_type`
#                   containing "code-reviewer", no `event`, source != "post_tool_use");
#                   the PostToolUse and SubagentStart/Stop rows of the same dispatch
#                   are not counted. The two counts have no shared session id, so no
#                   ratio is computed. A routing log with only test-origin rows is
#                   "no data", not 0.
#       main tier   tier/model distribution of session-tier.jsonl (session start rows).
#     Rows outside --window are dropped BEFORE grouping, so the solo rule is the
#     window-scoped variant of has_external_complete (an external review older than
#     the window no longer rescues a diff_key). Rows with an unparseable ts are kept.
#     The W1-5 origin filter below also applies here (routing/session-tier rows).
#     An analysis crash prints a loud skip (JSON "error" key), never a traceback.
#     Env seams: AGENT_WORKERS_ROOT (default ~/.agent/workers), AGENT_LOGS_DIR
#     (default ~/.agent/logs), AGENT_MODEL_ROUTING_SINK, AGENT_SESSION_TIER_SINK.
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
MODEL_MODE=0
ROUTING_LOG_PATH=""
MODEL_REGISTRY_PATH=""
REVIEW_MODE=0
PROJECTS_ARG="${AGENT_GATE_PROJECTS:-}"
WORKERS_ROOT="${AGENT_WORKERS_ROOT:-$HOME/.agent/workers}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gates)
            GATES_MODE=1
            shift
            ;;
        --model)
            MODEL_MODE=1
            shift
            ;;
        --review)
            REVIEW_MODE=1
            shift
            ;;
        --routing-log)
            ROUTING_LOG_PATH="${2:-}"
            shift 2
            ;;
        --model-registry)
            MODEL_REGISTRY_PATH="${2:-}"
            shift 2
            ;;
        --registry)
            REGISTRY_PATH="${2:-}"
            shift 2
            ;;
        --logs-dir)
            LOGS_DIR="${2:-}"
            shift 2
            ;;
        --projects)
            # MERGES with AGENT_GATE_PROJECTS (union, deduped by realpath). `shift 2`
            # alone never advances when the value is missing, so guard it.
            if [[ $# -ge 2 && "$2" != --* ]]; then
                PROJECTS_ARG="${PROJECTS_ARG:+$PROJECTS_ARG:}$2"
                shift 2
            else
                echo "telemetry-digest: --projects needs a value (p1:p2) — ignored" >&2
                shift
            fi
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
            echo "       telemetry-digest.sh --gates [--registry <md>] [--logs-dir <d>] [--projects <p1:p2>, merged with \$AGENT_GATE_PROJECTS] [--window <days>] [--fatigue <N>] [--stale-days <N>] [--json]" >&2
            echo "       telemetry-digest.sh --model [--routing-log <path>] [--model-registry <path>] [--json]" >&2
            echo "       telemetry-digest.sh --review [--window <days>] [--json]" >&2
            exit 0
            ;;
        *)
            LOG_PATH="$1"
            shift
            ;;
    esac
done

# AG9: AGENT_GATE_SINK_DIR diverts gate records away from the live sinks this digest reads.
# A test runner sets it together with AGENT_GATE_SINK_TEST_RUN=<same path> (verify-all.sh);
# any other occurrence is live-config pollution (settings.json env block, shell profile) and
# the digest silently misses records. Warn only — never changes the exit code or any count.
# Limit: a sink dir + marker leaked TOGETHER with the same path look like a runner here;
# setup.sh --doctor's settings-file scan is what catches that case.
SINK_OVERRIDE=""
if [[ -n "${AGENT_GATE_SINK_DIR:-}" && "${AGENT_GATE_SINK_TEST_RUN:-}" != "$AGENT_GATE_SINK_DIR" ]]; then
    SINK_OVERRIDE="${AGENT_GATE_SINK_DIR//[^[:print:]]/?}"
    echo "telemetry-digest: WARN AGENT_GATE_SINK_DIR=$SINK_OVERRIDE is set outside a test runner — gate records written while it is set went to that dir and are missing from these counts (unset it; setup.sh --doctor finds where it is configured)" >&2
elif [[ -n "${AGENT_GATE_SINK_TEST_RUN:-}" && "${AGENT_GATE_SINK_DIR:-}" != "$AGENT_GATE_SINK_TEST_RUN" ]]; then
    echo "telemetry-digest: WARN AGENT_GATE_SINK_TEST_RUN=${AGENT_GATE_SINK_TEST_RUN//[^[:print:]]/?} is set without a matching AGENT_GATE_SINK_DIR — stale test-runner marker in the environment (unset it)" >&2
fi

if [[ "$GATES_MODE" -eq 1 ]]; then
    [[ -z "$REGISTRY_PATH" ]] && REGISTRY_PATH="${AGENT_GATE_REGISTRY:-$REPO_ROOT/docs/gate-registry.md}"
    [[ -z "$LOGS_DIR" ]] && LOGS_DIR="${AGENT_GATE_LOGS_DIR:-$REPO_ROOT/.agent/logs}"
    python3 - "$REGISTRY_PATH" "$LOGS_DIR" "$WINDOW_DAYS" "$FATIGUE_THRESHOLD" "$STALE_DAYS" "$JSON_MODE" "$PROJECTS_ARG" "$SINK_OVERRIDE" <<'PY'
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
sink_override = sys.argv[8] if len(sys.argv) > 8 else ""
# X-5: extra project roots (colon-separated); each contributes <root>/.agent/logs.
# An entry is a project root (<root>/.agent/logs is used) or a logs dir itself (path
# ending in .agent/logs). Duplicates (same realpath: p1:p1, symlinks, env+flag) are
# dropped so no sink is counted twice; a missing dir warns on stderr.
project_dirs = []
all_dirs = [logs_dir]
_seen = {os.path.realpath(logs_dir)}
for _p in (sys.argv[7].split(":") if len(sys.argv) > 7 else []):
    if not _p:
        continue
    # path-component match, so "foo.agent/logs" is a project root, not a logs dir
    _d = _p if os.path.normpath(_p).split(os.sep)[-2:] == [".agent", "logs"] \
        else os.path.join(_p, ".agent", "logs")
    if not os.path.isdir(_d):
        sys.stderr.write("telemetry-digest: --projects entry has no logs dir, skipped: {}\n".format(_d))
        continue
    _r = os.path.realpath(_d)
    if _r in _seen:
        continue
    _seen.add(_r)
    project_dirs.append(_d)
    all_dirs.append(_d)

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
def count_sink(sink, match, hook):
    """Return (fired, suppressed, blocked, excluded, by_project) in-window counts
    for (sink, match, hook), summed over every dir in all_dirs (X-5 cross-project
    sweep). suppressed = matching reproduce_test rows; excluded = matching rows
    whose origin is neither "session" nor absent (test-battery fixtures). Both
    are TALLIED, never silently dropped, so the digest can report how much
    fixture noise it removed. Returns None when NO dir has the sink (absent !=
    0 firings). match '*' counts every valid JSON-object line; otherwise lines
    whose guard field == match. A record carrying a `hook` field must equal the
    registry hook (two gates sharing one sink+guard would otherwise double-count);
    records without one keep matching on guard alone.
    Each sink is confined to its dir: a registry '../' traversal is refused.
    `blocked` = firings whose decision == "deny"."""
    n = suppressed = blocked = excluded = 0
    by_project = {}
    found = False
    seen_files = set()
    for d in all_dirs:
        path = os.path.join(d, sink)
        real_logs = os.path.realpath(d)
        real_path = os.path.realpath(path)
        if real_path != real_logs and not real_path.startswith(real_logs + os.sep):
            continue
        # distinct dirs may reach one sink file through an in-tree symlink: count it once
        if real_path in seen_files:
            continue
        seen_files.add(real_path)
        pn = 0
        try:
            with open(path, encoding="utf-8") as f:
                found = True
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
                    ts = parse_ts(rec.get("ts"))
                    if ts is not None and ts < cutoff:
                        continue
                    if match != "*" and rec.get("guard") != match:
                        continue
                    rec_hook = rec.get("hook")
                    if rec_hook is not None and rec_hook != hook:
                        continue
                    if rec.get("reproduce_test") is True:
                        suppressed += 1
                        continue
                    origin = rec.get("origin")
                    if not (origin is None or origin == "session"):
                        excluded += 1
                        continue
                    n += 1
                    pn += 1
                    if rec.get("decision") == "deny":
                        blocked += 1
        except Exception:
            continue           # sink absent/unreadable in this dir
        by_project[d] = pn
    if not found:
        return None
    return n, suppressed, blocked, excluded, by_project


def fixture_rows_total():
    """Distinct-sink fixture tally (each file once, so gates sharing a sink are
    not double-counted): rows excluded as reproduce_test or origin != session."""
    seen = set()
    total = 0
    for g in gates:
        if g["sink"] == "-":
            continue
        for d in all_dirs:
            path = os.path.join(d, g["sink"])
            real = os.path.realpath(path)
            real_logs = os.path.realpath(d)
            if real in seen or not (real == real_logs or real.startswith(real_logs + os.sep)):
                continue
            seen.add(real)
            try:
                with open(path, encoding="utf-8") as f:
                    for line in f:
                        try:
                            rec = json.loads(line)
                        except Exception:
                            continue
                        if not isinstance(rec, dict):
                            continue
                        ts = parse_ts(rec.get("ts"))
                        if ts is not None and ts < cutoff:
                            continue
                        origin = rec.get("origin")
                        if rec.get("reproduce_test") is True or not (origin is None or origin == "session"):
                            total += 1
            except Exception:
                continue
    return total


reports = []
for g in gates:
    classes = []
    fired = None
    suppressed = 0
    blocked = 0
    excluded = 0
    by_project = {}
    if g["sink"] == "-":
        classes.append("UNINSTRUMENTED")
    else:
        counts = count_sink(g["sink"], g["match"], g["hook"])
        if counts is None:
            classes.append("DEAD")          # sink never created == never fired
            fired = 0
        else:
            fired, suppressed, blocked, excluded, by_project = counts
            if fired == 0:
                classes.append("DEAD")
            elif fired >= fatigue:
                classes.append("FATIGUE")
    lr = parse_ts(g["last_reviewed"] + "T00:00:00")
    if lr is not None and (now - lr).days > stale_days:
        classes.append("STALE")
    block_rate = round(100.0 * blocked / fired, 1) if fired else None
    reports.append({
        "id": g["id"], "hook": g["hook"], "decision": g["decision"],
        "sink": g["sink"], "fired": fired, "suppressed": suppressed,
        "blocked": blocked, "block_rate": block_rate,
        "excluded": excluded, "by_project": by_project,
        "last_reviewed": g["last_reviewed"],
        "flags": classes, "assumption": g["assumption"],
    })

flag_counts = collections.Counter(fl for r in reports for fl in r["flags"])
result = {
    "registry": registry_path,
    "registry_error": registry_error,
    "logs_dir": logs_dir,
    "project_logs_dirs": project_dirs,
    "fixture_rows_excluded": fixture_rows_total(),
    "sink_override": sink_override or None,
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
    for d in project_dirs:
        print("project logs dir: {}".format(d))
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
        # suppressed shown only when non-zero: a real-session env leak
        # (lingering AGENT_REPRODUCE_TEST=1) surfaces as an anomaly here.
        sup = " suppressed={}".format(r["suppressed"]) if r.get("suppressed") else ""
        print("  {:<20} {:<26} fired={:<5} reviewed={} [{}]{}".format(
            r["id"], r["hook"], str(fired), r["last_reviewed"], flags, sup))
        if len(all_dirs) > 1 and r["by_project"]:
            print("      by logs dir: " + ", ".join(
                "{}={}".format(d, c) for d, c in r["by_project"].items()))
    print()
    print("-- flag summary --")
    if not flag_counts:
        print("  (all gates ok)")
    for fl in ("DEAD", "FATIGUE", "STALE", "UNINSTRUMENTED"):
        if flag_counts.get(fl):
            print("  {}: {}".format(fl, flag_counts[fl]))
    print()
    # W1-5: block rate by gate (session-origin firings only, see count_sink).
    print("-- block rate by gate --")
    if not reports:
        print("  (none)")
    for r in reports:
        if r["fired"]:
            rate_str = "{}%".format(r["block_rate"])
        else:
            rate_str = "n/a"
        print("  {:<20} fired={:<5} blocked={:<5} rate={}".format(
            r["id"], r["fired"] if r["fired"] is not None else 0, r["blocked"], rate_str))
    print()
    # X-5: how much fixture noise was removed from the inputs above.
    print("-- fixture rows excluded --")
    print("fixture-rows-excluded: {} (reproduce_test or origin!=session, in-window, distinct sinks)".format(
        result["fixture_rows_excluded"]))
    print()
    print("-- gate sink override --")
    if sink_override:
        print("sink-override: WARN AGENT_GATE_SINK_DIR={} (outside a test runner; gate records written while it is set are missing from these counts)".format(sink_override))
    else:
        print("sink-override: none")
    print()
    print("gate-digest: {} gate(s), {} DEAD, {} FATIGUE, {} STALE, {} UNINSTRUMENTED".format(
        len(gates), flag_counts.get("DEAD", 0), flag_counts.get("FATIGUE", 0),
        flag_counts.get("STALE", 0), flag_counts.get("UNINSTRUMENTED", 0)))
PY
    exit 0
fi

if [[ "$MODEL_MODE" -eq 1 ]]; then
    [[ -z "$ROUTING_LOG_PATH" ]] && ROUTING_LOG_PATH="${AGENT_MODEL_ROUTING_SINK:-$REPO_ROOT/.agent/logs/model-routing.jsonl}"
    [[ -z "$MODEL_REGISTRY_PATH" ]] && MODEL_REGISTRY_PATH="${AGENT_REGISTRY_PATH:-$REPO_ROOT/agents/master-registry.json}"
    # LOUD SKIP — a missing routing log reported as a quiet pass is exactly the
    # false-green this repo's gitleaks-absent convention guards against.
    if [[ ! -f "$ROUTING_LOG_PATH" ]]; then
        echo "SKIP — no model-routing log at $ROUTING_LOG_PATH (model-routing-observer hook not firing?) — loud skip, not a silent pass" >&2
        if [[ "$JSON_MODE" -eq 1 ]]; then
            src_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$ROUTING_LOG_PATH")
            printf '{"source": %s, "skip": true, "records": 0}\n' "$src_json"
        else
            echo "model-digest: SKIP (0 records — log absent)"
        fi
        exit 0
    fi
    python3 - "$ROUTING_LOG_PATH" "$MODEL_REGISTRY_PATH" "$JSON_MODE" <<'PY'
import sys, os, re, json, collections

routing_log, registry_path, json_mode_flag = sys.argv[1], sys.argv[2], sys.argv[3]
json_mode = json_mode_flag == "1"

# Log-derived strings (subagent_type/model/verdict) are untrusted: a forged
# routing.jsonl record could carry "\n" or ANSI/control sequences aimed at
# faking extra lines in the text report (CWE-117 — the report is what a
# human, or /supervise Step 5, reads and copies into RECORD.md). Applied to
# TEXT-mode rendering only; the JSON output already escapes control chars
# via json.dumps and is meant to carry the raw values for machine consumers.
_SAFE_CHARS = re.compile(r"[^A-Za-z0-9:._-]")
_MAX_FIELD_LEN = 80


def sanitize_field(s):
    s = s if isinstance(s, str) else str(s)
    return _SAFE_CHARS.sub("?", s[:_MAX_FIELD_LEN])


def main():
    # same alias seam as manager-audit.sh: "model=TIER,..." exact-string overrides
    aliases = {}
    for pair in os.environ.get("AGENT_TIER_ALIASES", "").split(","):
        if "=" in pair:
            k, v = pair.split("=", 1)
            if k:
                aliases[k] = v

    # optional pinned_specialist -> model resolution, same shape manager-audit.sh
    # reads (agents/master-registry.json: {"agents": [{"id":..., "model":...}]})
    registry = {}
    try:
        with open(registry_path, encoding="utf-8") as f:
            reg = json.load(f)
        agents = reg.get("agents", reg) if isinstance(reg, dict) else reg
        if isinstance(agents, list):
            for a in agents:
                if isinstance(a, dict) and a.get("id"):
                    m = a.get("model")
                    registry[a["id"]] = m if isinstance(m, str) else ""
    except Exception:
        registry = {}

    MULT = {"LOW": 0.15, "MID": 1.0, "TOP": 3.5}

    def tier_of(model):
        if model.startswith("haiku"):
            return "LOW"
        if model.startswith("sonnet"):
            return "MID"
        if model.startswith("opus"):
            return "TOP"
        if aliases.get(model):
            return aliases[model]
        return "TOP"          # unknown/inherit = session top, same as manager-audit.sh

    def safe_num(v):
        # bool is a subclass of int in Python — exclude it explicitly so a
        # stray true/false in the log can't silently become 0/1 tokens.
        if isinstance(v, bool):
            return None
        if isinstance(v, (int, float)):
            return float(v)
        return None

    def build_record(rec):
        # Every field below is validated by TYPE before use — a malformed
        # record (wrong-typed verdict/model/subagent_type/total_tokens) is
        # rejected (caller counts it as skipped_malformed) instead of raising
        # AttributeError/TypeError, which would otherwise abort the whole
        # analysis after only a partial report — false-green (exit 0, thin
        # report) is exactly what this observer's own LOUD-SKIP discipline
        # forbids for a missing log, so a malformed record must not achieve
        # the same effect implicitly.
        verdict = rec.get("verdict")
        if verdict is None:
            verdict = "unknown"
        if not isinstance(verdict, str):
            return None
        model = rec.get("model")
        if model is None:
            model = ""
        if not isinstance(model, str):
            return None
        subagent = rec.get("subagent_type")
        if subagent is None:
            subagent = "unknown"
        if not isinstance(subagent, str):
            return None
        if not model and verdict == "pinned_specialist":
            model = registry.get(subagent.split(":")[-1], "") or ""
        tier = "TOP" if verdict == "inherit_top" else tier_of(model)
        total_tokens_raw = rec.get("total_tokens")
        if total_tokens_raw is not None:
            total_tokens = safe_num(total_tokens_raw)
            if total_tokens is None:
                return None
        else:
            prompt_chars_raw = rec.get("prompt_chars")
            if prompt_chars_raw is None:
                prompt_chars = 0.0
            else:
                prompt_chars = safe_num(prompt_chars_raw)
                if prompt_chars is None:
                    return None
            total_tokens = prompt_chars / 4.0
        rel_cost = total_tokens * MULT.get(tier, 1.0)
        return {
            "subagent_type": subagent, "verdict": verdict, "model": model,
            "tier": tier, "rel_cost": rel_cost,
        }

    try:
        with open(routing_log, encoding="utf-8") as f:
            raw_lines = f.readlines()
    except Exception:
        raw_lines = []

    records = []
    skipped = 0
    for line in raw_lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            skipped += 1
            continue
        if not isinstance(rec, dict) or rec.get("gate") != "model-routing-observer":
            continue
        # W1-5: same origin filter as count_sink() above — only origin=="session"
        # or a missing origin (legacy pre-W1-4 record) counts; origin=="test"
        # (verify-all.sh) is test-battery noise, excluded entirely.
        origin = rec.get("origin")
        if not (origin is None or origin == "session"):
            continue
        built = build_record(rec)
        if built is None:
            skipped += 1
            continue
        records.append(built)

    n = len(records)
    verdict_counts = collections.Counter(r["verdict"] for r in records)
    verdict_dist = [
        {"verdict": v, "count": c, "pct": round(100.0 * c / n, 1) if n else 0.0}
        for v, c in verdict_counts.most_common()
    ]

    total_cost = sum(r["rel_cost"] for r in records)
    tier_spend = collections.Counter()
    for r in records:
        tier_spend[r["tier"]] += r["rel_cost"]
    tier_spend_dist = [
        {"tier": t, "rel_cost": round(tier_spend[t], 1),
         "pct": round(100.0 * tier_spend[t] / total_cost, 1) if total_cost else 0.0}
        for t in ("LOW", "MID", "TOP") if t in tier_spend
    ]

    top_spend = sorted(records, key=lambda r: -r["rel_cost"])[:3]
    top_spend_labels = [
        "{} [{}] rel_cost={}".format(r["subagent_type"], r["tier"], int(r["rel_cost"]))
        for r in top_spend
    ]

    result = {
        "source": routing_log,
        "skip": False,
        "records": n,
        "skipped_malformed": skipped,
        "verdict_distribution": verdict_dist,
        "total_rel_cost": round(total_cost, 1),
        "tier_spend": tier_spend_dist,
        "top_spend_sources": top_spend_labels,
    }

    if json_mode:
        print(json.dumps(result))
    else:
        print("=== Model-Routing Digest — model-routing.jsonl ===")
        print("source: {}".format(routing_log))
        print("records: {} (skipped malformed: {})".format(n, skipped))
        print()
        print("-- verdict distribution --")
        if not verdict_dist:
            print("  (none)")
        for v in verdict_dist:
            print("  {}: {} ({}%)".format(sanitize_field(v["verdict"]), v["count"], v["pct"]))
        print()
        print("-- relative spend by tier (tokens x tier multiplier, LOW=0.15 MID=1 TOP=3.5) --")
        if not tier_spend_dist:
            print("  (none)")
        for t in tier_spend_dist:
            # t["tier"] is always LOW/MID/TOP (loop is over that fixed tuple) — no
            # log-derived data reaches here, so no sanitize_field needed.
            print("  {}: rel_cost={} ({}%)".format(t["tier"], t["rel_cost"], t["pct"]))
        print()
        print("-- top spend sources --")
        if not top_spend:
            print("  (none)")
        for r in top_spend:
            print("  {} [{}] rel_cost={}".format(
                sanitize_field(r["subagent_type"]), r["tier"], int(r["rel_cost"])))
        print()
        print("model-digest: {} record(s), total rel_cost={}".format(n, round(total_cost, 1)))


try:
    main()
except Exception as exc:
    # Outer fail-safe: an analysis-time crash must report the SAME way the
    # missing-log path does (LOUD SKIP), never a blank "0 records" success —
    # a thin report with rc=0 is the false-green this mode's own docstring
    # says the LOUD-SKIP discipline exists to prevent.
    print("model-digest: internal error ({}) — treating as skipped, not a clean pass".format(exc),
          file=sys.stderr)
    if json_mode:
        print(json.dumps({"source": routing_log, "skip": True, "records": 0, "error": str(exc)}))
    else:
        print("model-digest: SKIP (0 records — analysis error)")
PY
    exit 0
fi

if [[ "$REVIEW_MODE" -eq 1 ]]; then
    [[ -z "$ROUTING_LOG_PATH" ]] && ROUTING_LOG_PATH="${AGENT_MODEL_ROUTING_SINK:-$REPO_ROOT/.agent/logs/model-routing.jsonl}"
    review_out=$(python3 - "$WORKERS_ROOT" "${AGENT_LOGS_DIR:-$HOME/.agent/logs}" "$ROUTING_LOG_PATH" \
        "${AGENT_SESSION_TIER_SINK:-$REPO_ROOT/.agent/logs/session-tier.jsonl}" \
        "$WINDOW_DAYS" "$JSON_MODE" 2>/dev/null <<'PY'
import sys, os, json, datetime, collections

workers_root, logs_dir, routing_log, tier_log = sys.argv[1:5]
try:
    window_days = int(sys.argv[5])
except Exception:
    window_days = 30
json_mode = sys.argv[6] == "1"
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=window_days)
malformed = 0


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


def rows(path):
    """In-window JSON-object rows of one JSONL file, or None when it is absent.
    A row with no parseable ts is kept (legacy), same as the --gates counter."""
    global malformed
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    malformed += 1
                    continue
                if not isinstance(rec, dict):
                    malformed += 1
                    continue
                ts = parse_ts(rec.get("ts"))
                if ts is not None and ts < cutoff:
                    continue
                out.append(rec)
    except OSError:
        return None
    return out


def real_origin(rec):
    return rec.get("origin") in (None, "session")


def is_external_complete(row):
    # mirrors core/infra/review-evidence.py has_external_complete (parity-tested)
    return (row.get("status") == "complete"
            and not str(row.get("role") or "").startswith("advisor")
            and row.get("vendor") not in (None, "", "anthropic"))


def measured_or_none(rs):
    return rs is not None and len(rs) > 0


def label(value):
    return str(value)[:64]


# --- primary: solo ratio by (project dir, diff_key) --------------------------
groups = collections.OrderedDict()
try:
    projects = sorted(os.listdir(workers_root))
except OSError:
    projects = []
any_rows = False
for proj in projects:
    pdir = os.path.join(workers_root, proj)
    if not os.path.isdir(pdir):
        continue
    rs = rows(os.path.join(pdir, "reviews.jsonl")) or []
    for r in rs:
        key = r.get("diff_key")
        if not isinstance(key, str) or not key:
            continue
        any_rows = True
        groups.setdefault((proj, key), False)
        if is_external_complete(r):
            groups[(proj, key)] = True
solo = {"measured": any_rows, "groups": None, "solo_groups": None,
        "solo_ratio": None, "solo_pct": None}
if any_rows:
    n_groups = len(groups)
    n_solo = sum(1 for v in groups.values() if not v)
    solo.update(groups=n_groups, solo_groups=n_solo,
                solo_ratio=round(n_solo / n_groups, 4), solo_pct=round(100 * n_solo / n_groups, 1))

# --- per-lane success + duration (council-lanes.jsonl) -----------------------
lane_rows = rows(os.path.join(logs_dir, "council-lanes.jsonl"))
by_role = collections.OrderedDict()
lanes_measured = measured_or_none(lane_rows)
external_lanes = None
if lanes_measured:
    external_lanes = 0
    acc = collections.OrderedDict()
    for r in lane_rows:
        role = label(r.get("role") or "unknown")
        a = acc.setdefault(role, {"total": 0, "complete": 0, "statuses": collections.Counter(),
                                  "dur_all": [], "dur_ok": []})
        status = label(r.get("status") or "unknown")
        a["total"] += 1
        a["statuses"][status] += 1
        dur = r.get("duration_s")
        is_num = isinstance(dur, (int, float)) and not isinstance(dur, bool)
        if is_num and (dur != dur or dur in (float("inf"), float("-inf"))):
            is_num = False
        if status == "complete":
            a["complete"] += 1
            if is_num:
                a["dur_ok"].append(dur)
        if is_num:
            a["dur_all"].append(dur)
        if is_external_complete(r):
            external_lanes += 1
    for role, a in acc.items():
        mean = lambda xs: round(sum(xs) / len(xs), 2) if xs else None
        by_role[role] = {
            "total": a["total"], "complete": a["complete"],
            "success_rate": round(a["complete"] / a["total"], 4),
            "statuses": dict(a["statuses"]),
            "mean_duration_complete_s": mean(a["dur_ok"]),
            "mean_duration_all_s": mean(a["dur_all"]),
        }
lanes = {"measured": lanes_measured, "by_role": by_role}

# --- overrides: counts only, never reason/user -------------------------------
ov_rows = rows(os.path.join(logs_dir, "review-override.jsonl"))
ov_measured = measured_or_none(ov_rows)
ov_by = collections.Counter(label(r.get("project_key") or "unknown") for r in (ov_rows or []))
overrides = {"measured": ov_measured, "total": len(ov_rows) if ov_measured else None,
             "by_project": dict(ov_by) if ov_measured else {}}

# --- secondary context: Claude reviewer dispatches vs external lanes ---------
rt_rows = rows(routing_log)
rev = None
# one record kind per dispatch: the PreToolUse gate row (subagent_type, no `event`,
# source != "post_tool_use"). PostToolUse rows (source post_tool_use) and
# SubagentStart/Stop rows (agent_type, `event`) describe the same dispatch again.
rt_real = [r for r in (rt_rows or []) if real_origin(r)]
if rt_real:
    rev = sum(1 for r in rt_real
              if "event" not in r and r.get("source") != "post_tool_use"
              and "code-reviewer" in str(r.get("subagent_type") or ""))
context = {"measured": rev is not None and external_lanes is not None,
           "claude_code_reviewer_dispatches": rev, "external_complete_lanes": external_lanes,
           "caveat": "counts are not joinable (no shared session id); do not read as a ratio"}

# --- main model/tier distribution (session-tier.jsonl) -----------------------
st_rows = [r for r in (rows(tier_log) or []) if real_origin(r) and "tier" in r]
by_tier = collections.Counter(label(r.get("tier") or "unknown") for r in st_rows)
by_model = collections.Counter(label(r.get("model") or "unknown") for r in st_rows)
session_tier = {"measured": bool(st_rows), "total": len(st_rows) if st_rows else None,
                "by_tier": dict(by_tier), "by_model": dict(by_model)}

report = {"mode": "review", "window_days": window_days, "solo": solo, "context": context,
          "lanes": lanes, "overrides": overrides, "session_tier": session_tier,
          "skipped_malformed": malformed}

if json_mode:
    print(json.dumps(report, indent=2))
    sys.exit(0)

def fmt_mean(v):
    return "-" if v is None else v


print("review-digest (window: {}d)".format(window_days))
if solo["measured"]:
    print("solo ratio (diff_keys with no external-vendor complete review): {}/{} = {}%".format(
        solo["solo_groups"], solo["groups"], solo["solo_pct"]))
else:
    print("solo ratio: no data (no reviews.jsonl rows with a diff_key under {})".format(workers_root))
if context["measured"]:
    print("context: {} Claude code-reviewer dispatch(es) vs {} external-complete lane row(s) "
          "(no shared session id - not a ratio)".format(rev, external_lanes))
else:
    print("context: no data (needs both the routing log and council-lanes.jsonl; "
          "no shared session id - not a ratio)")
if lanes_measured:
    print("lanes:")
    for role, a in by_role.items():
        st = ", ".join("{}={}".format(k, v) for k, v in sorted(a["statuses"].items()))
        print("  {:<14} success {}/{} ({}%)  mean s: complete={} all={}  [{}]".format(
            role, a["complete"], a["total"], round(100 * a["success_rate"], 1),
            fmt_mean(a["mean_duration_complete_s"]), fmt_mean(a["mean_duration_all_s"]), st))
else:
    print("lanes: no data")
if ov_measured:
    per = ", ".join("{}={}".format(k, v) for k, v in sorted(ov_by.items()))
    print("overrides: {} ({})".format(overrides["total"], per))
else:
    print("overrides: no data")
if session_tier["measured"]:
    print("main tier: " + ", ".join("{}={}".format(k, v) for k, v in sorted(by_tier.items()))
          + "  model: " + ", ".join("{}={}".format(k, v) for k, v in sorted(by_model.items())))
else:
    print("main tier: no data")
if malformed:
    print("skipped {} malformed line(s)".format(malformed))
PY
    ) || {
        # same discipline as --model: an analysis crash is a loud skip, never a clean pass
        echo "review-digest: internal error — treating as unmeasured, not a clean pass" >&2
        if [[ "$JSON_MODE" -eq 1 ]]; then
            printf '{"mode": "review", "error": "internal error", "solo": {"measured": false}, "overrides": {"measured": false}}\n'
        else
            echo "review-digest: SKIP (analysis error)"
        fi
        exit 0
    }
    printf '%s\n' "$review_out"
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
