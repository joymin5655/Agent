#!/usr/bin/env python3
"""Validate public Agent Harness JSON config fixtures without third-party deps."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_BASE = "https://raw.githubusercontent.com/joymin5655/Agent/main/schemas"

CONFIG_EXPECTATIONS = {
    "config.json": {
        "$schema": f"{SCHEMA_BASE}/config.schema.json",
        "required": {
            "schema_version",
            "project_name",
            "mode",
            "strict",
            "log_dir",
            "state_dir",
            "session_lock_file",
            "supervisor",
        },
    },
    "agent-registry.json": {
        "$schema": f"{SCHEMA_BASE}/agent-registry.schema.json",
        "required": {"schema_version", "agents", "aliases", "non_specialist_agents"},
    },
    "domains.json": {
        "$schema": f"{SCHEMA_BASE}/domains.schema.json",
        "required": {"schema_version", "domains"},
    },
    "risk-rules.json": {
        "$schema": f"{SCHEMA_BASE}/risk-rules.schema.json",
        "required": {
            "schema_version",
            "high_risk_keywords",
            "medium_risk_keywords",
            "strict_block_tools",
            "allowed_bypass_path_fragments",
            "workflows",
        },
    },
}


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise AssertionError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise AssertionError(f"{path}: expected top-level object")
    return data


def assert_required(path: Path, data: dict[str, Any], required: set[str]) -> None:
    missing = sorted(required - set(data))
    if missing:
        raise AssertionError(f"{path}: missing required keys: {', '.join(missing)}")


def validate_schema_files() -> None:
    schema_dir = ROOT / "schemas"
    for name in (
        "config.schema.json",
        "agent-registry.schema.json",
        "domains.schema.json",
        "risk-rules.schema.json",
    ):
        data = load_json(schema_dir / name)
        assert_required(schema_dir / name, data, {"$schema", "$id", "title", "type", "properties"})


def validate_config_files() -> None:
    config_dir = ROOT / "core" / "config"
    for name, expectation in CONFIG_EXPECTATIONS.items():
        path = config_dir / name
        data = load_json(path)
        assert_required(path, data, expectation["required"])
        if data.get("$schema") != expectation["$schema"]:
            raise AssertionError(f"{path}: unexpected $schema {data.get('$schema')!r}")


def validate_cross_references() -> None:
    config_dir = ROOT / "core" / "config"
    domains = load_json(config_dir / "domains.json")["domains"]
    registry = load_json(config_dir / "agent-registry.json")
    risk_rules = load_json(config_dir / "risk-rules.json")

    agent_ids: set[str] = set()
    for agent in registry["agents"]:
        agent_id = agent.get("id")
        if not agent_id:
            raise AssertionError("agent-registry.json: agent without id")
        if agent_id in agent_ids:
            raise AssertionError(f"agent-registry.json: duplicate agent id {agent_id}")
        agent_ids.add(agent_id)
        if agent.get("domain") not in domains:
            raise AssertionError(f"agent-registry.json: {agent_id} uses unknown domain {agent.get('domain')}")
        if agent.get("risk") not in {"LOW", "MEDIUM", "HIGH"}:
            raise AssertionError(f"agent-registry.json: {agent_id} has invalid risk {agent.get('risk')}")

    for alias, targets in registry["aliases"].items():
        missing = [target for target in targets if target not in agent_ids]
        if missing:
            raise AssertionError(f"agent-registry.json: alias {alias} targets unknown agents {missing}")

    workflow_allowed = agent_ids | {"Plan", "plan", "{matched_agents}", "{matched_specialist}"}
    for workflow_id, workflow in risk_rules["workflows"].items():
        for agent in workflow.get("agents", []):
            if agent not in workflow_allowed:
                raise AssertionError(f"risk-rules.json: workflow {workflow_id} references unknown agent {agent}")


def main() -> int:
    validate_schema_files()
    validate_config_files()
    validate_cross_references()
    print("[ok] config and schema validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
