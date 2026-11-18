#!/usr/bin/env python3
"""model-routing-observer.py — measure the model-tier convention, don't enforce it.

Matcher: PostToolUse Task|Agent (registered after plan-gate.py / supervisor.py).

docs/model-routing.md pins only two specialists by frontmatter; every other
tier rule ("implementation dispatches at MID, fan-out at LOW, via a call-time
`model` override") is a convention CI cannot see. This observer makes that
convention measurable: one JSONL record per subagent dispatch, classified as

  override          — the dispatch carried an explicit tool_input.model
  pinned_specialist — subagent_type resolves to a master-registry agent id
                      (bare or plugin-namespaced); its frontmatter pin rules
  inherit_top       — neither: the dispatch inherits the session's top model.
                      This is the leak the observer exists to count.

Each record also carries a spend signal for downstream audits
(core/infra/manager-audit.sh):

  prompt_chars — len(tool_input.prompt); always present, deterministic proxy
  total_tokens — best-effort probe of tool_response usage; null when the
                 runtime doesn't surface usage on PostToolUse

Each record also carries origin (W1-4, hook_config.log_origin()): "session" by
default, or AGENT_LOG_ORIGIN's value verbatim (test runners export
AGENT_LOG_ORIGIN=test) — so a test-battery-produced record is distinguishable
from a real-session one downstream (telemetry-digest.sh --model).

W2-3: each record also carries the dispatch's effort budget and model tier:

  effort — tool_input.effort verbatim (e.g. "low"/"medium"/"high"/"max"), or
           null when the dispatch carried none (most dispatches today).
  tier   — TOP/MID/LOW/unknown for the EFFECTIVE model: the override's model
           when the verdict is "override", the registry's pinned model when
           "pinned_specialist", else "unknown" (an inherit_top dispatch's
           effective model is the session's, which this event can't see —
           session-tier-observer.py covers that side). Fable-family models
           classify TOP, same as opus (spec.md §7 Q3's TOP-F split) — this
           is what "any tier map must treat fable as TOP" means in practice:
           a fable-pinned specialist or `model: fable` override must not
           read as an under-tiered dispatch.

Verdict scope (inherit_top inflation fix): the 86% "inherit_top" headline was
mostly SubagentStart/SubagentStop lifecycle rows — each subagent writes two,
plus a PostToolUse row — and most of those carry an empty agent_type (Claude
Code's own internal agents). A lifecycle row only knows "agent_type is/isn't a
registry id", so a non-registry one is now "unclassified", not inherit_top; the
real dispatch verdict comes from the PostToolUse row. PostToolUse rows also
record resolved_model (tool_response.resolvedModel, null if absent) and
env_subagent_model (CLAUDE_CODE_SUBAGENT_MODEL as seen by the hook). The
verdict stays inherit_top there: the env var is NOT assumed to apply (a
header-less Plan agent was observed running the session's top model).

Measured runs: on SubagentStop one extra row goes to the user-level sink
(AGENT_SUBAGENT_RUNS_SINK, default ~/.agent/logs/subagent-runs.jsonl) built from
the subagent's own transcript (event.agent_transcript_path, else
<transcript_path minus .jsonl>/subagents/agent-<agent_id>.jsonl) and its
.meta.json: the model that actually answered, effort, turns, duration. No
prompt/answer text is ever copied. Transcripts over 64MB are skipped
(outcome "unknown"); failures here are swallowed.

Pure observer: emits nothing on stdout, never blocks, always exits 0; any
exception is swallowed (a broken observer must not tax dispatches). Analyze
with jq, e.g.:
  jq -r .verdict .agent/logs/model-routing.jsonl | sort | uniq -c

Seams: AGENT_MODEL_ROUTING_SINK (default <root>/.agent/logs/model-routing.jsonl),
AGENT_REGISTRY_PATH (default <repo>/agents/master-registry.json),
AGENT_SESSION_ID (recorded as agent_session_id; session_id prefers the event's
runtime session_id). Registered in docs/gate-registry.md (GATE model-routing-observer).
"""

