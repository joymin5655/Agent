#!/usr/bin/env python3
"""AirLens Claude supervisor runtime.

Single hook entry point for:
  - UserPromptSubmit: deterministic prompt analysis + routing hints + flags
  - PreToolUse: recommendation/verification guardrails for high-risk work
  - PostToolUse: lightweight dispatched-agent flag compatibility

This file intentionally does not import the deprecated supervisor hooks.  The
runtime keeps the old /tmp/airlens-* flag contract while adding a structured
analysis record suitable for routing regression tests and log comparison.
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

PROJECT_ROOT = Path(__file__).resolve().parents[2]
# 2026-04-30 monorepo 재구조화: AirLens-web/ → apps/web/, AirLens-models/ → models/
WEB_AGENTS_DIR = PROJECT_ROOT / "apps" / "web" / ".claude" / "agents"
MODELS_AGENTS_DIR = PROJECT_ROOT / "models" / ".claude" / "agents"
APP_AGENTS_DIR = PROJECT_ROOT / "apps" / "app" / ".claude" / "agents"

MASTER_REGISTRY = PROJECT_ROOT / ".claude" / "agents" / "master-registry.json"
WEB_REGISTRY = WEB_AGENTS_DIR / "registry.json"
WEB_TIER1 = WEB_AGENTS_DIR / "registry-tier1.json"
MODELS_TIER1 = MODELS_AGENTS_DIR / "registry-tier1.json"
APP_REGISTRY = APP_AGENTS_DIR / "registry.json"
APP_TIER1 = APP_AGENTS_DIR / "registry-tier1.json"
WORKFLOWS_FILE = WEB_AGENTS_DIR / "workflows.json"

LOG_DIR = PROJECT_ROOT / ".claude" / "logs"
SUPERVISOR_LOG = LOG_DIR / "supervisor-routing.jsonl"

def _flag_path(env_var: str, default: str) -> Path:
    return Path(os.environ.get(env_var) or default)


INTENT_FLAG = _flag_path("AIRLENS_INTENT_FLAG", "/tmp/airlens-intent-feature")
PLAN_FLAG = _flag_path("AIRLENS_PLAN_FLAG", "/tmp/airlens-plan-approved")
HARNESS_FLAG = _flag_path("AIRLENS_HARNESS_FLAG", "/tmp/airlens-harness-mode")
REQUIRED_FLAG = _flag_path("AIRLENS_REQUIRED_FLAG", "/tmp/airlens-required-agents")
DISPATCHED_FLAG = _flag_path("AIRLENS_DISPATCHED_FLAG", "/tmp/airlens-dispatched-agents")
ANALYSIS_FLAG = _flag_path("AIRLENS_ANALYSIS_FLAG", "/tmp/airlens-supervisor-analysis.json")

MAX_PROMPT_LEN = 50_000

# Global / cross-project agents that count as one of the registered AirLens
# specialists for PreToolUse coverage checks. Lets the user dispatch a global
# agent (e.g. design-system-architect) and have it satisfy a required local
# specialist (e.g. ux-reviewer). Keys are dispatched names; values are the
# specialists whose coverage they fulfill.
AGENT_ALIASES: dict[str, tuple[str, ...]] = {
    "design-system-architect": ("ux-reviewer", "ui-ux-director", "component-builder"),
    "ui-layout-reviewer":      ("ux-reviewer", "ui-ux-director", "component-builder"),
    "code-reviewer":           ("style-reviewer",),
    "database-reviewer":       ("db-architect",),
    "typescript-reviewer":     ("edge-fn-dev",),
    "research-scientist":      ("ml-researcher",),
    "performance-optimizer":   ("performance-reviewer",),
    "test":                    ("test-engineer",),
    "tdd-guide":               ("test-engineer",),
    "doc-updater":             ("doc-writer", "i18n-specialist"),
    "docs":                    ("doc-writer", "i18n-specialist"),
    "architect":               ("fe-architect",),
    # 2026-05-06 wave-3 expansion — 글로벌 agent ↔ AirLens specialist 매핑 8개 추가.
    "e2e-runner":              ("test-engineer",),
    "pr-test-analyzer":        ("test-engineer",),
    "web-scraper":             ("data-engineer",),
    "document-engineer":       ("doc-writer",),
    "python-reviewer":         ("ml-test-engineer",),
    "silent-failure-hunter":   ("style-reviewer",),
    "refactor-cleaner":        ("style-reviewer",),
    "comment-analyzer":        ("style-reviewer",),
    "hf-research-collector":   ("ml-researcher",),
}

# Reverse map: AirLens specialist → list of global agents that alias to it.
# Built from AGENT_ALIASES at import time so block messages can suggest
# concrete subagent_type values Claude can dispatch via the Agent tool.
_REVERSE_ALIASES: dict[str, list[str]] = {}
for _global_agent, _specialists in AGENT_ALIASES.items():
    for _spec in _specialists:
        _REVERSE_ALIASES.setdefault(_spec, []).append(_global_agent)

# Generic exploration / planning agents that do NOT count as specialist
# coverage. Dispatching only these and then writing high-risk code stays
# blocked, which is the intended behavior.
NON_SPECIALIST_AGENTS: frozenset[str] = frozenset({
    "Explore",
    "Plan",
    "general-purpose",
    "code-explorer",
})

INTENTS = {
    "QUERY",
    "SIMPLE_EDIT",
    "FEATURE",
    "MULTI_DEPT",
    "META",
    "RECALL",
    "LEARN",
    "REVIEW/AUDIT",
    "SELF_DRIVING_PM",
}

QUERY_RE = re.compile(
    r"(뭐야|뭔가요|알려줘|설명|어떻게|왜\s|보여줘|찾아줘|검색|what\b|how\b|why\b|show\b|find\b|explain\b)",
    re.IGNORECASE,
)
SIMPLE_RE = re.compile(
    r"(오타|typo|rename|변수명|한\s*줄|1[\-\s]?line|간단히|quick\s*fix|lint\s*fix|eslint)",
    re.IGNORECASE,
)
FEATURE_RE = re.compile(
    r"(구현|추가|만들|생성|수정|변경|개선|리팩|통합|연동|빌드|작성|연결|도입|"
    r"최적화|implement|create|build|add|fix|refactor|integrate|change|optimi[sz]e)",
    re.IGNORECASE,
)
REVIEW_RE = re.compile(
    r"(점검|감사|검토|리뷰|audit|review|check|진단|분석해|검증|하네스)",
    re.IGNORECASE,
)
META_RE = re.compile(
    r"(supervisor|에이전트|agent|라우팅|프롬프트\s*분석|registry|레지스트리|\bhooks?\b|훅|harness|하네스)",
    re.IGNORECASE,
)
RECALL_RE = re.compile(r"(이전에|기억나|지난번|과거\s*세션|예전에|지난\s*세션|전에\s*했)", re.IGNORECASE)
LEARN_RE = re.compile(r"(패턴\s*저장|이거\s*기억|스킬로\s*만들|학습해|스킬\s*생성|패턴\s*추출)", re.IGNORECASE)
SELF_DRIVING_PM_RE = re.compile(
    r"(이어서\s*해줘|계속\s*진행|다음\s*작업|다음\s*task|next\s*task|continue\s*(?:the\s*)?(?:queue|task|work)|"
    r"self[-\s]*driving\s*pm|autonomous\s*pm|task\s*queue|작업\s*큐|태스크\s*큐)",
    re.IGNORECASE,
)
HIGH_RISK_RE = re.compile(
    r"(마이그레이션|migration|RLS|security|보안|secret|시크릿|deploy|배포|production|prod|"
    r"결제|billing|인증|auth|webhook|HMAC|학습|훈련|training|schema|스키마)",
    re.IGNORECASE,
)
CANONICAL_RE = re.compile(
    r"(PRD|RPD|정본|요구사항|requirements?|architecture|아키텍처|"
    r"security|secret|gitleaks|pre-commit|시크릿|보안|취약점)",
    re.IGNORECASE,
)

AGENT_PATTERNS: dict[str, re.Pattern[str]] = {
    "ui-ux-director": re.compile(
        r"(랜딩|landing|히어로|hero|브랜드|brand|온보딩|onboarding|디자인\s*디렉션|하이엔드|"
        r"기억에\s*남는|UI\s*재설계|redesign|visual\s*direction)",
        re.IGNORECASE,
    ),
    "fe-architect": re.compile(
        r"(프론트엔드\s*아키텍처|frontend\s*architecture|AppShell|라우팅|route|layout|레이아웃|상태관리)",
        re.IGNORECASE,
    ),
    "component-builder": re.compile(
        r"(컴포넌트|component|UI.{0,8}구현|버튼|button|모달|modal|카드|card|사이드바|네비게이션|Tailwind)",
        re.IGNORECASE,
    ),
    "a11y-auditor": re.compile(r"(접근성|a11y|WCAG|키보드|스크린리더|ARIA)", re.IGNORECASE),
    "globe-specialist": re.compile(
        r"(Globe|지구본|Three\.js|Canvas|3D|파티클|오버레이|HUD|렌더링|d3-geo|projection)",
        re.IGNORECASE,
    ),
    "i18n-specialist": re.compile(
        r"(i18n|번역|다국어|로케일|locale|translation|translations)",
        re.IGNORECASE,
    ),
    "ux-reviewer": re.compile(r"(UX|사용성|휴리스틱|사용자\s*경험|CRO|디자인\s*리뷰)", re.IGNORECASE),
    "style-reviewer": re.compile(r"(스타일|style|코드\s*리뷰|변경\s*검증|lint|컨벤션|중복)", re.IGNORECASE),
    "ml-researcher": re.compile(
        r"(ML|모델|학습|훈련|예측|AOD|SDID|PINN|DQSS|GNN|XGBoost|ONNX|Camera\s*AI|DINOv2|GTWR)",
        re.IGNORECASE,
    ),
    "data-engineer": re.compile(
        r"(ETL|파이프라인|pipeline|전처리|피처\s*엔지니어링|feature\s*engineering|Open-Meteo|ERA5|AirKorea)",
        re.IGNORECASE,
    ),
    "aq-data-analyst": re.compile(r"(PM2\.5|PM10|AQI|대기질|오염|IDW|크리깅|보간)", re.IGNORECASE),
    "db-architect": re.compile(
        r"(DB|데이터베이스|스키마|schema|RLS|마이그레이션|migration|Supabase|쿼리|테이블|인덱스|PostgreSQL)",
        re.IGNORECASE,
    ),
    "edge-fn-dev": re.compile(
        r"(Edge\s*Function|Deno|API|엔드포인트|endpoint|웹훅|webhook|JWT|CORS|Polar)",
        re.IGNORECASE,
    ),
    "test-engineer": re.compile(r"(테스트|test|Vitest|Playwright|pytest|커버리지|coverage|E2E|TDD)", re.IGNORECASE),
    "security-reviewer": re.compile(
        r"(보안|security|취약점|XSS|injection|CSRF|시크릿|secret|인증\s*우회|RLS\s*우회|HMAC)",
        re.IGNORECASE,
    ),
    "performance-reviewer": re.compile(
        r"(성능|performance|번들|bundle|LCP|CWV|Core\s*Web\s*Vitals|최적화|캐싱|메모리|렌더\s*최적화)",
        re.IGNORECASE,
    ),
    "deploy-manager": re.compile(r"(배포|deploy|CI/CD|GitHub\s*Actions|Cloudflare|릴리스|ship)", re.IGNORECASE),
    "doc-writer": re.compile(r"(문서|README|CHANGELOG|CLAUDE\.md|API\s*문서|docs?)", re.IGNORECASE),
    "wiki-curator": re.compile(r"(위키|wiki|Obsidian|index\.md|log\.md|교차\s*참조|메모리|기록)", re.IGNORECASE),
    "cost-analyst": re.compile(r"(비용|토큰\s*사용|quota|예산|사용량\s*분석|API\s*비용)", re.IGNORECASE),
    "supervisor": re.compile(
        r"(supervisor|라우팅|프롬프트\s*분석|에이전트\s*구성|하네스|harness|\bhooks?\b|훅)",
        re.IGNORECASE,
    ),
}

MODELS_AGENT_PATTERNS: dict[str, re.Pattern[str]] = {
    "aod-specialist": re.compile(r"(AOD|MAIAC|satellite|위성|GTWR)", re.IGNORECASE),
    "sdid-specialist": re.compile(r"(SDID|causal|ATT|synthetic\s*control|정책\s*효과|policy\s*effect)", re.IGNORECASE),
    "camera-ai-specialist": re.compile(r"(Camera\s*AI|DINOv2|CORN|ONNX|sky\s*segmentation)", re.IGNORECASE),
    "dqss-specialist": re.compile(r"(DQSS|quality|anomaly|Beta|reliability)", re.IGNORECASE),
    "ml-test-engineer": re.compile(r"(pytest|regression|sanity|coverage|모델\s*테스트)", re.IGNORECASE),
    "ml-security-reviewer": re.compile(r"(path\s*traversal|pickle|EXIF|ML\s*API\s*보안|PII)", re.IGNORECASE),
    # 2026-05-06 wave-3 — Hugging Face research collector (project agent, hf-research-integration plan).
    # Hub / arXiv / paper / HF model+space deep-research 의도 잡음. ml-researcher fallback.
    "hf-research-collector": re.compile(
        r"(Hugging\s*Face|huggingface|\bHF\b|arXiv|arxiv|paper_search|hub_repo|"
        r"hf_doc_search|space_search|paper\s*search|논문\s*수집|연구\s*수집)",
        re.IGNORECASE,
    ),
}

APP_AGENT_PATTERNS: dict[str, re.Pattern[str]] = {
    "capture-specialist": re.compile(
        r"(\bcapture\b|캡처|sky[-\s]?seg|sky\s*segmentation|"
        r"감정\s*슬라이더|감각\s*태그|sense\s*tag|CaptureScreen|captureStore|"
        r"SkyCropStep|SenseTagsStep|sky-mask)",
        re.IGNORECASE,
    ),
    "widget-specialist": re.compile(
        r"(\bwidget\b|위젯|WidgetKit|Glance|snapshot\s*JSON|deep\s*link|glanceable)",
        re.IGNORECASE,
    ),
    "mobile-ux-specialist": re.compile(
        r"(React\s*Native|\bRN\b|Expo|TodayScreen|InsightsScreen|JournalScreen|SettingsScreen|"
        r"V8Glass|V8SkyBackdrop|useV8Theme|sky\s*theme|동적\s*테마|design\s*token|"
        r"디자인\s*토큰|모바일\s*UX|모바일\s*UI|mobile\s*UX)",
        re.IGNORECASE,
    ),
    "sync-specialist": re.compile(
        r"(sync_queue|동기화|SQLite|expo-sqlite|journal_entries_local|"
        r"encrypted\s*backup|암호화\s*백업|AES-?256-?GCM|background-?fetch)",
        re.IGNORECASE,
    ),
    "health-specialist": re.compile(
        r"(HealthKit|Health\s*Connect|react-native-health|Screen\s*Time|스크린타임|"
        r"수면|걸음\s*수|mood\s*prediction|기분\s*예측|on-device\s*ML|useHealthData|useMoodTrend)",
        re.IGNORECASE,
    ),
    "payment-specialist": re.compile(
        r"(RevenueCat|react-native-purchases|\bIAP\b|in-app\s*purchase|paywall|"
        r"Pro\s*tier|StoreKit|BillingClient|entitlement|restore\s*purchase|subscriptionStore|useSubscription)",
        re.IGNORECASE,
    ),
}

CANONICAL_DOCS = {
    "platform": [
        "Obsidian-airlens/raw/docs/platform/PLATFORM_PRD.md",
        "Obsidian-airlens/raw/docs/platform/PLATFORM_ARCHITECTURE.md",
    ],
    "web": [
        "Obsidian-airlens/raw/docs/web/WEB_PRD.md",
        "Obsidian-airlens/raw/docs/web/WEB_ARCHITECTURE.md",
    ],
    "app": [
        "Obsidian-airlens/raw/docs/app/APP_PRD.md",
        "Obsidian-airlens/raw/docs/app/APP_ARCHITECTURE.md",
    ],
    "models": [
        "Obsidian-airlens/raw/docs/ml/MODELS_PRD.md",
        "Obsidian-airlens/raw/docs/ml/MODELS_ARCHITECTURE.md",
    ],
    "db": [
        "Obsidian-airlens/raw/docs/db/DATABASE_SCHEMA.md",
        "Obsidian-airlens/raw/docs/platform/PLATFORM_ARCHITECTURE.md",
    ],
    "harness": [
        "Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md",
    ],
    "security": [
        ".claude/rules/public-repo.md",          # § Local Secret Scan + git safety guardrail
        ".claude/rules/multi-agent-worktree.md", # R4 자원 mutex (production-db / edge-function-deploy)
        "gitleaks.toml",                          # 시크릿 스캔 룰셋·allowlist (Layer 1+2 공용)
        ".github/workflows/secret-scan.yml",      # CI Layer 2 워크플로
    ],
}

ALWAYS_ALLOW_PATTERNS = (
    "scripts/hooks/",
    "scripts/git-hooks/",  # 확장자 없는 git hook 파일 (pre-commit/post-commit/pre-push) 대비
    ".claude/",
    "CLAUDE.md",
    "package.json",
    "tsconfig",
    ".env",
    "vite.config",
    "tailwind.config",
    "eslint",
    "Obsidian-airlens/",
    "memory/",
    "plans/",
    "public/",
)
ALWAYS_ALLOW_EXTENSIONS = (
    ".md",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".css",
    ".html",
    ".svg",
    ".png",
    ".jpg",
    ".jpeg",
)


@dataclass
class AgentInfo:
    id: str
    scope: str = "unknown"
    domain: str = "general"
    department: str = ""
    model: str = "sonnet"
    risk: str = "LOW"
    airlens_mode: str = "reference_only"
    use_condition: str = ""
    level: int | None = None
    path: str = ""
    executable: bool = False
    fallback_only: bool = True
    reason: str = ""


@dataclass
class RegistryIndex:
    agents: dict[str, AgentInfo] = field(default_factory=dict)
    departments: dict[str, dict[str, Any]] = field(default_factory=dict)
    workflows: dict[str, dict[str, Any]] = field(default_factory=dict)
    models_departments: dict[str, dict[str, Any]] = field(default_factory=dict)
    app_departments: dict[str, dict[str, Any]] = field(default_factory=dict)
    workflow_errors: list[str] = field(default_factory=list)


def _load_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def _path_exists(path_text: str) -> bool:
    if not path_text:
        return False
    expanded = Path(path_text.replace("~", str(Path.home()), 1))
    if expanded.is_absolute():
        return expanded.exists()
    return (PROJECT_ROOT / expanded).exists()


def load_registry_index() -> RegistryIndex:
    index = RegistryIndex()

    master = _load_json(MASTER_REGISTRY, {})
    for raw in master.get("agents", []):
        agent_id = raw.get("id", "")
        if not agent_id:
            continue
        scope = raw.get("scope", "unknown")
        path_text = raw.get("path", "")
        airlens_mode = raw.get("airlens_mode") or ("direct" if scope == "AirLens-web" else "reference_only")
        executable = _path_exists(path_text) and (
            scope == "AirLens-web" or (scope == "global" and airlens_mode == "direct")
        )
        index.agents[agent_id] = AgentInfo(
            id=agent_id,
            scope=scope,
            domain=raw.get("domain", "general"),
            model=raw.get("model", "sonnet"),
            risk=raw.get("risk", "LOW"),
            airlens_mode=airlens_mode,
            use_condition=raw.get("use_condition", ""),
            path=path_text,
            executable=executable,
            fallback_only=not executable,
            reason="" if executable else raw.get("use_condition") or "reference-only or not loaded in current Claude runtime",
        )

    web = _load_json(WEB_REGISTRY, {})
    for raw in web.get("agents", []):
        agent_id = raw.get("id", "")
        if not agent_id:
            continue
        current = index.agents.get(agent_id, AgentInfo(id=agent_id, scope="AirLens-web"))
        current.department = raw.get("department", current.department)
        current.model = raw.get("model", current.model or "sonnet")
        current.level = raw.get("level", current.level)
        current.executable = True
        current.fallback_only = False
        current.reason = ""
        index.agents[agent_id] = current

    tier1 = _load_json(WEB_TIER1, {})
    index.departments = tier1.get("departments", {})
    workflows = _load_json(WORKFLOWS_FILE, {})
    index.workflows = workflows.get("workflows", {})

    models = _load_json(MODELS_TIER1, {})
    index.models_departments = models.get("departments", {})
    for dept in index.models_departments.values():
        for agent_id in dept.get("agents", []):
            path_text = f"models/.claude/agents/{agent_id}.md"
            index.agents.setdefault(
                agent_id,
                AgentInfo(
                    id=agent_id,
                    scope="AirLens-models",
                    domain="ml",
                    department="models",
                    path=path_text,
                    executable=False,
                    fallback_only=True,
                    reason="AirLens-models specialist; route as candidate, use ml-researcher fallback from root",
                ),
            )

    # apps/app workspace registry override (post 2026-04-30 mobile bootstrap)
    app_reg = _load_json(APP_REGISTRY, {})
    for raw in app_reg.get("agents", []):
        agent_id = raw.get("id", "")
        if not agent_id:
            continue
        current = index.agents.get(
            agent_id, AgentInfo(id=agent_id, scope="AirLens-app", domain="mobile")
        )
        current.scope = "AirLens-app"
        current.domain = current.domain or "mobile"
        current.department = raw.get("department", current.department)
        current.model = raw.get("model", current.model or "sonnet")
        current.level = raw.get("level", current.level)
        current.path = raw.get("path") or f"apps/app/.claude/agents/{agent_id}.md"
        current.executable = True
        current.fallback_only = False
        current.reason = ""
        index.agents[agent_id] = current

    app_tier1 = _load_json(APP_TIER1, {})
    index.app_departments = app_tier1.get("departments", {})

    index.workflow_errors = validate_workflow_agents(index)
    return index


def validate_workflow_agents(index: RegistryIndex) -> list[str]:
    known = set(index.agents) | {"Plan", "plan", "{matched_specialist}", "{matched_agents}"}
    errors: list[str] = []
    for workflow_id, workflow in index.workflows.items():
        for step in workflow.get("steps", []):
            for agent_id in step.get("agents", []):
                if agent_id not in known:
                    errors.append(f"{workflow_id}:{step.get('name', '?')} references unknown agent {agent_id}")
    return errors


def classify_prompt(prompt: str) -> str:
    stripped = prompt.strip()
    if not stripped:
        return "SIMPLE_EDIT"
    if SELF_DRIVING_PM_RE.search(prompt):
        return "SELF_DRIVING_PM"
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
    if SIMPLE_RE.search(prompt) and not HIGH_RISK_RE.search(prompt):
        return "SIMPLE_EDIT"
    if FEATURE_RE.search(prompt):
        return "FEATURE"
    if QUERY_RE.search(prompt):
        return "QUERY"
    return "SIMPLE_EDIT"


def match_department(prompt: str, departments: dict[str, dict[str, Any]]) -> list[str]:
    prompt_lower = prompt.lower()
    scored: list[tuple[int, str]] = []
    for dept_id, dept in departments.items():
        score = sum(1 for kw in dept.get("triggerKeywords", []) if str(kw).lower() in prompt_lower)
        if score > 0:
            scored.append((score, dept_id))
    scored.sort(reverse=True)
    return [dept_id for _, dept_id in scored]


def match_scope(prompt: str, index: RegistryIndex) -> str:
    # Mobile-specific keywords take precedence — these are unique to apps/app even if "ONNX" appears
    # (e.g., on-device sky-seg uses ONNX in mobile context, not models training)
    mobile_native = re.search(
        r"(AirLens-app|React\s*Native|\bExpo\b|HealthKit|Health\s*Connect|RevenueCat|"
        r"WidgetKit|Glance|Screen\s*Time|expo-sqlite|sync_queue|paywall|"
        r"\b앱\b|모바일|캡처|위젯|스크린타임|paywall|결제\s*검증)",
        prompt, re.IGNORECASE,
    )
    if mobile_native:
        return "AirLens-app"
    if re.search(r"(AirLens-models|\bAOD\b|\bSDID\b|\bDQSS\b|GTWR|DINOv2|학습|훈련)", prompt, re.IGNORECASE):
        return "AirLens-models" if index.models_departments else "AirLens-web"
    # Generic ONNX without mobile context → models
    if re.search(r"\bONNX\b", prompt, re.IGNORECASE):
        return "AirLens-models" if index.models_departments else "AirLens-web"
    if re.search(r"(\bApp\b|life-?log|\bcapture\b|mobile)", prompt, re.IGNORECASE):
        return "AirLens-app"
    if META_RE.search(prompt):
        return "platform"
    return "AirLens-web"


def _append_unique(items: list[str], additions: list[str]) -> None:
    for item in additions:
        if item not in items:
            items.append(item)


def canonical_docs_for_prompt(prompt: str, scope: str, agents: list[dict[str, Any]]) -> list[str]:
    if not CANONICAL_RE.search(prompt):
        return []

    docs: list[str] = []
    agent_ids = {a["id"] for a in agents}
    web_match = re.search(r"\b(web|frontend|UI|UX|Globe|route|component|Insights?)\b|프론트|웹|페이지|컴포넌트|시나리오", prompt, re.IGNORECASE)
    app_match = re.search(r"\b(app|mobile|Expo|React Native|life-?log|capture)\b|모바일|캡처|저널", prompt, re.IGNORECASE)
    models_match = re.search(r"\b(models?|ML|AOD|SDID|DQSS|GTWR|Camera AI|DINOv2|ONNX)\b|모델|학습|훈련", prompt, re.IGNORECASE)
    db_match = "db-architect" in agent_ids or re.search(r"\b(DB|database|Supabase|RLS|migration|schema|PostgreSQL)\b|데이터베이스|마이그레이션|스키마", prompt, re.IGNORECASE)
    platform_match = re.search(r"\b(platform|multi-?dept|cross-?project)\b|플랫폼|멀티|공유", prompt, re.IGNORECASE)
    harness_match = "supervisor" in agent_ids or re.search(r"\b(supervisor|harness|hooks?)\b|하네스|훅|라우팅|에이전트", prompt, re.IGNORECASE)
    security_match = "security-reviewer" in agent_ids or re.search(
        r"\b(security|secret|gitleaks|pre-commit|XSS|CSRF|HMAC|push\s*protection)\b"
        r"|시크릿|보안|취약점|시크릿\s*스캔|RLS\s*우회",
        prompt, re.IGNORECASE,
    )

    if web_match:
        _append_unique(docs, CANONICAL_DOCS["web"])
    if scope == "AirLens-app" or app_match:
        _append_unique(docs, CANONICAL_DOCS["app"])
    if scope == "AirLens-models" or models_match:
        _append_unique(docs, CANONICAL_DOCS["models"])
    if db_match:
        _append_unique(docs, CANONICAL_DOCS["db"])
    if scope == "platform" or platform_match:
        _append_unique(docs, CANONICAL_DOCS["platform"])
    if harness_match:
        _append_unique(docs, CANONICAL_DOCS["harness"])
    if security_match:
        _append_unique(docs, CANONICAL_DOCS["security"])

    if not docs:
        if scope == "AirLens-models":
            _append_unique(docs, CANONICAL_DOCS["models"])
        elif scope == "AirLens-app":
            _append_unique(docs, CANONICAL_DOCS["app"])
        elif scope == "platform":
            _append_unique(docs, CANONICAL_DOCS["platform"])
        else:
            _append_unique(docs, CANONICAL_DOCS["web"])
    return docs


def match_agents(prompt: str, index: RegistryIndex) -> list[dict[str, Any]]:
    ordered: list[str] = []
    for agent_id, pattern in AGENT_PATTERNS.items():
        if pattern.search(prompt):
            ordered.append(agent_id)
    for agent_id, pattern in MODELS_AGENT_PATTERNS.items():
        if pattern.search(prompt):
            ordered.append(agent_id)
    for agent_id, pattern in APP_AGENT_PATTERNS.items():
        if pattern.search(prompt):
            ordered.append(agent_id)

    deduped: list[str] = []
    for agent_id in ordered:
        if agent_id not in deduped:
            deduped.append(agent_id)

    agents: list[dict[str, Any]] = []
    for agent_id in deduped:
        info = index.agents.get(agent_id, AgentInfo(id=agent_id))
        fallback = ""
        if info.fallback_only and info.scope == "AirLens-models":
            fallback = "ml-researcher"
        agents.append(
            {
                "id": info.id,
                "scope": info.scope,
                "department": info.department,
                "model": info.model,
                "executable": info.executable,
                "fallback_only": info.fallback_only,
                "fallback": fallback,
                "reason": info.reason,
            }
        )
    return agents


def select_workflow(intent: str, prompt: str, index: RegistryIndex) -> str:
    if intent == "MULTI_DEPT":
        return "multi-dept"
    if intent == "SELF_DRIVING_PM":
        return "query"
    if intent in {"FEATURE", "MULTI_DEPT"}:
        for workflow_id, workflow in index.workflows.items():
            keywords = workflow.get("triggerKeywords", [])
            if keywords and any(str(kw).lower() in prompt.lower() for kw in keywords):
                return workflow_id
    if intent in {"QUERY", "META", "REVIEW/AUDIT"}:
        return "query"
    if intent == "FEATURE":
        return "feature-dev"
    return ""


def assess_risk(intent: str, prompt: str, departments: list[str], agents: list[dict[str, Any]]) -> str:
    if intent == "SELF_DRIVING_PM":
        return "HIGH" if HIGH_RISK_RE.search(prompt) else "LOW"
    if intent in {"QUERY", "META", "REVIEW/AUDIT", "RECALL", "LEARN"}:
        return "LOW"
    if intent == "MULTI_DEPT" or len(set(departments)) >= 2:
        return "HIGH"
    if HIGH_RISK_RE.search(prompt):
        return "HIGH"
    if any(a["id"] in {"db-architect", "security-reviewer", "deploy-manager", "edge-fn-dev"} for a in agents):
        return "HIGH"
    if intent == "FEATURE":
        return "MEDIUM"
    return "LOW"


def required_checks(
    intent: str,
    risk: str,
    agents: list[dict[str, Any]],
    workflow_id: str,
    canonical_docs: list[str] | None = None,
) -> list[str]:
    checks: list[str] = []
    if intent in {"FEATURE", "MULTI_DEPT"}:
        checks.append("Plan recommended")
        checks.append("post-edit quality gate")
    if canonical_docs:
        checks.append("canonical PRD/Architecture evidence")
    if workflow_id == "ui-design-dev":
        checks.extend(["ui-ux-director design brief", "ux-reviewer/style-reviewer"])
    agent_ids = {a["id"] for a in agents}
    if "db-architect" in agent_ids:
        checks.extend(["Supabase migration review", "RLS policy review"])
    if "security-reviewer" in agent_ids or "edge-fn-dev" in agent_ids:
        checks.append("security review")
    if "test-engineer" in agent_ids or intent in {"FEATURE", "MULTI_DEPT"}:
        checks.append("targeted tests")
    if risk == "HIGH":
        checks.append("dispatch verification before high-risk Write/Edit")
    if intent == "SELF_DRIVING_PM":
        checks.append("queue schema validation")
        checks.append("bounded queue verification")
        if risk == "HIGH":
            checks.append("approval_required for deploy/merge/secret work")
    return list(dict.fromkeys(checks))


def analyze_prompt(prompt: str, index: RegistryIndex | None = None) -> dict[str, Any]:
    index = index or load_registry_index()
    intent = classify_prompt(prompt)
    # Merge web + app dept registries (apps/web + apps/app); namespace prefixes prevent collision
    merged_departments = {**index.departments, **index.app_departments}
    departments = match_department(prompt, merged_departments)
    scope = match_scope(prompt, index)
    agents = match_agents(prompt, index)

    agent_departments = {a["department"] for a in agents if a.get("department")}
    effective_depts = set(departments) | agent_departments
    if intent == "FEATURE" and len(effective_depts) >= 2:
        intent = "MULTI_DEPT"

    if intent == "SELF_DRIVING_PM":
        agents = []

    if intent in {"META", "REVIEW/AUDIT", "SELF_DRIVING_PM"} and not agents:
        info = index.agents.get("supervisor", AgentInfo(id="supervisor", executable=True, fallback_only=False))
        agents = [
            {
                "id": "supervisor",
                "scope": info.scope,
                "department": info.department or "operations",
                "model": info.model or "opus",
                "executable": True,
                "fallback_only": False,
                "fallback": "",
                "reason": "meta/supervisor request" if intent != "SELF_DRIVING_PM" else "self-driving PM queue request",
            }
        ]
        departments = departments or ["operations"]

    workflow_id = select_workflow(intent, prompt, index)
    risk = assess_risk(intent, prompt, departments, agents)
    canonical_docs = canonical_docs_for_prompt(prompt, scope, agents)
    executable_agents = [a["id"] for a in agents if a["executable"] and not a["fallback_only"]]
    reference_agents = [a["id"] for a in agents if a["fallback_only"]]
    if reference_agents and "ml-researcher" not in executable_agents:
        executable_agents.append("ml-researcher")

    rationale = []
    if departments:
        rationale.append(f"department keywords matched: {', '.join(departments)}")
    if agents:
        rationale.append(f"agent patterns matched: {', '.join(a['id'] for a in agents)}")
    if workflow_id:
        rationale.append(f"workflow selected: {workflow_id}")
    if reference_agents:
        rationale.append(f"reference-only candidates: {', '.join(reference_agents)}")
    if not rationale:
        rationale.append("fallback classification")

    return {
        "intent": intent if intent in INTENTS else "SIMPLE_EDIT",
        "scope": scope,
        "departments": departments,
        "agents": agents,
        "matched_agents": executable_agents,
        "reference_agents": reference_agents,
        "risk": risk,
        "workflow": workflow_id,
        "canonical_docs": canonical_docs,
        "rationale": "; ".join(rationale),
        "required_checks": required_checks(intent, risk, agents, workflow_id, canonical_docs),
        "workflow_errors": index.workflow_errors,
    }


def _workflow_agent_ids(workflow: dict[str, Any], analysis: dict[str, Any]) -> list[str]:
    matched = analysis.get("matched_agents", [])
    out: list[str] = []
    for step in workflow.get("steps", []):
        for agent_id in step.get("agents", []):
            if agent_id == "{matched_specialist}":
                out.extend(matched[:1] or ["supervisor"])
            elif agent_id == "{matched_agents}":
                out.extend(matched or ["supervisor"])
            elif agent_id == "Plan":
                out.append("Plan")
            else:
                out.append(agent_id)
    deduped: list[str] = []
    for agent_id in out:
        if agent_id not in deduped:
            deduped.append(agent_id)
    return deduped


def render_workflow(index: RegistryIndex, analysis: dict[str, Any]) -> str:
    workflow_id = analysis.get("workflow")
    workflow = index.workflows.get(workflow_id, {}) if workflow_id else {}
    if not workflow:
        agents = analysis.get("matched_agents", [])
        if not agents:
            return ""
        return "Recommended agents: " + ", ".join(f"Agent(subagent_type='{a}', prompt='[task]')" for a in agents)

    lines = [f"Workflow: {workflow_id} - {workflow.get('description', '')}"]
    for i, step in enumerate(workflow.get("steps", []), 1):
        resolved = []
        for agent_id in step.get("agents", []):
            if agent_id == "{matched_specialist}":
                resolved.extend(analysis.get("matched_agents", [])[:1] or ["supervisor"])
            elif agent_id == "{matched_agents}":
                resolved.extend(analysis.get("matched_agents", []) or ["supervisor"])
            else:
                resolved.append(agent_id)

        parallel = " parallel" if step.get("parallel") and len(resolved) > 1 else ""
        lines.append(f"Step {i} ({step.get('name', 'unnamed')}{parallel}):")
        for agent_id in resolved:
            info = index.agents.get(agent_id.lower(), index.agents.get(agent_id, AgentInfo(id=agent_id)))
            model = step.get("model", info.model or "sonnet")
            if model == "{dept_model}":
                first = (analysis.get("matched_agents") or ["supervisor"])[0]
                model = index.agents.get(first, AgentInfo(id=first)).model or "sonnet"
            prompt_hint = "[requirements]" if agent_id.lower() == "plan" else "[task]"
            lines.append(f"  Agent(subagent_type='{agent_id}', model='{model}', prompt='{prompt_hint}')")
    return "\n".join(lines)


def emit_hint(analysis: dict[str, Any], index: RegistryIndex) -> dict[str, str]:
    intent = analysis["intent"]
    if intent in {"SIMPLE_EDIT", "RECALL", "LEARN"}:
        return {}

    header = (
        f"SUPERVISOR v6 | intent={intent} | risk={analysis['risk']} | "
        f"scope={analysis['scope']} | workflow={analysis.get('workflow') or 'none'}"
    )
    body = [
        header,
        f"Reason: {analysis['rationale']}",
    ]
    if analysis.get("reference_agents"):
        body.append(
            "Reference-only candidates: "
            + ", ".join(analysis["reference_agents"])
            + " (use executable fallback from matched_agents)"
        )
    if analysis.get("canonical_docs"):
        body.append("Canonical docs: " + ", ".join(analysis["canonical_docs"]))

    if intent in {"FEATURE", "MULTI_DEPT"}:
        body.append(render_workflow(index, analysis))
        if analysis.get("required_checks"):
            body.append("Checks: " + ", ".join(analysis["required_checks"]))
        if analysis["risk"] == "HIGH" or intent == "MULTI_DEPT":
            body.append("High-risk verification: Plan/specialist dispatch may be required before Write/Edit.")
    elif intent in {"QUERY", "META", "REVIEW/AUDIT"}:
        agents = analysis.get("matched_agents") or ["supervisor"]
        body.append("Recommended reviewer/specialist: " + ", ".join(agents[:3]))
        body.append(f"Suggested call: Agent(subagent_type='{agents[0]}', prompt='[question or audit scope]')")
    elif intent == "SELF_DRIVING_PM":
        body.append("Queue runner: python3 scripts/pm/task_queue.py next")
        body.append("M1 policy: suggest/verify/update evidence only; approval_required for deploy, merge, secrets, and production work.")
        if analysis.get("required_checks"):
            body.append("Checks: " + ", ".join(analysis["required_checks"]))

    if analysis.get("workflow_errors"):
        body.append("Registry/workflow validation errors: " + "; ".join(analysis["workflow_errors"]))

    message = "\n".join(part for part in body if part)
    return {"systemMessage": message} if message else {}


def write_flags(prompt: str, analysis: dict[str, Any]) -> None:
    intent = analysis["intent"]
    risk = analysis["risk"]
    matched_agents = analysis.get("matched_agents", [])

    ANALYSIS_FLAG.write_text(json.dumps(analysis, ensure_ascii=False), encoding="utf-8")

    if intent in {"FEATURE", "MULTI_DEPT"}:
        INTENT_FLAG.write_text(prompt[:500], encoding="utf-8")
        HARNESS_FLAG.write_text(risk, encoding="utf-8")
        # 2026-05-01 fix: DISPATCHED_FLAG.unlink() 제거. 매 prompt마다 reset되면 turn 1에서
        # specialist dispatch → turn 2에서 Write 시 dispatched 비어 즉시 차단되는 회귀 발생.
        # PostToolUse가 add-only로 누적, 세션 단위 reset은 SessionStart hook에서 처리.
        # 누적 false-positive는 PreToolUse intersection 검사로 차단됨.
        if matched_agents:
            REQUIRED_FLAG.write_text(json.dumps(matched_agents[:5], ensure_ascii=False), encoding="utf-8")
        else:
            REQUIRED_FLAG.unlink(missing_ok=True)
        return

    INTENT_FLAG.unlink(missing_ok=True)
    HARNESS_FLAG.unlink(missing_ok=True)
    REQUIRED_FLAG.unlink(missing_ok=True)
    DISPATCHED_FLAG.unlink(missing_ok=True)
    if intent == "SIMPLE_EDIT":
        PLAN_FLAG.unlink(missing_ok=True)


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


def _resolve_event(input_data: dict[str, Any]) -> str:
    return str(
        input_data.get("hook_event_name")
        or input_data.get("event")
        or os.environ.get("CLAUDE_HOOK_EVENT", "")
    ).strip()


def _prompt_from_input(input_data: dict[str, Any]) -> str:
    prompt = (
        input_data.get("user_prompt")
        or input_data.get("prompt")
        or input_data.get("input")
        or input_data.get("tool_input", {}).get("user_prompt")
        or ""
    )
    return prompt if isinstance(prompt, str) else ""


def _read_input() -> dict[str, Any]:
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return {}
    try:
        return json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return {}


def has_active_plan() -> bool:
    if PLAN_FLAG.exists():
        return True
    plans_dir = Path.home() / ".claude" / "plans"
    return plans_dir.exists() and any(plans_dir.glob("*.md"))


def should_bypass_path(file_path: str) -> bool:
    for pattern in ALWAYS_ALLOW_PATTERNS:
        if pattern in file_path:
            return True
    return file_path.endswith(ALWAYS_ALLOW_EXTENSIONS)


def _load_analysis_flag() -> dict[str, Any]:
    try:
        return json.loads(ANALYSIS_FLAG.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _load_json_list(path: Path) -> list[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        return []


def _expand_dispatched(raw: list[str]) -> set[str]:
    """Expand dispatched agent names through AGENT_ALIASES; drop generics.

    - Names in NON_SPECIALIST_AGENTS contribute zero coverage (Explore, Plan, etc.).
    - Names in AGENT_ALIASES contribute themselves AND their mapped specialists.
    - Other names contribute themselves verbatim (covers exact matches like
      ``ml-researcher`` dispatched directly).
    """
    expanded: set[str] = set()
    for agent in raw:
        if not isinstance(agent, str):
            continue
        if agent in NON_SPECIALIST_AGENTS:
            continue
        expanded.add(agent)
        for alias in AGENT_ALIASES.get(agent, ()):
            expanded.add(alias)
    return expanded


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


def handle_pre_tool_use(input_data: dict[str, Any]) -> None:
    tool_name = input_data.get("tool_name") or input_data.get("tool") or ""
    if tool_name not in {"Write", "Edit", "MultiEdit"}:
        print(json.dumps({"decision": "allow"}))
        return

    tool_input = input_data.get("tool_input", {})
    file_path = str(tool_input.get("file_path") or "")
    if not file_path or should_bypass_path(file_path):
        print(json.dumps({"decision": "allow"}))
        return

    analysis = _load_analysis_flag()
    intent = analysis.get("intent")
    risk = analysis.get("risk")
    if intent != "MULTI_DEPT" and risk != "HIGH":
        print(json.dumps({"decision": "allow"}))
        return

    if not has_active_plan():
        reason = (
            "SUPERVISOR VERIFICATION - high-risk or multi-department write blocked.\n"
            f"Intent={intent}, risk={risk}, workflow={analysis.get('workflow') or 'none'}.\n"
            "Run Plan/plan first, then retry the edit."
        )
        print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
        return

    required = _load_json_list(REQUIRED_FLAG)
    dispatched = _expand_dispatched(_load_json_list(DISPATCHED_FLAG))
    required_set = set(required)
    coverage = dispatched.intersection(required_set)
    # 2026-05-01 fix: 단일 invariant — required ≥ 1 일 때 dispatched와 교집합 0 이면 block.
    # 기존: (required and not dispatched) 첫번째 조건은 dispatched 누적 후 false-positive
    # 회피 못함. intersection 기반 통합으로 누적 안전성 확보.
    if required and not coverage:
        missing = [a for a in required if a.lower() != "plan"]
        suggestions: list[dict[str, Any]] = []
        seen_subagents: set[str] = set()
        for spec in missing:
            # Native dispatch — if AirLens has the specialist agent file directly,
            # subagent_type=spec satisfies coverage exactly.
            if spec not in seen_subagents:
                suggestions.append({
                    "subagent_type": spec,
                    "covers": spec,
                    "why": "native AirLens specialist (direct match)",
                })
                seen_subagents.add(spec)
            # Aliased dispatch — global agents that expand to this specialist.
            for global_agent in _REVERSE_ALIASES.get(spec, []):
                if global_agent in seen_subagents:
                    continue
                suggestions.append({
                    "subagent_type": global_agent,
                    "covers": spec,
                    "why": f"global agent aliases to {spec}",
                })
                seen_subagents.add(global_agent)

        # Build structured reason text Claude can parse deterministically.
        lines = [
            "SUPERVISOR VERIFICATION - specialist coverage missing for high-risk work.",
            f"Required: {', '.join(required)}",
            "Dispatched (after alias expansion): "
            + (", ".join(sorted(dispatched)) if dispatched else "(none)"),
            f"Missing: {', '.join(missing) if missing else '(none)'}",
            "",
            "To unblock, invoke ONE of these via the Agent tool:",
        ]
        for idx, sugg in enumerate(suggestions, 1):
            lines.append(
                f"  Option {idx}: subagent_type=\"{sugg['subagent_type']}\" "
                f"(covers {sugg['covers']} — {sugg['why']})"
            )
        if not suggestions:
            lines.append("  (no alias known — dispatch the specialist directly by name)")
        lines.append("")
        lines.append("Then retry the Write/Edit. Plan must remain active.")
        reason = "\n".join(lines)
        payload = {
            "decision": "block",
            "reason": reason,
            "missing_specialists": missing,
            "suggested_invocations": suggestions,
        }
        print(json.dumps(payload, ensure_ascii=False))
        return

    print(json.dumps({"decision": "allow"}))


def handle_post_tool_use(input_data: dict[str, Any]) -> None:
    if input_data.get("tool_name") != "Agent":
        print(json.dumps({}))
        return
    tool_input = input_data.get("tool_input", {})
    subagent_type = tool_input.get("subagent_type")
    if not subagent_type:
        print(json.dumps({}))
        return
    existing = set(_load_json_list(DISPATCHED_FLAG))
    existing.add(str(subagent_type))
    try:
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
