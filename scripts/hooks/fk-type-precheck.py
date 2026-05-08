#!/usr/bin/env python3
"""Hook wrapper: delegate to scripts/agents/fk_type_precheck.py (tracked).

Plan: ~/.claude/plans/vigilant-checking-osprey.md
This wrapper is gitignored (scripts/hooks/) and exists locally per user.
Core logic is at scripts/agents/fk_type_precheck.py (tracked, PR-merged).

Fail-safe: if the core script is not yet present (e.g., before PR merge), emit
allow so we do not block unrelated Write/Edit calls. The CI step provides the
strict enforcement gate; the local hook is a convenience layer.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
TARGET = os.path.join(ROOT, "scripts", "agents", "fk_type_precheck.py")
if not os.path.exists(TARGET):
    print(json.dumps({"decision": "allow"}))
    sys.exit(0)
os.execv(sys.executable, [sys.executable, TARGET, *sys.argv[1:]])
