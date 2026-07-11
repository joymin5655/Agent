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


def registry_ids():
    path = os.environ.get("AGENT_REGISTRY_PATH") or os.path.join(
        REPO_ROOT, "agents", "master-registry.json"
    )
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        agents = data.get("agents", data) if isinstance(data, dict) else data
        return {a.get("id", "") for a in agents if isinstance(a, dict)} - {""}
    except Exception:
        return set()


def classify(subagent_type, model):
    if model:
        return "override"
    bare = subagent_type.rsplit(":", 1)[-1]
    if bare in registry_ids():
        return "pinned_specialist"
    return "inherit_top"


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

    sink = os.environ.get("AGENT_MODEL_ROUTING_SINK") or os.path.join(
        os.getcwd(), ".agent", "logs", "model-routing.jsonl"
    )
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "gate": "model-routing-observer",
        "subagent_type": subagent_type,
        "model": model,
        "verdict": classify(subagent_type, model),
        "session_id": os.environ.get("AGENT_SESSION_ID", ""),
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
