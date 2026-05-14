#!/usr/bin/env python3
"""Routing regression checks for core/hooks/supervisor.py."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SUPERVISOR = ROOT / "core" / "hooks" / "supervisor.py"
FIXTURES = ROOT / "core" / "hooks" / "supervisor-routing-fixtures.json"
CONFIG_FILES = [
    ROOT / "core" / "config" / "config.json",
    ROOT / "core" / "config" / "agent-registry.json",
    ROOT / "core" / "config" / "domains.json",
    ROOT / "core" / "config" / "risk-rules.json",
]


def load_supervisor():
    spec = importlib.util.spec_from_file_location("agent_harness_supervisor_runtime", SUPERVISOR)
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


def main() -> int:
    for path in CONFIG_FILES:
        json.loads(path.read_text(encoding="utf-8"))

    supervisor = load_supervisor()
    index = supervisor.load_registry_index()
    if index.workflow_errors:
        raise AssertionError("workflow validation errors: " + "; ".join(index.workflow_errors))

    fixtures = json.loads(FIXTURES.read_text(encoding="utf-8"))
    known_agents = set(index.agents)
    for fixture in fixtures:
        analysis = supervisor.analyze_prompt(fixture["prompt"], index)
        expect = fixture["expect"]

        for key in ("intent", "risk", "workflow"):
            if key in expect and analysis.get(key) != expect[key]:
                raise AssertionError(f"{fixture['prompt']}: {key}={analysis.get(key)} expected={expect[key]}")

        for agent_id in analysis["matched_agents"]:
            if agent_id not in known_agents:
                raise AssertionError(f"{fixture['prompt']}: matched unknown agent={agent_id}")

        assert_includes("domains", analysis["domains"], expect.get("domains_include", []))
        assert_includes("matched_agents", analysis["matched_agents"], expect.get("matched_agents_include", []))
        assert_includes("required_checks", analysis["required_checks"], expect.get("required_checks_include", []))

    print(f"[ok] {len(fixtures)} supervisor routing fixtures passed")
    test_expand_dispatched_aliases(supervisor)
    test_pretooluse_advisory_and_strict()
    return 0


def test_expand_dispatched_aliases(supervisor) -> None:
    expand = supervisor._expand_dispatched

    out = expand(["database-reviewer"])
    assert out == {"database-reviewer", "database-specialist"}, out

    assert expand(["Explore", "Plan", "general-purpose"]) == set()

    out = expand(["typescript-reviewer"])
    assert out == {"typescript-reviewer", "backend-specialist", "frontend-specialist"}, out

    out = expand([None, 123, "security-reviewer"])  # type: ignore[list-item]
    assert out == {"security-reviewer"}, out

    print("[ok] _expand_dispatched alias unit tests passed")


def _run_pretooluse(strict: bool, required: list[str], dispatched: list[str], analysis: dict) -> dict:
    with tempfile.TemporaryDirectory() as tmpd:
        tmp = Path(tmpd)
        required_file = tmp / "required.json"
        dispatched_file = tmp / "dispatched.json"
        analysis_file = tmp / "analysis.json"
        plan_file = tmp / "plan.flag"
        required_file.write_text(json.dumps(required), encoding="utf-8")
        dispatched_file.write_text(json.dumps(dispatched), encoding="utf-8")
        analysis_file.write_text(json.dumps(analysis), encoding="utf-8")

        env = os.environ.copy()
        env["AGENT_HARNESS_REQUIRED_FLAG"] = str(required_file)
        env["AGENT_HARNESS_DISPATCHED_FLAG"] = str(dispatched_file)
        env["AGENT_HARNESS_ANALYSIS_FLAG"] = str(analysis_file)
        env["AGENT_HARNESS_PLAN_FLAG"] = str(plan_file)
        env["AGENT_HARNESS_STRICT"] = "true" if strict else "false"
        env["AGENT_HARNESS_PROJECT_ROOT"] = str(ROOT)
        env["HOME"] = str(tmp)

        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Write",
            "tool_input": {"file_path": "src/example.ts", "content": ""},
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


def test_pretooluse_advisory_and_strict() -> None:
    high = {"intent": "MULTI_DEPT", "risk": "HIGH", "workflow": "multi-domain"}

    res = _run_pretooluse(False, ["database-specialist"], [], high)
    assert res.get("decision") == "allow", res
    assert "hookSpecificOutput" in res, res

    res = _run_pretooluse(True, ["database-specialist"], [], high)
    assert res.get("decision") == "block", res
    assert res.get("missing_specialists") == ["database-specialist"], res

    res = _run_pretooluse(True, ["database-specialist"], ["database-reviewer"], high)
    assert res.get("decision") == "block", res  # plan still missing

    print("[ok] PreToolUse advisory/strict checks passed")


if __name__ == "__main__":
    raise SystemExit(main())
