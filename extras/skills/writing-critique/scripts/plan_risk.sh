#!/usr/bin/env bash
# plan_risk.sh — does a plan or design document cite risk-area paths?
#
# usage: plan_risk.sh <doc> [--repo <dir>]
# Takes the path-like candidates from gather_sources.py --candidates, feeds them NUL-separated
# to the harness's core/infra/council-threshold.sh --classify (cwd = the repository, so the
# project's declared secret paths apply) and prints the risky paths, one per line.
# exit: 0 at least one risk-area path (auth, secrets, billing, production migration, edge
#       functions) | 1 none | 2 usage or setup error
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="" REPO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a folder}"; shift 2 ;;
        -h|--help) sed -n 2,9p "$0"; exit 0 ;;
        -*) echo "plan_risk: unknown option $1" >&2; exit 2 ;;
        *) if [[ -n "$DOC" ]]; then echo "plan_risk: one document only" >&2; exit 2; fi; DOC="$1"; shift ;;
    esac
done
[[ -f "$DOC" ]] || { echo "usage: plan_risk.sh <doc> [--repo <dir>]" >&2; exit 2; }
if [[ -z "$REPO" ]]; then
    REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO="$PWD"
fi
[[ -d "$REPO" ]] || { echo "plan_risk: no such folder: $REPO" >&2; exit 2; }
DOC="$(cd "$(dirname "$DOC")" && pwd)/$(basename "$DOC")"

ROOT="$(bash "$SKILL_DIR/../../scripts/harness-root.sh")" || exit 2
CT="$ROOT/core/infra/council-threshold.sh"
[[ -f "$CT" ]] || { echo "plan_risk: council-threshold.sh not found at $CT" >&2; exit 2; }

risky="$(python3 "$SKILL_DIR/scripts/gather_sources.py" --candidates -z "$DOC" \
    | (cd "$REPO" && bash "$CT" --classify | tr '\0' '\n'))" || exit 2
if [[ -n "$risky" ]]; then
    printf '%s\n' "$risky"
    exit 0
fi
exit 1
