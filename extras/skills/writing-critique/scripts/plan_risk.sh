#!/usr/bin/env bash
# plan_risk.sh — does a plan or design document cite risk-area paths?
#
# usage: plan_risk.sh <doc>... [--repo <dir>]
# Takes the path-like candidates of every document from gather_sources.py --candidates --all
# (inline, links and bare paths, fenced blocks included), feeds them NUL-separated to the
# harness's core/infra/council-threshold.sh --classify (AGENT_PROJECT_DIR = the repository, so
# that project's declared secret paths apply; cwd = an empty temporary folder, never the
# repository) and prints each risky path once, one per line.
# exit: 0 at least one risk-area path (auth, secrets, billing, production migration, edge
#       functions) | 1 none | 2 usage or setup error (also: the project's declared secret paths
#       cannot be read, e.g. PyYAML missing — never reported as "no risk")
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS=() REPO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a folder}"; shift 2 ;;
        -h|--help) sed -n 2,13p "$0"; exit 0 ;;
        -*) echo "plan_risk: unknown option $1" >&2; exit 2 ;;
        *) DOCS+=("$1"); shift ;;
    esac
done
[[ ${#DOCS[@]} -gt 0 ]] || { echo "usage: plan_risk.sh <doc>... [--repo <dir>]" >&2; exit 2; }
for DOC in "${DOCS[@]}"; do
    [[ -f "$DOC" ]] || { echo "usage: plan_risk.sh <doc>... [--repo <dir>] (not a file: $DOC)" >&2; exit 2; }
done
if [[ -z "$REPO" ]]; then
    REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO="$PWD"
fi
[[ -d "$REPO" ]] || { echo "plan_risk: no such folder: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"

ROOT="$(bash "$SKILL_DIR/../../scripts/harness-root.sh")" || exit 2
CT="$ROOT/core/infra/council-threshold.sh"
[[ -f "$CT" ]] || { echo "plan_risk: council-threshold.sh not found at $CT" >&2; exit 2; }

# `python3 -` (below and inside the classifier) imports from its working folder first, so a
# module planted in the reviewed repository (json.py, fnmatch.py, ...) would run: both run in
# this empty, process-owned folder instead. AGENT_PROJECT_DIR names the repository.
NEUTRAL="$(mktemp -d)" || exit 2
trap 'rm -rf "$NEUTRAL"' EXIT

# the project's declared secret paths must be readable, else the classifier would silently drop them
(cd "$NEUTRAL" && python3 - "$SKILL_DIR/scripts" "$ROOT" "$REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import gather_sources
sys.exit(0 if gather_sources.project_secret_tokens(sys.argv[2], sys.argv[3]) is not None else 2)
PY
) || exit 2

risky=""
for DOC in "${DOCS[@]}"; do
    ABS="$(cd "$(dirname "$DOC")" && pwd)/$(basename "$DOC")"
    part="$(python3 "$SKILL_DIR/scripts/gather_sources.py" --candidates --all -z "$ABS" \
        | (cd "$NEUTRAL" && AGENT_PROJECT_DIR="$REPO" bash "$CT" --classify | tr '\0' '\n'))" || exit 2
    if [[ -n "$part" ]]; then risky="$risky$part"$'\n'; fi
done
if [[ -n "$risky" ]]; then
    printf '%s' "$risky" | awk 'NF && !seen[$0]++'
    exit 0
fi
exit 1
