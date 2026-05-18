#!/usr/bin/env python3
"""EXEMPT-aware secret pattern scanner for auto-ship.sh §secrets check.

Reads `gh pr diff <PR>` unified-diff output on stdin.
Exits 0 = clean. Exits 1 = secret pattern hit in a non-EXEMPT file.

EXEMPT paths (policy docs / pattern source / test fixtures — where the
keyword is being *cited*, not *leaked*):
  - rules/, policy/                    (policy docs that cite keywords)
  - core/infra/auto-ship.sh            (this caller)
  - core/infra/auto-ship-guard-scan.py (self)
  - core/git-hooks/scan-push-diff.py   (pattern source)
  - core/hooks/secret-content-scan.py  (pattern source)
  - core/git-hooks/tests/, core/hooks/tests/, core/infra/tests/
  - wiki/, docs/                       (project docs)
  - .env.example, gitleaks.toml
  - *.test.*, *.spec.*, *.fixture.*, __tests__/, /tests/, /test/

Override EXEMPT list via env var:
  AGENT_EXEMPT_PATTERNS="path1,path2,path3,..."  (comma-separated substring patterns)

Override secret regex via env var:
  AGENT_SECRETS_REGEX="<regex>"  (replaces the default below)

Default secret regex catches generic public-key-style tokens (KEY=,
SERVICE_ROLE_KEY, API_TOKEN, STRIPE_SECRET, sk-..., JWT eyJ...).
"""
import os
import re
import sys

DEFAULT_EXEMPT = [
    "rules/",
    "policy/",
    "core/infra/auto-ship.sh",
    "core/infra/auto-ship-guard-scan.py",
    "core/git-hooks/scan-push-diff.py",
    "core/hooks/secret-content-scan.py",
    "core/git-hooks/tests/",
    "core/hooks/tests/",
    "core/infra/tests/",
    "wiki/",
    "docs/",
    ".env.example",
    "gitleaks.toml",
    ".test.",
    ".spec.",
    ".fixture.",
    "/__tests__/",
    "/tests/",
    "/test/",
]

if os.environ.get("AGENT_EXEMPT_PATTERNS"):
    EXEMPT_PATTERNS = [
        p.strip() for p in os.environ["AGENT_EXEMPT_PATTERNS"].split(",") if p.strip()
    ]
else:
    EXEMPT_PATTERNS = DEFAULT_EXEMPT

DEFAULT_SECRETS_REGEX = (
    r"(SERVICE_ROLE_KEY|API_TOKEN|API_KEY|STRIPE_SECRET|"
    r"sk-[a-zA-Z0-9]{20,}|eyJ[a-zA-Z0-9]{30,})"
)
SECRETS_REGEX = os.environ.get("AGENT_SECRETS_REGEX", DEFAULT_SECRETS_REGEX)

SECRET_RE = re.compile(SECRETS_REGEX, re.IGNORECASE)
FILE_HEADER_RE = re.compile(r"^diff --git a/(\S+) b/(\S+)")


def is_exempt(path: str) -> bool:
    return any(pat in path for pat in EXEMPT_PATTERNS)


def main() -> int:
    current_path = ""
    skip_chunk = False
    hits: list[tuple[str, str]] = []

    for line in sys.stdin:
        m = FILE_HEADER_RE.match(line)
        if m:
            current_path = m.group(2)
            skip_chunk = is_exempt(current_path)
            continue

        if skip_chunk:
            continue

        if line.startswith("+") and not line.startswith("+++"):
            match = SECRET_RE.search(line)
            if match:
                snippet = line.rstrip("\n")
                if len(snippet) > 200:
                    snippet = snippet[:197] + "..."
                hits.append((current_path, snippet))

    if hits:
        sys.stderr.write(
            f"BLOCK: risk-area 'secrets' violated — {len(hits)} hit in non-EXEMPT file(s):\n"
        )
        for path, snippet in hits[:5]:
            sys.stderr.write(f"  {path}: {snippet}\n")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