import collections
import json
import os
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DISPATCH_TOOLS = {"Task", "Agent"}
EFFORT_LEVELS = {"low", "medium", "high", "xhigh", "max"}
SUBAGENT_EVENTS = {"SubagentStart", "SubagentStop"}
RUNS_MAX_BYTES = 64 * 1024 * 1024  # 큰 기록은 줄 단위로 읽어도 15초 상한을 넘길 수 있어 건너뛴다

# Fail-safe import (same guard pattern as secret-content-scan.py): a broken or
# missing hook_config.py must never tax this observer — it just falls back to
# the "session" default origin.
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import hook_config  # noqa: E402

    def _log_origin():
        return hook_config.log_origin()
except Exception:
    def _log_origin():
        return os.environ.get("AGENT_LOG_ORIGIN") or "session"


def _registry_agents():
    path = os.environ.get("AGENT_REGISTRY_PATH") or os.path.join(
        REPO_ROOT, "agents", "master-registry.json"
    )
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        agents = data.get("agents", data) if isinstance(data, dict) else data
        return [a for a in agents if isinstance(a, dict)]
    except Exception:
        return []


def registry_ids():
    return {a.get("id", "") for a in _registry_agents()} - {""}


def registry_model(agent_id):
    """The registry's pinned model: for agent_id, or None if unlisted."""
    for a in _registry_agents():
        if a.get("id") == agent_id:
            model = a.get("model")
            return model if isinstance(model, str) and model else None
    return None


def classify(subagent_type, model):
    if model:
        return "override"
    bare = subagent_type.rsplit(":", 1)[-1]
    if bare in registry_ids():
        return "pinned_specialist"
    return "inherit_top"


TIER_MAP = (("fable", "TOP"), ("opus", "TOP"), ("sonnet", "MID"), ("haiku", "LOW"))


def tier_of(model_id):
    """fable and opus both classify TOP (spec.md §7 Q3) — same map shape as
    session-tier-observer.py's TIER_MAP, kept local since the two hooks
    observe different events and must not import each other."""
    lowered = (model_id or "").lower()
    for family, tier in TIER_MAP:
        if family in lowered:
            return tier
    return "unknown"


def effective_tier(subagent_type, model, verdict):
    """TOP/MID/LOW/unknown for the model actually driving this dispatch."""
    if verdict == "override":
        return tier_of(model)
    if verdict == "pinned_specialist":
        bare = subagent_type.rsplit(":", 1)[-1]
        return tier_of(registry_model(bare))
    return "unknown"  # inherit_top: effective model is the session's, unseen here


def total_tokens(event):
    """Best-effort usage probe; None when the runtime surfaces no usage."""
    response = event.get("tool_response")
    if not isinstance(response, dict):
        return None
    for holder in (response.get("usage"), response):
        if not isinstance(holder, dict):
            continue
        for key in ("total_tokens", "totalTokens"):
            value = holder.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                return int(value)
    return None


def resolved_model(event):
    """tool_response.resolvedModel (documented Agent PostToolUse field); None if absent."""
    response = event.get("tool_response")
    if isinstance(response, dict):
        value = response.get("resolvedModel")
        if isinstance(value, str) and value:
            return value
    return None


def _runs_sink_path():
    return os.environ.get("AGENT_SUBAGENT_RUNS_SINK") or os.path.join(
        os.path.expanduser("~"), ".agent", "logs", "subagent-runs.jsonl"
    )


def _runs_max_bytes():
    try:
        return int(os.environ.get("AGENT_SUBAGENT_RUNS_MAX_BYTES", "") or RUNS_MAX_BYTES)
    except ValueError:
        return RUNS_MAX_BYTES


