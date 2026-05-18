#!/usr/bin/env python3
"""Pre-push diff content scanner — Layer 6 of secret defense.

Reads added lines from `git diff <range>` (passed via stdin, lines already
filtered to start with `+` and stripped of the leading `+`).
Mirrors SECRET_PATTERNS from core/hooks/secret-content-scan.py to catch
bypass attempts in commits being pushed.

Exit 0 = clean. Exit 1 = secret pattern matched (push blocked, hook returns exit 15).

Override pattern set via env var:
  AGENT_SECRET_KEYWORDS="SECRET_KEY,API_TOKEN,..."  (comma-separated, OR-joined)
"""
import os
import re
import sys

DEFAULT_KEYWORDS = [
    "SERVICE_ROLE_KEY",
    "API_TOKEN",
    "API_KEY",
    "STRIPE_SECRET_KEY",
    "POLAR_API_KEY",
    "RC_SECRET_KEY",
    "PRIVATE_KEY",
    "CLIENT_SECRET",
]

if os.environ.get("AGENT_SECRET_KEYWORDS"):
    KEYWORDS = [
        k.strip() for k in os.environ["AGENT_SECRET_KEYWORDS"].split(",") if k.strip()
    ]
else:
    KEYWORDS = DEFAULT_KEYWORDS

KEYWORD_RE = "|".join(re.escape(k) for k in KEYWORDS)

SECRET_PATTERNS = [
    (
        r"""\bopen\s*\(\s*['"][^'"]*?secrets/""",
        "Python open() reading from secrets/",
    ),
    (
        r"""\bopen\s*\(\s*['"][^'"]*?\.env(?!\.example)""",
        "Python open() reading from .env*",
    ),
    (
        r"""\bfs\.(?:promises\.)?read(?:File)?Sync\s*\(\s*['"][^'"]*?secrets/""",
        "Node fs.readFileSync() reading from secrets/",
    ),
    (
        r"""\bfs\.(?:promises\.)?read(?:File)?Sync\s*\(\s*['"][^'"]*?\.env(?!\.example)""",
        "Node fs.readFileSync() reading from .env*",
    ),
    (
        rf"""\b(?:{KEYWORD_RE})\s*[:=]\s*['"][A-Za-z0-9_\-\.]{{20,}}['"]""",
        "hardcoded secret key value",
    ),
    (
        r"""\bsk-[A-Za-z0-9_\-]{40,}\b""",
        "OpenAI/Stripe API key (sk-...)",
    ),
    (
        r"""\beyJ[A-Za-z0-9_\-]{20,}\.eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b""",
        "JWT token (eyJ...)",
    ),
]


def main() -> int:
    try:
        diff_content = sys.stdin.read()
    except Exception:
        return 0  # silent fail — CI Layer 2 backs up

    if not diff_content.strip():
        return 0

    findings: list[tuple[str, str]] = []
    for pattern, label in SECRET_PATTERNS:
        match = re.search(pattern, diff_content)
        if match:
            snippet = match.group(0)
            if len(snippet) > 80:
                snippet = snippet[:77] + "..."
            findings.append((label, snippet))

    if findings:
        sys.stderr.write("scan-push-diff: secret patterns detected in push range:\n")
        for label, snippet in findings:
            sys.stderr.write(f"  - {label}: {snippet}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
