#!/usr/bin/env python3
"""Fail CI when pull_request workflows mix PR code with privileged tokens."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
if not WORKFLOW_DIR.exists():
    WORKFLOW_DIR = ROOT / "github" / "workflows"

WRITE_PERMISSION_RE = re.compile(
    r"(?m)^\s*(contents|pull-requests|id-token|actions|checks|deployments|issues|packages|pages|statuses):\s*write\b"
)
def _trigger_re(name: str) -> re.Pattern[str]:
    return re.compile(
        rf"^\s*{name}\s*:"
        rf"|^on\s*:\s*{name}\s*$"
        rf"|^on\s*:\s*\[[^\]]*\b{name}\b[^\]]*\]",
        re.MULTILINE,
    )


PULL_REQUEST_RE = _trigger_re("pull_request")
PULL_REQUEST_TARGET_RE = _trigger_re("pull_request_target")
SENSITIVE_SECRET_RE = re.compile(r"secrets\.([A-Z0-9_]+)")
CHECKOUT_RE = re.compile(r"uses:\s*actions/checkout@", re.IGNORECASE)
OWNER_GATE_RE = re.compile(
    r"(github\.event\.pull_request\.author_association\s*==\s*'OWNER'|"
    r"github\.actor\s*==\s*github\.repository_owner)"
)
WRITE_ALL_RE = re.compile(r"(?m)^\s*permissions:\s*write-all\b")
SAFE_BASE_REF_RE = re.compile(
    r"ref:\s*\$\{\{\s*(github\.base_ref|github\.event\.pull_request\.base\.ref)\s*\}\}"
)
PERSIST_FALSE_RE = re.compile(r"persist-credentials:\s*false\b")
PR_CODE_EXEC_RE = re.compile(
    r"(?m)^\s*(?:run:\s*)?.*\b("
    r"npm\s+(ci|run)|"
    r"pnpm\s+(install|run)|"
    r"yarn\s+(install|run)|"
    r"bun\s+(install|run)|"
    r"npx\s+|"
    r"node\s+(\.|apps/|scripts/|[^\s]+\.c?m?js)|"
    r"python3?\s+(\.|apps/|scripts/|[^\s]+\.py)|"
    r"bash\s+(\.|apps/|scripts/|[^\s]+\.sh)|"
    r"sh\s+(\.|apps/|scripts/|[^\s]+\.sh)|"
    r"uv\s+sync|"
    r"pip\s+install|"
    r"git\s+push"
    r")\b"
)

PUBLIC_SECRET_PREFIXES = ("VITE_", "EXPO_PUBLIC_")
PUBLIC_SECRET_NAMES = {"GITHUB_TOKEN"}


def has_sensitive_secret(block: str) -> bool:
    for match in SENSITIVE_SECRET_RE.finditer(block):
        name = match.group(1)
        if name in PUBLIC_SECRET_NAMES:
            continue
        if name.startswith(PUBLIC_SECRET_PREFIXES):
            continue
        return True
    return False


def has_safe_base_checkout(block: str) -> bool:
    return (
        bool(CHECKOUT_RE.search(block))
        and bool(SAFE_BASE_REF_RE.search(block))
        and bool(PERSIST_FALSE_RE.search(block))
    )


def has_write_permission(block: str) -> bool:
    return bool(WRITE_ALL_RE.search(block) or WRITE_PERMISSION_RE.search(block))


def split_job_blocks(text: str) -> list[tuple[str, str]]:
    lines = text.splitlines(keepends=True)
    jobs_index = next(
        (index for index, line in enumerate(lines) if re.match(r"^jobs:\s*(?:#.*)?$", line)),
        None,
    )
    if jobs_index is None:
        return []

    blocks: list[tuple[str, str]] = []
    current_name: str | None = None
    current_lines: list[str] = []

    for line in lines[jobs_index + 1 :]:
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$", line)
        if match:
            if current_name is not None:
                blocks.append((current_name, "".join(current_lines)))
            current_name = match.group(1)
            current_lines = [line]
            continue
        if current_name is not None:
            current_lines.append(line)

    if current_name is not None:
        blocks.append((current_name, "".join(current_lines)))

    return blocks


def global_permissions_block(text: str) -> str:
    parts = text.split("\njobs:", 1)
    return parts[0]


def check_workflow(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT)
    errors: list[str] = []

    if PULL_REQUEST_TARGET_RE.search(text):
        errors.append(
            f"{rel}: pull_request_target requires explicit security review; use pull_request for code tests."
        )

    if not PULL_REQUEST_RE.search(text):
        return errors

    workflow_write = has_write_permission(global_permissions_block(text))

    for job_name, block in split_job_blocks(text):
        job_write = workflow_write or has_write_permission(block)
        checkout = bool(CHECKOUT_RE.search(block))
        safe_checkout = has_safe_base_checkout(block)
        executes_pr_code = bool(PR_CODE_EXEC_RE.search(block))
        sensitive_secret = has_sensitive_secret(block)
        owner_gate = bool(OWNER_GATE_RE.search(block))

        if job_write and checkout and not safe_checkout:
            errors.append(
                f"{rel} job '{job_name}': write permission with pull_request checkout. "
                "Use contents:read, or checkout github.base_ref with persist-credentials:false."
            )

        if sensitive_secret and executes_pr_code and checkout and not safe_checkout:
            errors.append(
                f"{rel} job '{job_name}': sensitive secret is available while executing PR-controlled code. "
                "Split into a read-only PR job and a privileged trusted-base job."
            )

        if sensitive_secret and not owner_gate and not safe_checkout:
            errors.append(
                f"{rel} job '{job_name}': sensitive secret is available to pull_request without an owner-only "
                "gate or trusted base checkout."
            )

    return errors


def main() -> int:
    errors: list[str] = []
    for path in sorted([*WORKFLOW_DIR.glob("*.yml"), *WORKFLOW_DIR.glob("*.yaml")]):
        errors.extend(check_workflow(path))

    if errors:
        print("GitHub Actions PR token safety check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("GitHub Actions PR token safety check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
