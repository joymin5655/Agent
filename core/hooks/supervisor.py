#!/usr/bin/env python3
"""Generic Agent Harness supervisor runtime.

Single hook entry point for:
  - UserPromptSubmit: deterministic intent/domain/risk analysis
  - PreToolUse: advisory evidence prompts by default, optional strict blocking
  - PostToolUse: dispatched-specialist evidence tracking

Configuration is read from `.agent-harness/*.json` in the target project. When
those files are absent, the repository's `core/config/*.json` defaults are used.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
from typing import Any


PROJECT_ROOT = Path(os.environ.get("AGENT_HARNESS_PROJECT_ROOT", Path(__file__).resolve().parents[2])).resolve()
DEFAULT_CONFIG_DIR = PROJECT_ROOT / "core" / "config"
PROJECT_CONFIG_DIR = PROJECT_ROOT / ".agent-harness"
CONFIG_DIR = Path(os.environ.get("AGENT_HARNESS_CONFIG_DIR", PROJECT_CONFIG_DIR if PROJECT_CONFIG_DIR.exists() else DEFAULT_CONFIG_DIR)).resolve()


def _load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


CONFIG = _load_json(CONFIG_DIR / "config.json", {})
DOMAIN_CONFIG = _load_json(CONFIG_DIR / "domains.json", {"domains": {}})
AGENT_CONFIG = _load_json(CONFIG_DIR / "agent-registry.json", {"agents": []})
RISK_CONFIG = _load_json(CONFIG_DIR / "risk-rules.json", {})

MODE = str(os.environ.get("AGENT_HARNESS_MODE") or CONFIG.get("mode") or "advisory").lower()
STRICT = (
    MODE == "strict"
    or bool(CONFIG.get("strict"))
    or os.environ.get("AGENT_HARNESS_STRICT", "").lower() in {"1", "true", "yes"}
)
MAX_PROMPT_LEN = int(CONFIG.get("supervisor", {}).get("max_prompt_len", 50_000))
LOG_DIR = PROJECT_ROOT / str(CONFIG.get("log_dir", ".claude/logs"))
SUPERVISOR_LOG = LOG_DIR / "supervisor-routing.jsonl"


def _flag_path(env_var: str, default: str) -> Path:
    value = os.environ.get(env_var)
    return Path(value or default)


STATE_DIR = PROJECT_ROOT / str(CONFIG.get("state_dir", ".agent-harness/state"))
INTENT_FLAG = _flag_path("AGENT_HARNESS_INTENT_FLAG", str(STATE_DIR / "intent-feature"))
PLAN_FLAG = _flag_path("AGENT_HARNESS_PLAN_FLAG", str(STATE_DIR / "plan-approved"))
HARNESS_FLAG = _flag_path("AGENT_HARNESS_MODE_FLAG", str(STATE_DIR / "harness-mode"))
REQUIRED_FLAG = _flag_path("AGENT_HARNESS_REQUIRED_FLAG", str(STATE_DIR / "required-agents.json"))
DISPATCHED_FLAG = _flag_path("AGENT_HARNESS_DISPATCHED_FLAG", str(STATE_DIR / "dispatched-agents.json"))
ANALYSIS_FLAG = _flag_path("AGENT_HARNESS_ANALYSIS_FLAG", str(STATE_DIR / "supervisor-analysis.json"))

INTENTS = {"QUERY", "SIMPLE_EDIT", "FEATURE", "MULTI_DEPT", "META", "RECALL", "LEARN", "REVIEW/AUDIT"}

QUERY_RE = re.compile(r"(what\b|how\b|why\b|show\b|find\b|explain\b|뭐야|알려줘|설명|왜\s|찾아줘|보여줘)", re.IGNORECASE)
SIMPLE_RE = re.compile(r"(typo|rename|one[-\s]?line|quick\s*fix|lint\s*fix|오타|변수명|한\s*줄|간단히)", re.IGNORECASE)
FEATURE_RE = re.compile(r"(implement|create|build|add|fix|refactor|integrate|change|optimi[sz]e|write|update|구현|추가|만들|수정|변경|개선|리팩|통합|작성)", re.IGNORECASE)
REVIEW_RE = re.compile(r"(review|audit|check|inspect|validate|분석|검토|리뷰|감사|진단|검증)", re.IGNORECASE)
META_RE = re.compile(r"(supervisor|agent|harness|routing|registry|hooks?|에이전트|하네스|라우팅|레지스트리|훅)", re.IGNORECASE)
RECALL_RE = re.compile(r"(previous|last time|remember|earlier|이전에|지난번|기억|예전에)", re.IGNORECASE)
LEARN_RE = re.compile(r"(make.*skill|extract.*pattern|remember this|학습|스킬\s*생성|패턴\s*추출|기억해)", re.IGNORECASE)


@dataclass
class AgentInfo:
    id: str
    domain: str = "general"
    model: str = "sonnet"
    risk: str = "LOW"
    path: str = ""
    executable: bool = True
    triggers: list[str] = field(default_factory=list)
    description: str = ""


@dataclass
class RegistryIndex:
    agents: dict[str, AgentInfo] = field(default_factory=dict)
    domains: dict[str, dict[str, Any]] = field(default_factory=dict)
    aliases: dict[str, list[str]] = field(default_factory=dict)
    reverse_aliases: dict[str, list[str]] = field(default_factory=dict)
    non_specialist_agents: set[str] = field(default_factory=set)
    workflows: dict[str, dict[str, Any]] = field(default_factory=dict)
    workflow_errors: list[str] = field(default_factory=list)


def load_registry_index() -> RegistryIndex:
    index = RegistryIndex()
    index.domains = DOMAIN_CONFIG.get("domains", {})
    index.aliases = {k: list(v) for k, v in AGENT_CONFIG.get("aliases", {}).items()}
    index.non_specialist_agents = set(AGENT_CONFIG.get("non_specialist_agents", []))
    index.workflows = RISK_CONFIG.get("workflows", {})

    for raw in AGENT_CONFIG.get("agents", []):
        agent_id = raw.get("id", "")
        if not agent_id:
            continue
        index.agents[agent_id] = AgentInfo(
            id=agent_id,
            domain=raw.get("domain", "general"),
            model=raw.get("model", "sonnet"),
            risk=raw.get("risk", "LOW"),
            path=raw.get("path", ""),
            executable=bool(raw.get("executable", True)),
            triggers=list(raw.get("triggers", [])),
            description=raw.get("description", ""),
        )

    for alias, specialists in index.aliases.items():
        for specialist in specialists:
            index.reverse_aliases.setdefault(specialist, []).append(alias)

    index.workflow_errors = validate_workflows(index)
    return index


def validate_workflows(index: RegistryIndex) -> list[str]:
    known = set(index.agents) | {"Plan", "plan", "{matched_agents}", "{matched_specialist}"}
    errors: list[str] = []
    for workflow_id, workflow in index.workflows.items():
        for agent_id in workflow.get("agents", []):
            if agent_id not in known:
                errors.append(f"{workflow_id} references unknown agent {agent_id}")
    return errors


def classify_prompt(prompt: str) -> str:
    if not prompt.strip():
        return "SIMPLE_EDIT"
    if RECALL_RE.search(prompt):
        return "RECALL"
    if LEARN_RE.search(prompt):
        return "LEARN"
    if META_RE.search(prompt) and REVIEW_RE.search(prompt):
        return "REVIEW/AUDIT"
    if META_RE.search(prompt) and not FEATURE_RE.search(prompt):
        return "META"
    if REVIEW_RE.search(prompt) and not FEATURE_RE.search(prompt):
        return "REVIEW/AUDIT"
    if QUERY_RE.search(prompt) and not FEATURE_RE.search(prompt):
        return "QUERY"
    if SIMPLE_RE.search(prompt) and not _has_high_risk_keyword(prompt):
        return "SIMPLE_EDIT"
    if FEATURE_RE.search(prompt):
        return "FEATURE"
    return "QUERY" if QUERY_RE.search(prompt) else "SIMPLE_EDIT"


def _keyword_hits(prompt: str, keywords: list[str]) -> int:
    prompt_lower = prompt.lower()
    return sum(1 for kw in keywords if str(kw).lower() in prompt_lower)


def match_domains(prompt: str, index: RegistryIndex) -> list[str]:
    scored: list[tuple[int, str]] = []
    for domain_id, domain in index.domains.items():
        hits = _keyword_hits(prompt, domain.get("keywords", []))
        if hits > 0:
            scored.append((hits, domain_id))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [domain for _, domain in scored] or ["general"]


def match_agents(prompt: str, index: RegistryIndex) -> list[str]:
    scored: list[tuple[int, str]] = []
    for agent_id, info in index.agents.items():
        hits = _keyword_hits(prompt, info.triggers)
        if hits > 0:
            scored.append((hits, agent_id))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [agent_id for _, agent_id in scored]


def _has_high_risk_keyword(prompt: str) -> bool:
    return _keyword_hits(prompt, list(RISK_CONFIG.get("high_risk_keywords", []))) > 0


def assess_risk(intent: str, prompt: str, domains: list[str], agents: list[str], index: RegistryIndex) -> str:
    if intent in {"QUERY", "META", "RECALL", "LEARN"}:
        return "LOW"
    if _has_high_risk_keyword(prompt):
        return "HIGH"
    if len({d for d in domains if d != "general"}) >= 2 or intent == "MULTI_DEPT":
        return "HIGH"
    if any(index.agents.get(agent, AgentInfo(agent)).risk == "HIGH" for agent in agents):
        return "HIGH"
    if _keyword_hits(prompt, list(RISK_CONFIG.get("medium_risk_keywords", []))) > 0:
        return "MEDIUM"
    return "MEDIUM" if intent == "FEATURE" else "LOW"


def select_workflow(intent: str, risk: str, domains: list[str]) -> str:
    if intent == "MULTI_DEPT" or len({d for d in domains if d != "general"}) >= 2:
        return "multi-domain"
    if intent == "FEATURE":
        return "feature-dev"
    if intent == "REVIEW/AUDIT":
        return "review"
    if risk == "HIGH":
        return "review"
    return "query" if intent in {"QUERY", "META"} else ""


def required_checks(intent: str, risk: str, matched_agents: list[str], workflow_id: str) -> list[str]:
    checks: list[str] = []
    if intent in {"FEATURE", "MULTI_DEPT"}:
        checks.extend(["Plan recommended", "implementation evidence", "targeted verification"])
    if workflow_id == "multi-domain":
        checks.append("domain owner evidence")
    if "security-reviewer" in matched_agents or risk == "HIGH":
        checks.append("security or production-risk review")
    if "test-engineer" in matched_agents or intent in {"FEATURE", "MULTI_DEPT"}:
        checks.append("tests or explicit test-gap note")
    if risk == "HIGH":
        checks.append("specialist dispatch evidence before high-risk Write/Edit")
    return list(dict.fromkeys(checks))


def analyze_prompt(prompt: str, index: RegistryIndex | None = None) -> dict[str, Any]:
    index = index or load_registry_index()
    intent = classify_prompt(prompt)
    domains = match_domains(prompt, index)
    agents = match_agents(prompt, index)
    agent_domains = [index.agents[a].domain for a in agents if a in index.agents]
    all_domains = list(dict.fromkeys([*domains, *agent_domains]))
    effective_domains = [d for d in all_domains if d != "general"]
    if intent == "FEATURE" and len(set(effective_domains)) >= 2:
        intent = "MULTI_DEPT"
    if intent in {"META", "REVIEW/AUDIT"} and not agents:
        agents = ["supervisor"]

    risk = assess_risk(intent, prompt, all_domains, agents, index)
    workflow_id = select_workflow(intent, risk, all_domains)
    matched_agents = [a for a in agents if index.agents.get(a, AgentInfo(a)).executable]
    if not matched_agents and intent in {"FEATURE", "MULTI_DEPT", "META", "REVIEW/AUDIT"}:
        matched_agents = ["supervisor"]

    rationale: list[str] = []
    if effective_domains:
        rationale.append("domains matched: " + ", ".join(effective_domains))
    if agents:
        rationale.append("agents matched: " + ", ".join(agents))
    if risk != "LOW":
        rationale.append(f"risk={risk}")
    if not rationale:
        rationale.append("fallback classification")

    return {
        "intent": intent if intent in INTENTS else "SIMPLE_EDIT",
        "domains": all_domains,
        "matched_agents": matched_agents,
        "reference_agents": [],
        "risk": risk,
        "workflow": workflow_id,
        "mode": "strict" if STRICT else "advisory",
        "rationale": "; ".join(rationale),
        "required_checks": required_checks(intent, risk, matched_agents, workflow_id),
        "workflow_errors": index.workflow_errors,
    }


def _workflow_agents(index: RegistryIndex, analysis: dict[str, Any]) -> list[str]:
    workflow = index.workflows.get(analysis.get("workflow") or "", {})
    agents = workflow.get("agents", [])
    out: list[str] = []
    for agent_id in agents:
        if agent_id == "{matched_specialist}":
            out.extend((analysis.get("matched_agents") or ["supervisor"])[:1])
        elif agent_id == "{matched_agents}":
            out.extend(analysis.get("matched_agents") or ["supervisor"])
        else:
            out.append(agent_id)
    return list(dict.fromkeys(out))


def emit_hint(analysis: dict[str, Any], index: RegistryIndex) -> dict[str, str]:
    if analysis["intent"] in {"SIMPLE_EDIT", "RECALL", "LEARN"}:
        return {}
    header = (
        f"AGENT HARNESS | intent={analysis['intent']} | risk={analysis['risk']} | "
        f"domains={','.join(analysis['domains'])} | mode={analysis['mode']}"
    )
    body = [header, f"Reason: {analysis['rationale']}"]
    agents = _workflow_agents(index, analysis) or analysis.get("matched_agents") or ["supervisor"]
    body.append("Recommended evidence path: " + ", ".join(agents))
    if analysis.get("required_checks"):
        body.append("Checks: " + ", ".join(analysis["required_checks"]))
    if analysis["risk"] == "HIGH":
        body.append("High-risk work: advisory by default; strict mode blocks Write/Edit until Plan and specialist evidence exist.")
    if analysis.get("workflow_errors"):
        body.append("Config errors: " + "; ".join(analysis["workflow_errors"]))
    return {"systemMessage": "\n".join(body)}


def _mkdir_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def write_flags(prompt: str, analysis: dict[str, Any]) -> None:
    _mkdir_parent(ANALYSIS_FLAG)
    ANALYSIS_FLAG.write_text(json.dumps(analysis, ensure_ascii=False), encoding="utf-8")
    if analysis["intent"] in {"FEATURE", "MULTI_DEPT"} or analysis["risk"] == "HIGH":
        _mkdir_parent(INTENT_FLAG)
        INTENT_FLAG.write_text(prompt[:500], encoding="utf-8")
        _mkdir_parent(HARNESS_FLAG)
        HARNESS_FLAG.write_text(analysis["risk"], encoding="utf-8")
        required = (analysis.get("matched_agents") or ["supervisor"])[:5]
        _mkdir_parent(REQUIRED_FLAG)
        REQUIRED_FLAG.write_text(json.dumps(required, ensure_ascii=False), encoding="utf-8")
        return

    for flag in (INTENT_FLAG, HARNESS_FLAG, REQUIRED_FLAG, DISPATCHED_FLAG):
        flag.unlink(missing_ok=True)


def log_analysis(prompt: str, analysis: dict[str, Any]) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "prompt_first_160": prompt[:160],
        "prompt_len": len(prompt),
        **analysis,
    }
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with SUPERVISOR_LOG.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def _read_input() -> dict[str, Any]:
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return {}
    try:
        return json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return {}


def _resolve_event(input_data: dict[str, Any]) -> str:
    return str(input_data.get("hook_event_name") or input_data.get("event") or os.environ.get("CLAUDE_HOOK_EVENT", "")).strip()


def _prompt_from_input(input_data: dict[str, Any]) -> str:
    prompt = (
        input_data.get("user_prompt")
        or input_data.get("prompt")
        or input_data.get("input")
        or input_data.get("tool_input", {}).get("user_prompt")
        or ""
    )
    return prompt if isinstance(prompt, str) else ""


def _load_json_list(path: Path) -> list[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def _load_analysis_flag() -> dict[str, Any]:
    try:
        return json.loads(ANALYSIS_FLAG.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _expand_dispatched(raw: list[str], index: RegistryIndex | None = None) -> set[str]:
    index = index or load_registry_index()
    expanded: set[str] = set()
    for agent in raw:
        if not isinstance(agent, str) or agent in index.non_specialist_agents:
            continue
        expanded.add(agent)
        for alias in index.aliases.get(agent, []):
            expanded.add(alias)
    return expanded


def has_active_plan() -> bool:
    if PLAN_FLAG.exists():
        return True
    plans_dir = Path.home() / ".claude" / "plans"
    return plans_dir.exists() and any(plans_dir.glob("*.md"))


def should_bypass_path(file_path: str) -> bool:
    for fragment in RISK_CONFIG.get("allowed_bypass_path_fragments", []):
        if fragment and fragment in file_path:
            return True
    return False


def handle_user_prompt(input_data: dict[str, Any]) -> None:
    prompt = _prompt_from_input(input_data)
    if len(prompt.strip()) < 2 or prompt.strip().startswith("/") or len(prompt) > MAX_PROMPT_LEN:
        print(json.dumps({}))
        return
    index = load_registry_index()
    analysis = analyze_prompt(prompt, index)
    write_flags(prompt, analysis)
    log_analysis(prompt, analysis)
    print(json.dumps(emit_hint(analysis, index), ensure_ascii=False))


def _advisory_payload(message: str) -> dict[str, Any]:
    return {
        "decision": "allow",
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": message,
        },
    }


def handle_pre_tool_use(input_data: dict[str, Any]) -> None:
    tool_name = input_data.get("tool_name") or input_data.get("tool") or ""
    if tool_name not in set(RISK_CONFIG.get("strict_block_tools", ["Write", "Edit", "MultiEdit"])):
        print(json.dumps({"decision": "allow"}))
        return

    tool_input = input_data.get("tool_input", {})
    file_path = str(tool_input.get("file_path") or "")
    if file_path and should_bypass_path(file_path):
        print(json.dumps({"decision": "allow"}))
        return

    analysis = _load_analysis_flag()
    if analysis.get("risk") != "HIGH" and analysis.get("intent") != "MULTI_DEPT":
        print(json.dumps({"decision": "allow"}))
        return

    index = load_registry_index()
    required = _load_json_list(REQUIRED_FLAG)
    dispatched = _expand_dispatched(_load_json_list(DISPATCHED_FLAG), index)
    missing = [agent for agent in required if agent not in dispatched]
    plan_missing = not has_active_plan()
    evidence_missing = bool(missing)

    if not plan_missing and not evidence_missing:
        print(json.dumps({"decision": "allow"}))
        return

    lines = [
        "AGENT HARNESS VERIFICATION - high-risk or multi-domain edit needs evidence.",
        f"Intent={analysis.get('intent')}, risk={analysis.get('risk')}, workflow={analysis.get('workflow') or 'none'}.",
    ]
    if plan_missing:
        lines.append("Missing: active plan evidence.")
    if missing:
        lines.append("Missing specialists: " + ", ".join(missing))
        suggestions: list[str] = []
        for spec in missing:
            suggestions.append(spec)
            suggestions.extend(index.reverse_aliases.get(spec, []))
        if suggestions:
            lines.append("Suggested dispatch: " + ", ".join(list(dict.fromkeys(suggestions))[:6]))

    reason = "\n".join(lines)
    if STRICT:
        print(json.dumps({"decision": "block", "reason": reason, "missing_specialists": missing}, ensure_ascii=False))
    else:
        print(json.dumps(_advisory_payload(reason), ensure_ascii=False))


def handle_post_tool_use(input_data: dict[str, Any]) -> None:
    if input_data.get("tool_name") not in {"Agent", "Task"}:
        print(json.dumps({}))
        return
    tool_input = input_data.get("tool_input", {})
    subagent_type = tool_input.get("subagent_type") or tool_input.get("agent_type")
    if not subagent_type:
        print(json.dumps({}))
        return
    existing = set(_load_json_list(DISPATCHED_FLAG))
    existing.add(str(subagent_type))
    try:
        _mkdir_parent(DISPATCHED_FLAG)
        DISPATCHED_FLAG.write_text(json.dumps(sorted(existing), ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass
    print(json.dumps({}))


def main() -> None:
    input_data = _read_input()
    event = _resolve_event(input_data)
    if event == "UserPromptSubmit":
        handle_user_prompt(input_data)
        return
    if event == "PreToolUse":
        handle_pre_tool_use(input_data)
        return
    if event == "PostToolUse":
        handle_post_tool_use(input_data)
        return
    print(json.dumps({}))


if __name__ == "__main__":
    main()
