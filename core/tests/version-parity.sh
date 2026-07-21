#!/usr/bin/env bash
# version-parity.sh — the release-version drift gate.
#
# Usage:
#   bash core/tests/version-parity.sh          # gate this repo
#   bash core/tests/version-parity.sh <dir>    # gate an arbitrary tree (test seam)
#
# Exit 0: every declared version agrees. Exit 1: drift (prints each source).
#
# Why: the version ships from seven declarations in five files — README.md badge + status line, the
# README.ko.md mirror of both, .claude-plugin/plugin.json (what the plugin
# runtime reports), .claude-plugin/marketplace.json (what the marketplace
# offers), and the CHANGELOG's latest release heading. Before this gate they
# had drifted three ways (README + marketplace at 0.5.1, plugin.json +
# CHANGELOG at 0.5.3) with nothing failing. A missing file or unmatched
# pattern is a FAIL, not a skip — a guard that can silently skip is the
# false-green this repo bans.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-$REPO_ROOT}"

python3 - "$TARGET" <<'EOF'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
found = {}   # label -> version or None
problems = []

def grab(label, path, pattern):
    p = root / path
    if not p.is_file():
        problems.append(f"{label}: file missing ({path})")
        return
    m = re.search(pattern, p.read_text(encoding="utf-8"))
    if not m:
        problems.append(f"{label}: version pattern not found in {path}")
        return
    found[label] = m.group(1)

grab("README badge",    "README.md",    r"badge/version-(\d+\.\d+\.\d+)-blue")
grab("README status",   "README.md",    r"> Status: v(\d+\.\d+\.\d+)")
grab("README.ko badge", "README.ko.md", r"badge/version-(\d+\.\d+\.\d+)-blue")
grab("README.ko status","README.ko.md", r"> 상태: v(\d+\.\d+\.\d+)")

for label, path in [("plugin.json", ".claude-plugin/plugin.json"),
                    ("marketplace.json", ".claude-plugin/marketplace.json")]:
    p = root / path
    if not p.is_file():
        problems.append(f"{label}: file missing ({path})")
        continue
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        problems.append(f"{label}: unparseable ({e})")
        continue
    ver = data.get("version") or (data.get("metadata") or {}).get("version")
    if isinstance(ver, str) and re.fullmatch(r"\d+\.\d+\.\d+", ver):
        found[label] = ver
    else:
        problems.append(f"{label}: no semver 'version' field")

# CHANGELOG: first "## [x.y.z]" heading, skipping [Unreleased]
cl = root / "CHANGELOG.md"
if not cl.is_file():
    problems.append("CHANGELOG: file missing (CHANGELOG.md)")
else:
    m = re.search(r"(?m)^## \[(\d+\.\d+\.\d+)\]", cl.read_text(encoding="utf-8"))
    if m:
        found["CHANGELOG latest"] = m.group(1)
    else:
        problems.append("CHANGELOG: no '## [x.y.z]' release heading")

versions = set(found.values())
if problems or len(versions) != 1:
    print("FAIL — release version drift:")
    for label, v in sorted(found.items()):
        print(f"  {label}: {v}")
    for pr in problems:
        print(f"  {pr}")
    print("")
    print("Every declaration must carry the same x.y.z. Bump the laggards.")
    sys.exit(1)

print(f"PASS — all {len(found)} version declarations agree on {versions.pop()}")
EOF
