#!/usr/bin/env python3
"""
PreToolUse hook: detect secret bypass patterns in Write/Edit/MultiEdit and MCP tool content.

This is Layer 3 of the framework's secret defense (see rules/security-guards.md).
It catches bypass paths that pre-tool-guard.sh (Layer 3 Bash) cannot see:
  - Python `open()` reading from secrets/ or .env*
  - Node `fs.readFileSync()` reading from secrets/ or .env*
  - Hardcoded credential value assignments
  - OpenAI / Stripe `sk-...` token literals
  - JWT token literals
  - MCP tool calls with secrets in nested URL/query/content fields

Hook protocol:
  - Reads canonical event JSON from stdin (see docs/hook-protocol.md)
  - Writes decision JSON to stdout (deny) OR empty stdout (allow)
  - Exits 0 (decision in stdout) on match, or 0 (silent allow) on pass-through

The 7 patterns below are generic and apply to all projects. To add project-specific
secret token formats, extend via `hook-config.yml`:

  secret_patterns:
    - id: my-service-token
      regex: 'myservice_(live|test)_[a-zA-Z0-9_-]{32,}'

The hardcoded credential KEY name list (line ~70) covers a starter set of well-known
credential variable names. Project-specific variable names are detected by the
hook-config.yml addition above.
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
    "/__tests__/",
    "/tests/",
    "/test/",
    ".test.",
    ".spec.",
    ".fixture.",
    # Self + sibling test scripts (cite same patterns)
    "secret-content-scan.py",
    "secret-content-scan-test.sh",
    # Hooks that cite the same patterns in documentation/comments
    "/core/hooks/pre-tool-guard.sh",
    "/core/hooks/check-hardcoding.py",
    "/core/hooks/_archive/",
    # Policy + skill docs (cite variable names, no values)
    "/rules/",
    "/skills/",
    "/docs/",
    # Plan files (~/.claude/plans/)
    "/plans/",
    # CI definition
    ".github/workflows/secret-scan.yml",
    # Legacy archive (never scan content of preserved prior-project files)
    "/legacy/",
]

# Generic secret bypass patterns (7 default). Project-specific patterns can be
# added through hook-config.yml: secret_patterns[].
SECRET_PATTERNS = [
    # Python open() into secrets/ dir
    (
        r"""\bopen\s*\(\s*['"][^'"]*?secrets/""",
        "Python file open from secrets/",
    ),
    # Python open() into .env* (excluding .env.example)
    (
        r"""\bopen\s*\(\s*['"][^'"]*?\.env(?!\.example)""",
        "Python file open from .env*",
    ),
    # Node fs.readFileSync / fs.readSync into secrets/
    (
        r"""\bfs\.(?:promises\.)?read(?:File)?Sync\s*\(\s*['"][^'"]*?secrets/""",
        "Node fs read from secrets/",
    ),
    # Node fs.readFileSync into .env* (excluding .env.example)
    (
        r"""\bfs\.(?:promises\.)?read(?:File)?Sync\s*\(\s*['"][^'"]*?\.env(?!\.example)""",
        "Node fs read from .env*",
    ),
    # Hardcoded credential value: KNOWN_KEY = "..." (20+ chars). Starter list of
    # well-known cloud / SaaS credential names. Extend via hook-config.yml.
    (
        r"""\b(?:AWS_SECRET_ACCESS_KEY|AWS_SECRET_KEY|AWS_ACCESS_KEY_ID|GCP_SERVICE_ACCOUNT_KEY|AZURE_CLIENT_SECRET|CLOUDFLARE_API_TOKEN|ANTHROPIC_API_KEY|OPENAI_API_KEY|STRIPE_SECRET_KEY|STRIPE_RESTRICTED_KEY|GITHUB_TOKEN|GITHUB_PAT|SLACK_TOKEN|SLACK_BOT_TOKEN|DATABASE_URL|DATABASE_PASSWORD|JWT_SECRET|SESSION_SECRET|PRIVATE_KEY|SUPABASE_SERVICE_ROLE_KEY|SUPABASE_JWT_SECRET)\s*[:=]\s*['"][A-Za-z0-9_\-\.]{20,}['"]""",
        "hardcoded credential value",
    ),
    # OpenAI / Stripe API key pattern — word-boundary (no quote required, catches URL/MCP)
    (
        r"""\bsk-[A-Za-z0-9_\-]{40,}\b""",
        "API key literal (sk-...)",
    ),
    # JWT token (3 dot-separated base64url segments) — word-boundary
    (
        r"""\beyJ[A-Za-z0-9_\-]{20,}\.eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b""",
        "JWT token literal",
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
    """Append security violation record to .agent/logs/security-violations.jsonl.

    Matches the schema written by other guard hooks. Silent on failure —
    we never want telemetry issues to crash an AI session.
    """
    repo_root = os.environ.get("AGENT_PROJECT_DIR") or os.environ.get("CLAUDE_PROJECT_DIR")
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

    log_dir = Path(repo_root) / ".agent" / "logs"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        return

    repro_env = os.environ.get("AGENT_REPRODUCE_TEST", "")
    reproduce_test = repro_env in ("1", "true", "TRUE", "True")

    record = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "guard": "secrets",
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

    # Optional broadcast — work-feed visibility for multi-session coordination
    try:
        broadcast = Path(repo_root) / "core" / "infra" / "agent-session.sh"
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
    """Recursively collect all string values from nested dict/list."""
    if isinstance(obj, str):
        return [obj]
    if isinstance(obj, dict):
        return [s for v in obj.values() for s in walk_strings(v)]
    if isinstance(obj, list):
        return [s for v in obj for s in walk_strings(v)]
    return []


# MCP write/external-tool prefixes whose input may carry secrets nested in URLs
# or content fields. Each adapter that connects new MCP servers should review
# this list and add prefixes covering URL/content payloads.
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
    elif tool_name.startswith("mcp__supabase__") or tool_name.startswith("mcp__postgres__"):
        # Database MCP servers: execute_sql / apply_migration / deploy_*
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
        # Crawler / search / cloud-storage MCP — recursive walk to catch nested URLs
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

    # File-based path uses EXEMPT whitelist. MCP / WebFetch paths always scan.
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
            "\nSee rules/security-guards.md (Risk Area: secrets).\n"
            "Place credentials in env-managed `.env.local` or `secrets/` (gitignored) and read via secure server-side code.",
            file=sys.stderr,
        )

        first_label = findings[0][0]
        reason = f"{first_label} in {label_source}"
        log_violation(reason)
        emit_deny(reason)

        sys.exit(0)

    # Pass through (empty stdout — `allow` per docs/hook-protocol.md § 3)
    sys.exit(0)


if __name__ == "__main__":
    main()
