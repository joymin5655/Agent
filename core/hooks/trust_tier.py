#!/usr/bin/env python3
"""trust_tier.py — per-project trust tier detection (personal | collab).

Shared module (same import pattern as hook_config.py): hooks that modulate
prompt friction call detect_tier(root) at decision time. v1 consumer:
plan-scope-allow.py (AGENT_PLAN_ALLOW_MODE unset -> tier decides).

Tiers map to the loop-engineering readiness ladder
(docs/concepts/loop-engineering.md): personal ~ L2/L3 (own project, earned
automation), collab ~ L0/L1 (external/shared project, report-first posture).
Hard safeguards (risk-area abort, mutex, gitleaks, test-failure abort) are
tier-INDEPENDENT — a tier only adjusts prompt friction, never safety gates.

Security invariants (docs/customization.md § Trust tiers):
- The only durable source that can GRANT "personal" is a USER-SIDE file
  outside any workspace: ~/.agent/trust.list (override: AGENT_TRUST_FILE —
  test seam). plan-scope-allow never auto-allows writes outside the
  workspace root, so an agent editing the trust list always faces the
  native permission prompt. The env-only-weakening principle is preserved
  by mechanism, not convention.
- A repo-side file (.agent/trust-tier) can only DOWNGRADE to "collab".
  Content "personal" is ignored — repo files must never escalate.
- Everything unknown fails CLOSED to "collab": no trust list, unparseable
  lines, git errors, exceptions.

trust.list line format (no YAML — stdlib only):
    # comment / blank lines ignored
    owner <github-owner>        # matches git remote origin owner, case-insensitive
    path <absolute-dir>         # matches workspace roots under this prefix (realpath)

A parseable remote owner decides alone: foreign owner -> collab even under a
trusted path (an external clone in a personal projects dir is still
collaboration). The path grant applies only to workspaces with no parseable
remote owner.

Accepted risk (documented): a Bash-capable agent can spoof `git remote add
origin` to a trusted owner. Bash is already a full-power surface guarded by
its own gates; the threat model here is durable repo-file self-weakening,
same accepted risk class as the /tmp/agent-plan-approved flag.

CLI (for tests and doctor checks):
    python3 core/hooks/trust_tier.py --detect [root]   # prints: personal|collab
"""

import os
import re
import subprocess
import sys

PERSONAL = "personal"
COLLAB = "collab"

# git remote URL -> owner. Covers https://host/OWNER/repo(.git),
# ssh://git@host/OWNER/repo(.git), git@host:OWNER/repo(.git).
_URL_OWNER_PATTERNS = [
    re.compile(r"^[a-z][a-z0-9+.-]*://[^/]+/([^/]+)/[^/]+?(?:\.git)?/?$", re.IGNORECASE),
    re.compile(r"^[^@\s]+@[^:\s]+:([^/]+)/[^/]+?(?:\.git)?/?$"),
]


def _trust_file():
    override = os.environ.get("AGENT_TRUST_FILE", "").strip()
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".agent", "trust.list")


def _load_trust_list():
    """Parse trust.list -> (owners_lowercase, realpath_prefixes). Missing or
    unreadable file -> empty (fail-closed)."""
    owners, paths = set(), []
    try:
        with open(_trust_file(), encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(None, 1)
                if len(parts) != 2:
                    continue  # unparseable line -> ignored, never trusted
                kind, value = parts[0].lower(), parts[1].strip()
                if kind == "owner" and value:
                    owners.add(value.lower())
                elif kind == "path" and os.path.isabs(value):
                    paths.append(os.path.realpath(value))
    except Exception:
        return set(), []
    return owners, paths


def _remote_owner(root):
    """Owner segment of git remote origin, lowercase — or None."""
    try:
        out = subprocess.run(
            ["git", "-C", root, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode != 0:
            return None
        url = out.stdout.strip()
        for pattern in _URL_OWNER_PATTERNS:
            m = pattern.match(url)
            if m:
                return m.group(1).lower()
    except Exception:
        pass
    return None


def _repo_downgrade(root):
    """True if the repo-side .agent/trust-tier file says collab.
    Any other content (including 'personal') is ignored — repo files can
    only downgrade, never escalate."""
    try:
        marker = os.path.join(root, ".agent", "trust-tier")
        with open(marker, encoding="utf-8") as f:
            return f.read().strip().lower() == COLLAB
    except Exception:
        return False


def detect_tier(root):
    """Resolve the trust tier for a workspace root. Fail-closed to collab."""
    try:
        if not root or not os.path.isdir(root):
            return COLLAB
        if _repo_downgrade(root):
            return COLLAB
        owners, paths = _load_trust_list()
        if not owners and not paths:
            return COLLAB
        owner = _remote_owner(root)
        if owner:
            # A parseable remote owner is the strongest signal and decides
            # alone: a foreign-owned clone sitting inside a trusted path
            # prefix is still collaboration, so it must NOT fall through to
            # the path grant below.
            return PERSONAL if owner in owners else COLLAB
        real_root = os.path.realpath(root)
        for prefix in paths:
            try:
                if os.path.commonpath([real_root, prefix]) == prefix:
                    return PERSONAL
            except ValueError:
                continue
        return COLLAB
    except Exception:
        return COLLAB


def main(argv):
    if len(argv) >= 2 and argv[1] == "--detect":
        root = argv[2] if len(argv) >= 3 else os.getcwd()
        print(detect_tier(root))
        return 0
    print(__doc__.strip().splitlines()[0])
    print("usage: trust_tier.py --detect [root]")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
