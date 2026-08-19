#!/usr/bin/env bash
# antigravity-worker.sh — stdin->argv bridge for the Antigravity `agy` CLI, the
# council's google review lane after the gemini CLI's OAuth was retired.
#
# call-worker.sh streams the prompt on STDIN, but `agy` takes its single-turn
# prompt as the POSITIONAL argument to -p, and (measured 2026-08-19, agy 1.1.14)
# flags placed AFTER the prompt are misparsed — so this bridge composes
# `agy <flags> -p "<prompt read from stdin>"`, keeping the registry's uniform
# "cmd + tier_args, prompt on stdin" contract.
#
# AUTH: agy authenticates from the OS keyring, seeded once interactively (this
# machine's was already seeded — see adapters/antigravity/README.md). The worker
# never logs in; a dead credential is the preflight's problem (fail closed).
#
# THREAT MODEL: the prompt carries an untrusted diff (an outside-contributor PR
# is the lane's normal input), so a prompt can try to drive local action.
# Measured posture (probes in .agent/plans/antigravity-lane/probes/):
#   * default headless mode DENIES shell exec ("user denied permission to run
#     command") and created NO file in any probe — it fails closed;
#   * BUT the file-write tool was not observed to be explicitly denied (only the
#     shell denial surfaced), so the write path is "no file produced", not
#     "provably gated".
# A code review needs neither write nor exec (it reads the diff from the prompt
# and emits findings text), so this worker (a) FORBIDS
# --dangerously-skip-permissions, and (b) — belt-and-suspenders, matching the
# grok lane — runs under an OS sandbox-exec deny-write/deny-cred-read profile so
# the unproven write path cannot matter. sandbox-exec is fail-closed: no
# sandbox-exec => refuse (unless GROK-style opt-out).
#
# Tier policy: model IDs are forbidden in core/infra/backends.json
# (no-model-ids gate), so the model pin lives in a tiers file THIS adapter owns:
# $ANTIGRAVITY_TIERS_FILE > ~/.gemini/antigravity-cli/agent-tiers.json > the
# shipped template. agy bakes effort into the model ID, so tiers differ by
# MODEL: .model is MID's; .tiers.TOP may carry one ["--model","<id>"] override,
# which the worker collapses so only a single -m reaches agy. Every model ID is
# validated against a tight regex before use.
#
# usage: antigravity-worker [--tier mid|top] < prompt.md
# env:   ANTIGRAVITY_TIERS_FILE, ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1,
#        ANTIGRAVITY_WORKER_PRINT_TIMEOUT (agy --print-timeout, default 5m)
# exit:  agy's own exit code; 2 usage/config; 6 mktemp failure;
#        7 sandbox unavailable (fail closed); 8 unsafe $HOME for a scheme string
set -euo pipefail