def _agent_transcript(event, agent_id):
    path = event.get("agent_transcript_path")
    if isinstance(path, str) and path.strip():
        return os.path.expanduser(path)
    main = event.get("transcript_path")
    if isinstance(main, str) and main.endswith(".jsonl") and agent_id:
        return os.path.join(
            os.path.expanduser(main[: -len(".jsonl")]), "subagents", "agent-%s.jsonl" % agent_id
        )
    return None


def _parse_ts(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def measure_run(event, agent_type, agent_id):
    """One measured-run record from the subagent's own transcript + meta.json.

    Only counts, model ids, effort and timestamps are read out — never message
    text. Any unreadable piece degrades to null/unknown instead of raising."""
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "agent_type": agent_type,
        "agent_id": agent_id,
        "model": None,
        "effort": None,
        "requested_model": None,
        "launched_with_defaults": None,
        "started": None,
        "ended": None,
        "duration_s": None,
        "turns": 0,
        "outcome": "unknown",
        "origin": _log_origin(),
    }
    path = _agent_transcript(event, agent_id)
    meta = {}
    if path:
        try:
            with open(path[: -len(".jsonl")] + ".meta.json" if path.endswith(".jsonl") else path + ".meta.json",
                      encoding="utf-8") as f:
                loaded = json.load(f)
            meta = loaded if isinstance(loaded, dict) else {}
        except Exception:
            meta = {}
    requested = meta.get("model")
    record["requested_model"] = requested if isinstance(requested, str) and requested else None
    launched = meta.get("launchedWithDefaults")
    record["launched_with_defaults"] = launched if isinstance(launched, bool) else None
    meta_effort = meta.get("effort")
    meta_effort = meta_effort.strip().lower() if isinstance(meta_effort, str) else None
    meta_effort = meta_effort if meta_effort in EFFORT_LEVELS else None

    if not path:
        record["effort"] = meta_effort
        return record
    try:
        if os.path.getsize(path) > _runs_max_bytes():
            record["effort"] = meta_effort
            return record
    except OSError:
        return record

    models, efforts = collections.Counter(), collections.Counter()
    first_ts = last_ts = None
    turns = 0
    errored = False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if not isinstance(row, dict):
                    continue
                ts = row.get("timestamp")
                if isinstance(ts, str) and ts:
                    first_ts = first_ts or ts
                    last_ts = ts
                if row.get("type") != "assistant":
                    continue
                turns += 1
                msg = row.get("message")
                model = msg.get("model") if isinstance(msg, dict) else None
                if isinstance(model, str) and model:
                    models[model] += 1
                eff = row.get("effort")
                eff = eff.strip().lower() if isinstance(eff, str) else None
                if eff in EFFORT_LEVELS:
                    efforts[eff] += 1
                # 실제 기록의 오류 표시만 인정한다(isApiErrorMessage / error 키).
                errored = bool(row.get("isApiErrorMessage") is True or row.get("error"))
    except OSError:
        return record

    record["model"] = models.most_common(1)[0][0] if models else None
    record["effort"] = efforts.most_common(1)[0][0] if efforts else meta_effort
    record["started"], record["ended"] = first_ts, last_ts
    t0, t1 = _parse_ts(first_ts or ""), _parse_ts(last_ts or "")
    if t0 and t1:
        record["duration_s"] = int(round((t1 - t0).total_seconds()))
    record["turns"] = turns
    # errored 는 마지막 assistant 줄 기준 — 중간 재시도 오류는 오류로 치지 않는다.
    record["outcome"] = "error" if errored else ("ok" if turns else "unknown")
    return record


