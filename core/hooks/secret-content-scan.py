#!/usr/bin/env python3
"""
PreToolUse hook: detect secret bypass patterns in Write/Edit/MultiEdit content.

Layer 3 보강 (`.claude/rules/policy/security-guards.md §2`). Bash `pre-tool-guard.sh`
가 못 잡는 우회 경로 (Python `open('secrets/')`, Node `fs.readFileSync('.env*')`,
하드코딩 secret key value, sk-/JWT 토큰 패턴) 를 작업-time 에 deny.

Reads tool_input from stdin (JSON).
Exit 0 + empty stdout = allow; Exit 0 + permissionDecision="deny" = block.
"""
import sys
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

# Files / paths exempt from secret content scan
EXEMPT_PATHS = [
    ".env.example",
    "gitleaks.toml",
    "Obsidian-airlens/",
    "/__tests__/",
    "/tests/",
    "/test/",
    ".test.",
    ".spec.",
    ".fixture.",
    # Self + sibling test/MCP scanner
    "secret-content-scan.py",
    "secret-content-scan-test.sh",
    "secret-mcp-input-scan.py",
    # Hooks that cite the same patterns
    "/scripts/hooks/pre-tool-guard.sh",
    "/scripts/hooks/check-hardcoding.py",
    "/scripts/hooks/_archive/",
    # Policy + skill docs (cite variable names, no values)
    ".claude/rules/",
    ".claude/skills/",
    # Plan files (~/.claude/plans/)
    "/plans/",
    # CI definition
    ".github/workflows/secret-scan.yml",
]

# Patterns that indicate secret bypass attempts in source content
SECRET_PATTERNS = [
    # Python open() into secrets/ dir
    (
        r"""\bopen\s*\(\s*['"][^'"]*?secrets/""",
        "Python open() reading from secrets/",
    ),
    # Python open() into .env* (excluding .env.example)
    (
        r"""\bopen\s*\(\s*['"][^'"]*?\.env(?!\.example)""",
        "Python open() reading from .env*",
    ),
    # Node fs.readFileSync / fs.readSync into secrets/
    (
        r"""\bfs\.(?:promises\.)?read(?:File)?Sync\s*\(\s*['"][^'"]*?secrets/""",
        "Node fs.readFileSync() reading from secrets/",
    ),
    # Node fs.readFileSync into .env* (excluding .env.example)
    (
        r"""\bfs\.(?:promises\.)?read(?:File)?Sync\s*\(\s*['"][^'"]*?\.env(?!\.example)""",
        "Node fs.readFileSync() reading from .env*",
    ),
    # Hardcoded secret key value: VAR = "..." (20+ chars)
    (
        r"""\b(?:SUPABASE_SERVICE_ROLE_KEY|WAQI_TOKEN|OPENAQ_API_KEY|CLOUDFLARE_API_TOKEN|ANTHROPIC_API_KEY|OPENAI_API_KEY|STRIPE_SECRET_KEY|POLAR_API_KEY|RC_SECRET_KEY)\s*[:=]\s*['"][A-Za-z0-9_\-\.]{20,}['"]""",
        "hardcoded secret key value",
    ),
    # OpenAI / Stripe API key pattern — word-boundary (no quote required, catches URL/MCP)
    (
        r"""\bsk-[A-Za-z0-9_\-]{40,}\b""",
        "OpenAI/Stripe API key (sk-...)",
    ),
    # JWT token (3 dot-separated base64url segments) — word-boundary
    (
        r"""\beyJ[A-Za-z0-9_\-]{20,}\.eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b""",
        "JWT token (eyJ...)",
    ),
]


def is_exempt(file_path: str) -> bool:
    for pattern in EXEMPT_PATHS:
        if pattern in file_path:
            return True
    return False


def scan_content(content: str) -> list[tuple[str, str]]:
    findings: list[tuple[str, str]] = []
    for pattern, label in SECRET_PATTERNS:
        match = re.search(pattern, content)
        if match:
            snippet = match.group(0)
            if len(snippet) > 80:
                snippet = snippet[:77] + "..."
            findings.append((label, snippet))
    return findings


