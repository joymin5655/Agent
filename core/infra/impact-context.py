#!/usr/bin/env python3
"""impact-context.py — blast-radius context for a diff, from CodeGraph.

Reviewers see the diff and nothing else, so a change that breaks a caller
OUTSIDE the diff is invisible to them. This script lists, for each changed
source file, the files that depend on it but are not part of the diff, and the
test files CodeGraph says the change reaches. /council-review appends the output
to its shared review core. /wrap shows it as an advisory "tests worth running"
hint. (Idea borrowed from Graft's `graft blast`, built on the CodeGraph index
this machine already maintains, with no new indexer.)

usage: impact-context.py [--staged|--head|<range>]
  Same target shape as review-tier.sh / council-threshold.sh. --staged (the
  default) falls back to HEAD~1..HEAD when nothing is staged. A <range> is
  passed after --end-of-options so it can never be read as a git option.

stdout: a markdown block, or NOTHING when there is nothing worth saying (no
        .codegraph/ index, codegraph not installed, empty diff, no dependents
        outside the diff and no affected tests).
exit:   always 0. This is advisory context, never a gate (fail-open).

env:
  IMPACT_CONTEXT_BUDGET_S   total wall-clock budget, default 10
  IMPACT_CONTEXT_MAX_LINES  output line cap, default 60
  IMPACT_CONTEXT_MAX_FILES  changed files examined, default 20
  CODEGRAPH_BIN             codegraph executable, default "codegraph" (tests)
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import time

SOURCE_EXT = {
    ".py", ".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".go", ".rs", ".java",
    ".kt", ".swift", ".rb", ".php", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs",
    ".sh", ".vue", ".svelte",
}
USED_BY = re.compile(r"used by (\d+) files?: (.+)$")
# A real path token: no spaces, not a warning glyph or an "… and N more" tail.
PATHISH = re.compile(r"^[\w./@+-][^\s]*$")


def env_int(name, default):
    try:
        return max(1, int(os.environ.get(name, default)))
    except ValueError:
        return default


def run(cmd, cwd, deadline):
    """Run cmd bounded by the remaining budget; '' on any failure."""
    left = deadline - time.monotonic()
    if left <= 0.2:
        return ""
    try:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    except OSError:
        return ""
    try:
        out, _ = p.communicate(timeout=left)
    except subprocess.TimeoutExpired:
        # Kill the whole group: codegraph (or a test stub) may have children
        # that would otherwise outlive this advisory script.
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return ""
    return out if p.returncode == 0 else ""


def changed_files(root, target, deadline):
    """[(path, deleted?)]. Renames are split into delete + add (--no-renames) so
    the old path's callers are still examined; quotePath=false keeps non-ASCII
    paths readable."""
    base = ["git", "-c", "core.quotePath=false", "diff", "--name-status", "--no-renames"]
    fallback = False
    if target == "--staged":
        out = run(base + ["--staged"], root, deadline)
        if not out.strip():
            out = run(base + ["HEAD~1..HEAD"], root, deadline)
            fallback = True
    elif target == "--head":
        out = run(base + ["HEAD~1..HEAD"], root, deadline)
    else:
        out = run(base + ["--end-of-options", target], root, deadline)
    files = []
    for line in out.splitlines():
        status, _, path = line.partition("\t")
        if path.strip():
            files.append((path.strip(), status.startswith("D")))
    return files, fallback


def index_root(root, deadline):
    """Directory holding .codegraph/ for this checkout. .codegraph/ is gitignored,
    so a linked worktree (.worktrees/<tool>-<topic>) has none of its own; fall
    back to the main worktree's index. Paths are repo-relative in both, and the
    main index may lag this branch, which is acceptable for advisory context."""
    if os.path.isdir(os.path.join(root, ".codegraph")):
        return root
    common = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                 root, deadline).strip()
    main = os.path.dirname(common) if common else ""
    if main and os.path.isdir(os.path.join(main, ".codegraph")):
        return main
    return ""


def main(argv):
    target = argv[1] if len(argv) > 1 else "--staged"
    budget = env_int("IMPACT_CONTEXT_BUDGET_S", 10)
    max_lines = env_int("IMPACT_CONTEXT_MAX_LINES", 60)
    max_files = env_int("IMPACT_CONTEXT_MAX_FILES", 20)
    cg = os.environ.get("CODEGRAPH_BIN", "codegraph")
    deadline = time.monotonic() + budget

    if not shutil.which(cg):
        return 0
    root = run(["git", "rev-parse", "--show-toplevel"], os.getcwd(), deadline).strip()
    idx = index_root(root, deadline) if root else ""
    if not idx:
        return 0

    changed, fallback = changed_files(root, target, deadline)
    changed_set = {f for f, _ in changed}
    deleted = {f for f, gone in changed if gone}
    sources = [f for f, _ in changed if os.path.splitext(f)[1].lower() in SOURCE_EXT]
    if not sources:
        return 0
    skipped = max(0, len(sources) - max_files)
    sources = sources[:max_files]

    dependents = []  # (file, [outside dependents])
    for f in sources:
        out = run([cg, "node", "-f", f, "--symbols-only", "-p", idx], root, deadline)
        # Scan the header lines, not just line 1: codegraph prefixes a warning
        # line when the index belongs to another worktree (see index_root).
        hits = (USED_BY.search(ln.replace("**", "")) for ln in out.splitlines()[:5])
        m = next((h for h in hits if h), None)
        if not m:
            continue
        users = [u.strip() for u in m.group(2).split(",")
                 if u.strip() and PATHISH.match(u.strip())]
        outside = [u for u in users if u not in changed_set]
        # the header's N can exceed the names it lists; count the rest as "+more"
        unlisted = max(0, int(m.group(1)) - len(users))
        if outside:
            dependents.append((f, outside, unlisted))

    live = [f for f in sources if f not in deleted]
    tests_out = run([cg, "affected", "-q", "-p", idx] + live, root, deadline) if live else ""
    tests = [t.strip() for t in tests_out.splitlines()
             if PATHISH.match(t.strip()) and t.strip() not in changed_set]

    if not dependents and not tests:
        return 0

    lines = ["## Impact context (codegraph)", ""]
    if fallback:
        lines += ["(nothing staged — showing HEAD~1..HEAD, the last commit)", ""]
    if dependents:
        lines.append("Files that depend on changed code but are NOT in this diff "
                     "(check these callers still hold):")
        for f, outside, unlisted in dependents:
            shown = ", ".join(outside[:5])
            extra = max(0, len(outside) - 5) + unlisted
            more = f" (+{extra})" if extra else ""
            gone = " (deleted/renamed in this diff)" if f in deleted else ""
            lines.append(f"- `{f}`{gone} → used by {shown}{more}")
        lines.append("")
    if tests:
        lines.append("Test files the change reaches (not edited in this diff):")
        lines.extend(f"- `{t}`" for t in tests)
        lines.append("")
    if skipped:
        lines.append(f"({skipped} more changed source files not examined)")
    if time.monotonic() >= deadline:
        lines.append(f"(budget {budget}s exhausted; results may be partial)")

    if len(lines) > max_lines:
        lines = lines[:max_lines - 1] + [f"… (truncated at {max_lines} lines)"]
    print("\n".join(lines).rstrip())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:  # noqa: BLE001 — advisory context must never break /wrap or /council
        sys.exit(0)
