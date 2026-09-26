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

Pure observer: emits nothing on stdout, never blocks, always exits 0; any
exception is swallowed (a broken observer must not tax dispatches). Analyze
with jq, e.g.:
  jq -r .verdict .agent/logs/model-routing.jsonl | sort | uniq -c

Seams: AGENT_MODEL_ROUTING_SINK (default <root>/.agent/logs/model-routing.jsonl),
AGENT_REGISTRY_PATH (default <repo>/agents/master-registry.json),
AGENT_SESSION_ID. Registered in docs/gate-registry.md (GATE model-routing-observer).
"""

import json
import os
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DISPATCH_TOOLS = {"Task", "Agent"}
EFFORT_LEVELS = {"low", "medium", "high", "xhigh", "max"}

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


def main():
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
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

    sink = os.environ.get("AGENT_MODEL_ROUTING_SINK") or os.path.join(
        os.getcwd(), ".agent", "logs", "model-routing.jsonl"
    )
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
        "session_id": os.environ.get("AGENT_SESSION_ID", ""),
        "origin": _log_origin(),
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
