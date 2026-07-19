#!/usr/bin/env bash
# rubric-commit-judge.sh — per-commit deterministic rubric scoring (advisory).
#
# PostToolUse Bash hook. On a `git commit`, if the project defines .agent/rubric.yml,
# runs core/infra/rubric-score.py and appends the verdict (shared scoring-convention
# schema) as one jsonl line to .agent/logs/rubric-score.jsonl.
#
# ADVISORY — like model-routing-observer.py: it never blocks, always exits 0, and
# emits nothing on stdout. A REFUTED verdict is RECORDED, not enforced (the commit
# already happened; this hook only observes). This is the DETERMINISTIC half of the
# two-layer rubric design — it runs cheaply per commit; the SEMANTIC half
# (skills/verify-completion) runs on-demand in a fresh context. The git-commit
# detection mirrors r4-file-mutex-register.sh.
#
# Best-effort: silent exit 0 on missing deps / no rubric / non-commit / non-repo cwd.
# Wire into: PostToolUse "Bash" (hooks.json) — after circuit-breaker.py.
set +e

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)"
[[ -z "$INPUT" ]] && exit 0
CMD="$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && exit 0
# Only fire after `git commit` patterns (excludes plumbing variants).
echo "$CMD" | grep -qE '\bgit\b[^|;&]*\bcommit(\s|$)' || exit 0

command -v git >/dev/null 2>&1 || exit 0
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[[ -z "$REPO_ROOT" ]] && exit 0

RUBRIC="$REPO_ROOT/.agent/rubric.yml"
[[ -f "$RUBRIC" ]] || exit 0   # no project rubric -> nothing to score (opt-in per project)

SCORER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" 2>/dev/null && pwd)/rubric-score.py"
[[ -f "$SCORER" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

LOG_DIR="$REPO_ROOT/.agent/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

# Advisory: capture the verdict, append one jsonl line; ignore the scorer's exit
# code so a REFUTED verdict never fails anything — this hook records, never gates.
VERDICT="$(python3 "$SCORER" --root "$REPO_ROOT" --rubric "$RUBRIC" 2>/dev/null)"
[[ -n "$VERDICT" ]] && printf '%s\n' "$VERDICT" >> "$LOG_DIR/rubric-score.jsonl"

exit 0
