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
# $ANTIGRAVITY_TIERS_FILE > ~/.agent/antigravity-tiers.json (one-time migrated
# from the old ~/.gemini/antigravity-cli/agent-tiers.json path if only that one
# exists) > the shipped template. agy bakes effort into the model ID, so tiers
# differ by MODEL: .model is MID's; .tiers.TOP may carry one
# ["--model","<id>"] override, which the worker collapses so only a single -m
# reaches agy. A tier may also carry ["--effort","<level>"], passed through
# verbatim as agy's own separate --effort flag. Every model ID is validated
# against a tight regex before use; every effort level against an allowlist.
#
# SUCCESS: agy's exit 0 alone proves nothing. Headless agy SOFT-DENIES a tool
# call it cannot get approval for — the run continues, exits 0, and prints a
# notice on stderr (docs/cli/headless). So a dispatch counts only when the
# --output-format json envelope says status "SUCCESS" AND no soft-deny notice
# was printed; the envelope and stderr are forwarded unchanged either way.
# The notice's exact wording is undocumented; SOFT_DENY_RE matches the text
# measured on agy 1.1.14 (probes/probe1-default.txt) — unverified on 1.2.x.
#
# usage: antigravity-worker [--tier mid|top] < prompt.md
# env:   ANTIGRAVITY_TIERS_FILE, ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1,
#        ANTIGRAVITY_WORKER_PRINT_TIMEOUT (agy --print-timeout, default 5m)
# exit:  agy's own nonzero exit code; 2 usage/config; 6 mktemp failure;
#        7 sandbox unavailable (fail closed); 8 unsafe $HOME for a scheme string;
#        9 agy exited 0 but soft-denied a tool call; 10 agy exited 0 but the
#        envelope is unparseable or its status is not SUCCESS
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

NEW_TIERS_FILE="$HOME/.agent/antigravity-tiers.json"
OLD_TIERS_FILE="$HOME/.gemini/antigravity-cli/agent-tiers.json"

if [[ -n "${ANTIGRAVITY_TIERS_FILE:-}" ]]; then
    TIERS_FILE="$ANTIGRAVITY_TIERS_FILE"
elif [[ -f "$NEW_TIERS_FILE" && -f "$OLD_TIERS_FILE" ]]; then
    # Both paths exist: the new path wins, but a stale old copy silently
    # shadowing an edit to the new one is a surprising failure mode — warn.
    echo "antigravity-worker: both $NEW_TIERS_FILE and $OLD_TIERS_FILE exist — using $NEW_TIERS_FILE; the old copy is unused and stale, remove it to silence this warning" >&2
    TIERS_FILE="$NEW_TIERS_FILE"
elif [[ -f "$NEW_TIERS_FILE" ]]; then
    TIERS_FILE="$NEW_TIERS_FILE"
elif [[ -f "$OLD_TIERS_FILE" ]]; then
    # One-time migration off the vendor CLI's own config dir.
    mkdir -p "$HOME/.agent"
    cp "$OLD_TIERS_FILE" "$NEW_TIERS_FILE"
    echo "antigravity-worker: migrated tiers file $OLD_TIERS_FILE -> $NEW_TIERS_FILE (one-time); the old path will no longer be read" >&2
    TIERS_FILE="$NEW_TIERS_FILE"
else
    TIERS_FILE="$SELF_DIR/antigravity-tiers.json.template"
fi
[[ -f "$TIERS_FILE" ]] || { echo "antigravity-worker: no tiers file (looked at $NEW_TIERS_FILE, $OLD_TIERS_FILE, and the shipped template)" >&2; exit 2; }

# A model ID / effort level is the only free-form tokens the tiers file feeds
# to argv; pin their shape so a tampered tiers file cannot smuggle a flag
# through either slot.
valid_model() { [[ "$1" =~ ^gemini-[0-9]+\.[0-9]+-(pro|flash)-(low|medium|high)$ ]]; }
valid_effort() { [[ "$1" =~ ^(low|medium|high|max)$ ]]; }

BASE_MODEL="$(jq -r '.model // empty' "$TIERS_FILE")"
[[ -n "$BASE_MODEL" ]] || { echo "antigravity-worker: tiers file $TIERS_FILE pins no .model" >&2; exit 2; }
TIER_KEY="$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')"

# Resolve ONE model (and an optional --effort) for this tier: the tier's
# ["--model","<id>"] / ["--effort","<level>"] overrides if present, else
# .model with no --effort. Only --model + a valid id, or --effort + a valid
# level, is accepted in a tier's args — anything else means a tampered tiers
# file, refuse.
MODEL="$BASE_MODEL"
EFFORT=""
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
        --effort)
            EFFORT="${TIER_TOKS[$((i+1))]:-}"
            i=$((i+2)) ;;
        *)
            echo "antigravity-worker: tiers file $TIERS_FILE carries a non-allowlisted tier token ('${TIER_TOKS[$i]}') — only --model <id> and --effort <level> are permitted; refusing" >&2
            exit 2 ;;
    esac
done
valid_model "$MODEL" || { echo "antigravity-worker: resolved model '$MODEL' is not a valid agy model id — refusing" >&2; exit 2; }
if [[ -n "$EFFORT" ]]; then
    valid_effort "$EFFORT" || { echo "antigravity-worker: resolved effort '$EFFORT' is not a valid agy effort level — refusing" >&2; exit 2; }
fi

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
CMD=(agy --model "$MODEL")
[[ -n "$EFFORT" ]] && CMD+=(--effort "$EFFORT")
CMD+=(--output-format json --print-timeout "$PRINT_TIMEOUT"
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

# agy's stdout/stderr land in CAP_DIR, OUTSIDE the sandbox's writable WORK_DIR
# (agy's cwd), so a prompt-driven file write cannot forge the envelope we judge.
CAP_DIR="$(mktemp -d)" || { rm -rf "$WORK_DIR"; echo "antigravity-worker: mktemp -d failed" >&2; exit 6; }

# Run as a CHILD (not exec) with signal forwarding so the EXIT trap fires and
# the prompt file — the untrusted diff — never outlives the dispatch.
child=
cleanup() { rm -rf "$WORK_DIR" "$CAP_DIR"; }
forward() { [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null || true; }
trap cleanup EXIT
trap forward TERM INT
cd "$WORK_DIR"
"${RUN[@]}" > "$CAP_DIR/out" 2> "$CAP_DIR/err" &
child=$!
rc=0
wait "$child" || rc=$?
cat "$CAP_DIR/err" >&2
cat "$CAP_DIR/out"
[[ $rc -eq 0 ]] || exit "$rc"

SOFT_DENY_RE='permission check failed|denied permission to'
err_text="$(<"$CAP_DIR/err")"
shopt -s nocasematch
if [[ "$err_text" =~ $SOFT_DENY_RE ]]; then
    echo "antigravity-worker: agy exited 0 but soft-denied a tool call (notice above) — result is incomplete; not reporting success" >&2
    exit 9
fi
shopt -u nocasematch
# -s: the whole stdout must be exactly ONE json value — trailing text fails.
status="$(jq -rs 'if length == 1 then (.[0].status // empty) else empty end' "$CAP_DIR/out" 2>/dev/null || true)"
if [[ "$status" != "SUCCESS" ]]; then
    echo "antigravity-worker: agy exited 0 but the json envelope status is '${status:-<unparseable>}', not SUCCESS — not reporting success" >&2
    exit 10
fi
exit 0
