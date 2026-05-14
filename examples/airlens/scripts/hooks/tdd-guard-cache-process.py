#!/usr/bin/env python3
"""
tdd-guard cache processor (Phase 1.1).

Reads vitest --reporter=json output from stdin, transforms to schema v1,
atomic-writes to .claude/state/vitest-last-run.json.

Invoked by tdd-guard-refresh.sh after a vitest run.
Silent on parse failure — prior cache preserved.
Plan: ~/.claude/plans/tdd-guard-self-strengthen-frosted-mason.md §1.1
"""
import sys
import json
import os
import tempfile
import subprocess
from datetime import datetime, timezone

SCHEMA_VERSION = 1
SCOPE = "apps/web"
SIZE_CAP_BYTES = 256 * 1024


def repo_root():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return os.getcwd()


def to_relative(path, root):
    if path.startswith(root + os.sep):
        return path[len(root) + 1:]
    return path


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        sys.exit(0)
    try:
        data = json.loads(raw)
    except Exception:
        sys.exit(0)

    root = repo_root()
    test_results_in = data.get("testResults", []) or []
    cleaned = []
    failed_files = []

    for tr in test_results_in:
        name = tr.get("name") or tr.get("file") or ""
        rel = to_relative(name, root)
        status = tr.get("status", "unknown")
        cleaned_assertions = []
        for ar in tr.get("assertionResults", []) or []:
            full_name = ar.get("fullName") or ar.get("title") or ""
            ar_status = ar.get("status", "unknown")
            fmsg = ar.get("failureMessages") or []
            failure_message = ""
            if fmsg and isinstance(fmsg, list):
                failure_message = (fmsg[0] or "")[:80]
            cleaned_assertions.append({
                "fullName": full_name,
                "status": ar_status,
                "failureMessage": failure_message,
            })
        cleaned.append({
            "file": rel,
            "status": status,
            "assertionResults": cleaned_assertions,
        })
        if status == "failed":
            failed_files.append(rel)

    out = {
        "version": SCHEMA_VERSION,
        "ts": datetime.now(timezone.utc).isoformat(),
        "scope": SCOPE,
        "testResults": cleaned,
        "failedFiles": failed_files,
    }

    serialized = json.dumps(out)
    if len(serialized) > SIZE_CAP_BYTES:
        for tr in out["testResults"]:
            if tr["status"] != "failed":
                tr["assertionResults"] = []
        serialized = json.dumps(out)

    target = os.path.join(root, ".claude/state/vitest-last-run.json")
    target_dir = os.path.dirname(target)
    try:
        os.makedirs(target_dir, exist_ok=True)
    except Exception:
        sys.exit(0)

    fd, tmp_path = tempfile.mkstemp(dir=target_dir, prefix=".vitest-cache-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(serialized)
        os.replace(tmp_path, target)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
