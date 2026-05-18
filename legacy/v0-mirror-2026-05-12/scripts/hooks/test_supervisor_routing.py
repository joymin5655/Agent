#!/usr/bin/env python3
"""Routing regression checks for scripts/hooks/supervisor.py."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SUPERVISOR = ROOT / "scripts" / "hooks" / "supervisor.py"
FIXTURES = ROOT / "scripts" / "hooks" / "supervisor-routing-fixtures.json"
JSON_FILES = [
    ROOT / ".claude" / "settings.local.json",
    ROOT / "apps" / "web" / ".claude" / "settings.local.json",
    ROOT / "apps" / "web" / ".claude" / "agents" / "registry.json",
    ROOT / "apps" / "web" / ".claude" / "agents" / "registry-tier1.json",
    ROOT / "apps" / "web" / ".claude" / "agents" / "workflows.json",
    ROOT / "apps" / "app" / ".claude" / "agents" / "registry.json",
    ROOT / "apps" / "app" / ".claude" / "agents" / "registry-tier1.json",
]
OPTIONAL_JSON_FILES = [
    ROOT / "models" / ".claude" / "agents" / "registry-tier1.json",
]


def load_supervisor():
    spec = importlib.util.spec_from_file_location("airlens_supervisor_runtime", SUPERVISOR)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load supervisor.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def assert_includes(name: str, actual: list[str], expected: list[str]) -> None:
    missing = [item for item in expected if item not in actual]
    if missing:
        raise AssertionError(f"{name} missing {missing}; actual={actual}")


def assert_equals_list(name: str, actual: list[str], expected: list[str]) -> None:
    if actual != expected:
        raise AssertionError(f"{name}={actual} expected={expected}")


def main() -> int:
    if not SUPERVISOR.exists():
        print("[skip] supervisor.py is not mirrored in this public/runtime-light checkout")
        return 0

    for path in JSON_FILES:
        if path.exists():
            json.loads(path.read_text(encoding="utf-8"))
    for path in OPTIONAL_JSON_FILES:
        if path.exists():
            json.loads(path.read_text(encoding="utf-8"))

    supervisor = load_supervisor()
    index = supervisor.load_registry_index()
    if index.workflow_errors:
        raise AssertionError("workflow validation errors: " + "; ".join(index.workflow_errors))

    fixtures = json.loads(FIXTURES.read_text(encoding="utf-8"))
    registry_agents = set(index.agents)
    web_agents = {agent_id for agent_id, info in index.agents.items() if info.scope == "AirLens-web"}
    model_agents = {agent_id for agent_id, info in index.agents.items() if info.scope == "AirLens-models"}

    for fixture in fixtures:
        analysis = supervisor.analyze_prompt(fixture["prompt"], index)
        expect = fixture["expect"]

        if "intent" in expect and analysis["intent"] != expect["intent"]:
            raise AssertionError(f"{fixture['prompt']}: intent={analysis['intent']} expected={expect['intent']}")
        if "intent_one_of" in expect and analysis["intent"] not in expect["intent_one_of"]:
            raise AssertionError(
                f"{fixture['prompt']}: intent={analysis['intent']} expected one of {expect['intent_one_of']}"
            )
        if "risk" in expect and analysis["risk"] != expect["risk"]:
            raise AssertionError(f"{fixture['prompt']}: risk={analysis['risk']} expected={expect['risk']}")
        if "workflow" in expect and analysis["workflow"] != expect["workflow"]:
            raise AssertionError(
                f"{fixture['prompt']}: workflow={analysis['workflow']} expected={expect['workflow']}"
            )

        workflow_id = analysis.get("workflow")
        if workflow_id and workflow_id not in index.workflows:
            raise AssertionError(f"{fixture['prompt']}: unknown workflow={workflow_id}")

        for agent_id in analysis["matched_agents"]:
            if agent_id not in registry_agents:
                raise AssertionError(f"{fixture['prompt']}: matched unknown agent={agent_id}")
            if agent_id in model_agents:
                raise AssertionError(f"{fixture['prompt']}: models specialist must be reference-only: {agent_id}")

        for agent_id in analysis["reference_agents"]:
            if agent_id not in model_agents:
                raise AssertionError(f"{fixture['prompt']}: unexpected reference agent={agent_id}")
            if agent_id in web_agents:
                raise AssertionError(f"{fixture['prompt']}: executable web agent cannot be reference-only: {agent_id}")

        if "matched_agents" in expect:
            assert_equals_list("matched_agents", analysis["matched_agents"], expect["matched_agents"])
        if "reference_agents" in expect:
            assert_equals_list("reference_agents", analysis["reference_agents"], expect["reference_agents"])
        if "required_checks" in expect:
            assert_equals_list("required_checks", analysis["required_checks"], expect["required_checks"])
        if "canonical_docs" in expect:
            assert_equals_list("canonical_docs", analysis["canonical_docs"], expect["canonical_docs"])

        assert_includes("matched_agents", analysis["matched_agents"], expect.get("matched_agents_include", []))
        assert_includes("departments", analysis["departments"], expect.get("departments_include", []))
        assert_includes("reference_agents", analysis["reference_agents"], expect.get("reference_agents_include", []))
        assert_includes("required_checks", analysis["required_checks"], expect.get("required_checks_include", []))
        assert_includes("canonical_docs", analysis["canonical_docs"], expect.get("canonical_docs_include", []))

    print(f"[ok] {len(fixtures)} supervisor routing fixtures passed")

    test_expand_dispatched_aliases(supervisor)
    test_handle_pre_tool_use_alias()
    return 0


def test_expand_dispatched_aliases(supervisor) -> None:
    """_expand_dispatched maps global agents to specialists and drops generics."""
    expand = supervisor._expand_dispatched

    out = expand(["design-system-architect"])
    assert "ux-reviewer" in out and "ui-ux-director" in out and "design-system-architect" in out, out

    assert expand(["Explore", "Plan", "general-purpose"]) == set(), expand(["Explore", "Plan"])

    out = expand(["database-reviewer", "Explore"])
    assert out == {"database-reviewer", "db-architect"}, out

    out = expand(["typescript-reviewer"])
    assert out == {"typescript-reviewer", "edge-fn-dev"}, out

    out = expand(["research-scientist"])
    assert out == {"research-scientist", "ml-researcher"}, out

    out = expand(["ml-researcher"])
    assert out == {"ml-researcher"}, out

    out = expand([])
    assert out == set(), out

    out = expand([None, 123, "ux-reviewer"])  # type: ignore[list-item]
    assert out == {"ux-reviewer"}, out

    print("[ok] _expand_dispatched alias unit tests passed")


def _run_pretooluse(required: list[str], dispatched: list[str], analysis: dict) -> dict:
    """Invoke supervisor.py PreToolUse with custom flag state and return decision."""
    with tempfile.TemporaryDirectory() as tmpd:
        tmp = Path(tmpd)
        required_file = tmp / "required.json"
        dispatched_file = tmp / "dispatched.json"
        analysis_file = tmp / "analysis.json"
        plan_file = tmp / "plan.flag"
        required_file.write_text(json.dumps(required), encoding="utf-8")
        dispatched_file.write_text(json.dumps(dispatched), encoding="utf-8")
        analysis_file.write_text(json.dumps(analysis), encoding="utf-8")
        plan_file.write_text("ok", encoding="utf-8")

        env = os.environ.copy()
        env["AIRLENS_REQUIRED_FLAG"] = str(required_file)
        env["AIRLENS_DISPATCHED_FLAG"] = str(dispatched_file)
        env["AIRLENS_ANALYSIS_FLAG"] = str(analysis_file)
        env["AIRLENS_PLAN_FLAG"] = str(plan_file)

        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Write",
            "tool_input": {"file_path": "apps/app/src/example.tsx", "content": ""},
        }
        result = subprocess.run(
            [sys.executable, str(SUPERVISOR)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        out = result.stdout.strip() or "{}"
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            raise AssertionError(f"non-JSON stdout: {out!r}; stderr={result.stderr!r}")


def test_handle_pre_tool_use_alias() -> None:
    """handle_pre_tool_use accepts alias dispatches and rejects generics."""
    multi = {"intent": "MULTI_DEPT", "risk": "HIGH", "workflow": "multi-dept"}

    # Alias path: design-system-architect → ux-reviewer (allow)
    res = _run_pretooluse(["ux-reviewer"], ["design-system-architect"], multi)
    assert res.get("decision") == "allow", res

    # Generic only: Explore alone is not specialist coverage (block)
    res = _run_pretooluse(["db-architect"], ["Explore"], multi)
    assert res.get("decision") == "block", res

    # typescript-reviewer covers edge-fn-dev (allow)
    res = _run_pretooluse(["edge-fn-dev"], ["typescript-reviewer"], multi)
    assert res.get("decision") == "allow", res

    # research-scientist covers ml-researcher (allow)
    res = _run_pretooluse(["ml-researcher"], ["research-scientist"], multi)
    assert res.get("decision") == "allow", res

    # Direct specialist dispatch still works (allow)
    res = _run_pretooluse(["ux-reviewer"], ["ux-reviewer"], multi)
    assert res.get("decision") == "allow", res

    print("[ok] handle_pre_tool_use alias integration tests passed")


if __name__ == "__main__":
    sys.exit(main())
