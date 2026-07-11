#!/usr/bin/env python3
"""Scan git remote URL(s) for embedded credentials (W-3).

gitleaks and the content scanners inspect *file* content; a token baked into a
remote URL lives in `.git/config`, never in a tracked file, so it slips every
content-based layer yet authenticates every push in plaintext. This closes that
blind spot: it flags an http(s) remote whose userinfo carries a password
(`user:token@host`) or a token-shaped single userinfo (`ghp_…@host`).

Deliberately NOT flagged (no false positives):
  - ssh URLs (`git@github.com:owner/repo.git`) — `git@` is a username, the colon
    is the ssh path separator, and there is no secret;
  - `ssh://git@host/…`, `git://…` — no userinfo password;
  - a bare non-token username with no password (`https://alice@host/…`) — a
    username alone is not a credential.

Usage:
  scan-remote-url.py <url> [<url> ...]     # URLs as args
  git remote -v | scan-remote-url.py        # or one URL per line on stdin
Exit 0: no embedded credential. Exit 1: at least one URL embeds a credential
(each offending URL printed to stderr, with the secret redacted).
"""
import re
import sys
from urllib.parse import urlsplit

# Known VCS/token prefixes — a userinfo that IS one of these (even without a
# password colon) is a credential, e.g. `https://ghp_xxx@github.com/...`.
TOKEN_PREFIXES = (
    "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
    "glpat-", "xoxb-", "xoxp-", "sk-", "pk-", "AKIA", "ASIA",
)


def redact(url: str) -> str:
    """Replace any userinfo with '***' so we never echo the secret back."""
    return re.sub(r"(://)[^/@]+@", r"\1***@", url)


def embeds_credential(url: str) -> bool:
    url = url.strip()
    if not url:
        return False
    # Only http(s) userinfo carries a plaintext push credential. ssh/git schemes
    # and scp-style `git@host:path` use key auth, not an embedded secret.
    try:
        parts = urlsplit(url)
    except Exception:
        return False
    if parts.scheme not in ("http", "https"):
        return False
    userinfo = ""
    netloc = parts.netloc
    if "@" in netloc:
        userinfo = netloc.rsplit("@", 1)[0]
    if not userinfo:
        return False
    # A password component (`user:secret`) is always a credential.
    if ":" in userinfo:
        return True
    # A single userinfo with no password: credential only if it looks like a
    # token (a plain username like `alice` is not a secret).
    return any(userinfo.startswith(p) for p in TOKEN_PREFIXES)


def main() -> None:
    if len(sys.argv) > 1:
        urls = sys.argv[1:]
    else:
        urls = [ln for ln in sys.stdin.read().splitlines() if ln.strip()]
    # `git remote -v` lines look like: "origin\thttps://...@host (push)" — pull
    # the URL token out of each line if present.
    offenders = []
    for raw in urls:
        candidate = raw
        m = re.search(r"(https?://\S+)", raw)
        if m:
            candidate = m.group(1)
        if embeds_credential(candidate):
            offenders.append(candidate)
    if offenders:
        print("BLOCKED: git remote URL embeds a credential (W-3):", file=sys.stderr)
        for u in offenders:
            print("  - " + redact(u), file=sys.stderr)
        print(
            "\nWHY: a token in a remote URL sits in .git/config in plaintext and "
            "authenticates every push — invisible to content secret-scanners.\n"
            "FIX: strip it — `git remote set-url <remote> https://host/owner/repo.git` "
            "— and store the token in a credential helper (git config credential.helper).",
            file=sys.stderr,
        )
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