self="${BASH_SOURCE[0]}"
while [[ -L "$self" ]]; do
    target="$(readlink "$self")"
    case "$target" in
        /*) self="$target" ;;
        *)  self="$(cd "$(dirname "$self")" && pwd)/$target" ;;
    esac
done
SELF_DIR="$(cd "$(dirname "$self")" && pwd)"

TIER="mid"
if [[ "${1:-}" == "--tier" ]]; then
    TIER="${2:-}"
    case "$TIER" in mid|top) ;; *) echo "antigravity-worker: --tier must be mid or top (got '$TIER')" >&2; exit 2 ;; esac
fi

command -v jq >/dev/null 2>&1 || { echo "antigravity-worker: jq is required to read the tiers file" >&2; exit 2; }
command -v agy >/dev/null 2>&1 || { echo "antigravity-worker: agy CLI not found on PATH (install: https://antigravity.google/cli/install.sh — auth lives in the OS keyring)" >&2; exit 127; }

TIERS_FILE="${ANTIGRAVITY_TIERS_FILE:-$HOME/.gemini/antigravity-cli/agent-tiers.json}"
[[ -f "$TIERS_FILE" ]] || TIERS_FILE="$SELF_DIR/antigravity-tiers.json.template"
[[ -f "$TIERS_FILE" ]] || { echo "antigravity-worker: no tiers file (looked at ~/.gemini/antigravity-cli/agent-tiers.json and the shipped template)" >&2; exit 2; }

# A model ID is the only free-form token the tiers file feeds to argv; pin its
# shape so a tampered tiers file cannot smuggle a flag through the model slot.
valid_model() { [[ "$1" =~ ^gemini-[0-9]+\.[0-9]+-(pro|flash)-(low|medium|high)$ ]]; }

BASE_MODEL="$(jq -r '.model // empty' "$TIERS_FILE")"
[[ -n "$BASE_MODEL" ]] || { echo "antigravity-worker: tiers file $TIERS_FILE pins no .model" >&2; exit 2; }
TIER_KEY="$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')"

# Resolve ONE model for this tier: the tier's ["--model","<id>"] override if
# present, else .model. Only --model + a valid id is accepted in a tier's args —
# anything else means a tampered tiers file, refuse.
MODEL="$BASE_MODEL"
TIER_TOKS=()
while IFS= read -r tok; do
    [[ -n "$tok" ]] && TIER_TOKS+=("$tok")
done < <(jq -r --arg t "$TIER_KEY" '.tiers[$t] // [] | .[]' "$TIERS_FILE")
i=0
while [[ $i -lt ${#TIER_TOKS[@]} ]]; do
    case "${TIER_TOKS[$i]}" in
        --model)
            MODEL="${TIER_TOKS[$((i+1))]:-}"
            i=$((i+2)) ;;
        *)
            echo "antigravity-worker: tiers file $TIERS_FILE carries a non-allowlisted tier token ('${TIER_TOKS[$i]}') — only --model <id> is permitted; refusing" >&2
            exit 2 ;;
    esac
done
valid_model "$MODEL" || { echo "antigravity-worker: resolved model '$MODEL' is not a valid agy model id — refusing" >&2; exit 2; }

PRINT_TIMEOUT="${ANTIGRAVITY_WORKER_PRINT_TIMEOUT:-5m}"

# $HOME is interpolated into the SBPL scheme string; a value containing scheme
# metacharacters could widen the profile. Refuse rather than emit a profile
# whose meaning we can't vouch for.
case "$HOME" in
    *'"'*|*'('*|*')'*|*'\'*) echo "antigravity-worker: \$HOME contains a scheme metacharacter — refusing to build a sandbox profile" >&2; exit 8 ;;
esac

WORK_DIR="$(mktemp -d)" || { echo "antigravity-worker: mktemp -d failed" >&2; exit 6; }
PROMPT_FILE="$WORK_DIR/prompt.md"   # inside WORK_DIR so cleanup takes it too
cat > "$PROMPT_FILE"

# Flags BEFORE the positional prompt (measured: flags after -p are misparsed).
# --dangerously-skip-permissions is NEVER present. --output-format json gives
# call-worker the status/response envelope; --print-timeout caps a hung run.
CMD=(agy --model "$MODEL" --output-format json --print-timeout "$PRINT_TIMEOUT"
     -p "$(cat "$PROMPT_FILE")")

if command -v sandbox-exec >/dev/null 2>&1; then
    # Deny writes outside this run's WORK_DIR and the agy state dir; deny reads
    # of the obvious credential stores so a prompt-driven exfil finds nothing.
    # Network + process-exec stay open: agy needs the vendor API, and denying
    # process-exec blocks the CLI's own launch. Later matching SBPL rule wins.
    SBPROF='(version 1)(allow default)
(deny file-write*)
(allow file-write* (subpath "'"$WORK_DIR"'") (subpath "'"$HOME"'/.gemini") (subpath "'"$HOME"'/.antigravity") (subpath "/dev"))
(deny file-read* (subpath "'"$HOME"'/.ssh") (subpath "'"$HOME"'/.aws") (subpath "'"$HOME"'/.config") (subpath "'"$HOME"'/.codex") (subpath "'"$HOME"'/.grok"))'
    RUN=(sandbox-exec -p "$SBPROF" "${CMD[@]}")
elif [[ "${ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED:-0}" == "1" ]]; then
    echo "antigravity-worker: WARNING dispatching UNSANDBOXED (ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1) — only review trusted content this way" >&2
    RUN=("${CMD[@]}")
else
    rm -rf "$WORK_DIR"
    echo "antigravity-worker: sandbox-exec not available. Refusing; set ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1 to accept an unsandboxed dispatch." >&2
    exit 7
fi

# Run as a CHILD (not exec) with signal forwarding so the EXIT trap fires and
# the prompt file — the untrusted diff — never outlives the dispatch.
child=
cleanup() { rm -rf "$WORK_DIR"; }
forward() { [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null || true; }
trap cleanup EXIT
trap forward TERM INT
cd "$WORK_DIR"
"${RUN[@]}" &
child=$!
rc=0
wait "$child" || rc=$?
exit "$rc"