def write_run(record):
    sink = _runs_sink_path()
    os.makedirs(os.path.dirname(sink), exist_ok=True)
    with open(sink, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")


def _sink_path():
    return os.environ.get("AGENT_MODEL_ROUTING_SINK") or os.path.join(
        os.getcwd(), ".agent", "logs", "model-routing.jsonl"
    )


def _session_id(event):
    """Runtime session UUID from the hook event, so concurrent sessions in one
    cwd stay distinguishable; AGENT_SESSION_ID when the event carries none.
    The env id is also recorded separately as agent_session_id."""
    sid = event.get("session_id")
    if isinstance(sid, str) and sid.strip():
        return sid
    return os.environ.get("AGENT_SESSION_ID", "")


def handle_subagent_event(event, hook_event_name):
    """SubagentStart/SubagentStop — a measured dispatch record distinct from
    the PostToolUse-derived ones below (Task/Agent tool_input doesn't carry
    agent_id or a completion payload; these events do). `source` tags which
    lane produced the record so downstream consumers (manager-audit) can tell
    them apart without double-counting the same dispatch twice."""
    agent_type = event.get("agent_type", "")
    agent_type = agent_type if isinstance(agent_type, str) else ""
    agent_id = event.get("agent_id", "")
    agent_id = agent_id if isinstance(agent_id, str) else ""

    bare = agent_type.rsplit(":", 1)[-1] if agent_type else ""
    tier = tier_of(registry_model(bare)) if bare in registry_ids() else "unknown"

    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "gate": "model-routing-observer",
        "event": hook_event_name,
        "agent_type": agent_type,
        "agent_id": agent_id,
        "verdict": "pinned_specialist" if tier != "unknown" else "unclassified",
        "effort": None,
        "tier": tier,
        "session_id": _session_id(event),
        "agent_session_id": os.environ.get("AGENT_SESSION_ID", ""),
        "origin": _log_origin(),
        "source": "subagent_event",
    }
    if hook_event_name == "SubagentStop":
        last_msg = event.get("last_assistant_message", "")
        last_msg = last_msg if isinstance(last_msg, str) else ""
        record["last_assistant_message_len"] = len(last_msg)

    sink = _sink_path()
    os.makedirs(os.path.dirname(sink), exist_ok=True)
    with open(sink, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")

    if hook_event_name == "SubagentStop":
        try:
            write_run(measure_run(event, agent_type, agent_id))
        except Exception:
            pass  # 사용자 단위 실측 기록 실패가 세션이나 프로젝트별 기록을 막지 않는다


def main():
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        return

    hook_event_name = event.get("hook_event_name") or event.get("event") or ""
    if hook_event_name in SUBAGENT_EVENTS:
        handle_subagent_event(event, hook_event_name)
        return

    if event.get("tool_name") not in DISPATCH_TOOLS:
        return
    tool_input = event.get("tool_input") or {}
    subagent_type = tool_input.get("subagent_type", "")
    if not isinstance(subagent_type, str) or not subagent_type.strip():
        return
    model = tool_input.get("model", "")
    model = model if isinstance(model, str) else ""
    prompt = tool_input.get("prompt", "")
    prompt = prompt if isinstance(prompt, str) else ""
    effort = tool_input.get("effort")
    # Allowlisted like session-tier-observer.py: a garbage value would skew
    # manager-audit aggregates, so anything outside the known levels is null.
    effort = effort.strip().lower() if isinstance(effort, str) else None
    effort = effort if effort in EFFORT_LEVELS else None

    verdict = classify(subagent_type, model)

    sink = _sink_path()
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "gate": "model-routing-observer",
        "subagent_type": subagent_type,
        "model": model,
        "verdict": verdict,
        "effort": effort,
        "tier": effective_tier(subagent_type, model, verdict),
        "prompt_chars": len(prompt),
        "total_tokens": total_tokens(event),
        "resolved_model": resolved_model(event),
        "env_subagent_model": os.environ.get("CLAUDE_CODE_SUBAGENT_MODEL") or None,
        "session_id": _session_id(event),
        "agent_session_id": os.environ.get("AGENT_SESSION_ID", ""),
        "origin": _log_origin(),
        "source": "post_tool_use",
    }
    os.makedirs(os.path.dirname(sink), exist_ok=True)
    with open(sink, "a", encoding="utf-8") as f:
        f.write(json.dumps(record) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # observer failure must never tax the dispatch
    sys.exit(0)