def log_violation(reason: str) -> None:
    """Write security violation record to .claude/logs/security-violations.jsonl (schema v2).

    Matches bash log_violation() in pre-tool-guard.sh / context-mode-guard.sh / gsd-cwd-guard.sh / r4-mutex-check.sh.
    Silent fail — broadcast best-effort.
    """
    repo_root = os.environ.get("CLAUDE_PROJECT_DIR")
    if not repo_root:
        try:
            repo_root = subprocess.check_output(
                ["git", "rev-parse", "--show-toplevel"],
                stderr=subprocess.DEVNULL,
            ).decode().strip()
        except Exception:
            return

    if not repo_root:
        return

    log_dir = Path(repo_root) / ".claude" / "logs"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        return

    repro_env = os.environ.get("AIRLENS_REPRODUCE_TEST", "")
    reproduce_test = repro_env in ("1", "true", "TRUE", "True")

    record = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "guard": 2,
        "hook": "secret-content-scan.py",
        "reason": reason,
        "session_id": os.environ.get("AGENT_SESSION_ID", "main"),
        "decision": "deny",
        "reproduce_test": reproduce_test,
        "schema_version": "2.0.0",
    }
    try:
        with open(log_dir / "security-violations.jsonl", "a") as f:
            f.write(json.dumps(record) + "\n")
    except Exception:
        pass

    # work-feed broadcast (R13 — blocked event, multi-agent visibility)
    try:
        broadcast = Path(repo_root) / "scripts" / "infra" / "agent-session.sh"
        if broadcast.is_file() and os.access(broadcast, os.X_OK):
            subprocess.run(
                [str(broadcast), "broadcast", "blocked",
                 f"[security] secret-content-scan.py: {reason}"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
            )
    except Exception:
        pass


def emit_deny(reason: str) -> None:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(output, ensure_ascii=False))


def walk_strings(obj) -> list[str]:
    """Recursive collect all string values from nested dict/list."""
    if isinstance(obj, str):
        return [obj]
    if isinstance(obj, dict):
        return [s for v in obj.values() for s in walk_strings(v)]
    if isinstance(obj, list):
        return [s for v in obj for s in walk_strings(v)]
    return []


# MCP write/external tool prefixes — recursive walk_strings on tool_input.
# (P2 — secrets-bypass-mcp-url-content.md)
MCP_RECURSIVE_PREFIXES = (
    "mcp__firecrawl__",
    "mcp__plugin_context-mode_",
    "mcp__plugin_context_mode_",
    "mcp__claude_ai_Notion__",
    "mcp__claude_ai_Google_Drive__",
    "mcp__stitch__",
)


def extract_chunks(tool_name: str, tool_input: dict) -> list[str]:
    """Pull scannable string content from Write/Edit/MultiEdit or MCP tool input."""
    chunks: list[str] = []
    if tool_name in ("Write", "Edit", "MultiEdit"):
        for key in ("content", "new_string", "new_content"):
            value = tool_input.get(key)
            if isinstance(value, str):
                chunks.append(value)
        edits = tool_input.get("edits")
        if isinstance(edits, list):
            for edit in edits:
                if isinstance(edit, dict) and isinstance(edit.get("new_string"), str):
                    chunks.append(edit["new_string"])
    elif tool_name.startswith("mcp__supabase__"):
        # execute_sql / apply_migration / deploy_edge_function
        for key in ("query", "name"):
            value = tool_input.get(key)
            if isinstance(value, str):
                chunks.append(value)
        files = tool_input.get("files")
        if isinstance(files, list):
            for entry in files:
                if isinstance(entry, dict) and isinstance(entry.get("content"), str):
                    chunks.append(entry["content"])
    elif any(tool_name.startswith(p) for p in MCP_RECURSIVE_PREFIXES):
        # firecrawl / context-mode / Notion / Drive / stitch — full recursive walk
        chunks.extend(walk_strings(tool_input))
    elif tool_name == "WebFetch":
        for key in ("url", "prompt"):
            value = tool_input.get(key)
            if isinstance(value, str):
                chunks.append(value)
    return chunks


def main() -> None:
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit(0)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    # File-based path uses EXEMPT whitelist. MCP path always scans.
    if file_path and is_exempt(file_path):
        sys.exit(0)

    chunks = extract_chunks(tool_name, tool_input)
    if not chunks:
        sys.exit(0)

    findings: list[tuple[str, str]] = []
    for content in chunks:
        findings.extend(scan_content(content))

    if findings:
        label_source = file_path.split("/")[-1] if file_path else tool_name
        print(f"[Hook] BLOCKED: secret bypass pattern in {label_source}", file=sys.stderr)
        for label, snippet in findings:
            print(f"  - {label}: {snippet}", file=sys.stderr)
        print(
            "\n.claude/rules/policy/security-guards.md §2 — secret 변경 자동화 영원히 회피.\n"
            "Place secrets in env-managed `.env.local` / `secrets/` (gitignored) and read via Edge Function.",
            file=sys.stderr,
        )

        # Schema v2 jsonl sink (matches 4 bash writers — security-violations-schema-v2.md)
        first_label = findings[0][0]
        reason = f"{first_label} in {label_source}"
        log_violation(reason)
        emit_deny(reason)

        sys.exit(0)

    # Pass through (empty stdout — Claude Code skips decision parse)
    sys.exit(0)


if __name__ == "__main__":
    main()
