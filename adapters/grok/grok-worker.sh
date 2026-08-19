#!/usr/bin/env bash
# grok-worker.sh — stdin->argv bridge for the xAI grok CLI worker lane.
#
# call-worker.sh streams the prompt on STDIN, but `grok` takes its single-turn
# prompt as an ARGUMENT (-p) or a FILE (--prompt-file) — there is no stdin
# prompt mode. This bridge writes stdin to a file and dispatches
# `grok --prompt-file`, so the registry keeps the uniform
# "cmd + tier_args, prompt on stdin" contract.
#
# THREAT MODEL: the prompt carries an untrusted diff (an outside-contributor
# PR is the lane's normal input), and the grok CLI exposes a live `shell` tool
# its own flags do NOT disable (measured 0.2.118, 2026-08-19 — see
# adapters/grok/README.md). So a prompt can drive arbitrary local action. The
# ONLY enforcement is an OS sandbox, and it must block the two things an
# exfil needs: reading secrets, and writing where it can do damage.
#
# The sandbox-exec profile (fail-closed — no sandbox-exec => refuse):
#   * deny ALL writes except this run's private WORK_DIR and the CLI's own
#     session store ~/.grok — MINUS ~/.grok/agent-tiers.json, which supplies
#     this worker's argv: a writable tiers file is a persistence hole (rewrite
#     it in one run, run attacker flags the next). Narrowing writes to WORK_DIR
#     also stops a concurrent council lane from forging a sibling's capture
#     (call-worker's mktemp scratch is no longer world-writable to this run).
#   * deny reads of the obvious credential stores (~/.ssh ~/.aws ~/.config and
#     the sibling CLIs' auth) so a `shell`+network exfil finds nothing to send.
#     Network and process-exec stay OPEN: the CLI needs the vendor API, and
#     denying process-exec blocks the CLI's own launch (measured).
# Residual risk (documented, not closed here): a determined prompt can still
# exfil data it can READ (the diff it was given, public files). The lane is for
# reviewing code you are willing to send to xAI anyway.
#
# Web search is DISABLED by default: search queries derive from the prompt —
# i.e. from the diff — an exfil channel. GROK_WORKER_WEB_SEARCH=1 opts in.
#
# Tier policy: model IDs are forbidden in core/infra/backends.json
# (no-model-ids gate), so the model pin + per-tier args live in a tiers file
# THIS adapter owns: $GROK_TIERS_FILE > ~/.grok/agent-tiers.json > the shipped
# template. Each tier arg is validated against an allow-list before use.
#
# usage: grok-worker [--tier mid|top] < prompt.md
# env:   GROK_TIERS_FILE, GROK_WORKER_WEB_SEARCH=1, GROK_WORKER_ALLOW_UNSANDBOXED=1,
#        GROK_WORKER_MAX_TURNS (default 4)
# exit:  the grok CLI's own exit code; 2 usage/config; 6 mktemp failure;
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
    case "$TIER" in mid|top) ;; *) echo "grok-worker: --tier must be mid or top (got '$TIER')" >&2; exit 2 ;; esac
fi

command -v jq >/dev/null 2>&1 || { echo "grok-worker: jq is required to read the tiers file" >&2; exit 2; }
command -v grok >/dev/null 2>&1 || { echo "grok-worker: grok CLI not found on PATH (install: https://x.ai — auth lives in ~/.grok)" >&2; exit 127; }

TIERS_FILE="${GROK_TIERS_FILE:-$HOME/.grok/agent-tiers.json}"
[[ -f "$TIERS_FILE" ]] || TIERS_FILE="$SELF_DIR/grok-tiers.json.template"
[[ -f "$TIERS_FILE" ]] || { echo "grok-worker: no tiers file (looked at ~/.grok/agent-tiers.json and the shipped template)" >&2; exit 2; }

MODEL="$(jq -r '.model // empty' "$TIERS_FILE")"
[[ -n "$MODEL" ]] || { echo "grok-worker: tiers file $TIERS_FILE pins no .model" >&2; exit 2; }
TIER_KEY="$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')"
# Validate every tier arg against an allow-list: the tiers file is user-owned
# and (despite the write-deny above) could be tampered with out of band, so a
# rewritten flag must not reach the CLI argv. Only these tokens are accepted.
TIER_ARGS=()
while IFS= read -r tok; do
    case "$tok" in
        --reasoning-effort|low|medium|high) TIER_ARGS+=("$tok") ;;
        "") ;;
        *) echo "grok-worker: tiers file $TIERS_FILE carries a non-allowlisted tier arg ('$tok') — refusing" >&2; exit 2 ;;
    esac
done < <(jq -r --arg t "$TIER_KEY" '.tiers[$t] // [] | .[]' "$TIERS_FILE")

# $HOME is interpolated into the SBPL scheme string; a value containing scheme
# metacharacters could widen the profile. Refuse rather than emit a profile
# whose meaning we can't vouch for.
case "$HOME" in
    *'"'*|*'('*|*')'*|*'\'*) echo "grok-worker: \$HOME contains a scheme metacharacter — refusing to build a sandbox profile" >&2; exit 8 ;;
esac

WORK_DIR="$(mktemp -d)" || { echo "grok-worker: mktemp -d failed" >&2; exit 6; }
PROMPT_FILE="$WORK_DIR/prompt.md"   # inside WORK_DIR so cleanup takes it too
cat > "$PROMPT_FILE"

CMD=(grok --prompt-file "$PROMPT_FILE" -m "$MODEL"
     --output-format plain --no-subagents --no-memory
     --max-turns "${GROK_WORKER_MAX_TURNS:-4}")
[[ ${#TIER_ARGS[@]} -gt 0 ]] && CMD+=("${TIER_ARGS[@]}")
[[ "${GROK_WORKER_WEB_SEARCH:-0}" == "1" ]] || CMD+=(--disable-web-search)
[[ "${GROK_WORKER_WEB_SEARCH:-0}" == "1" ]] && echo "grok-worker: WARNING web search enabled — prompt-derived queries can exfiltrate diff content" >&2

if command -v sandbox-exec >/dev/null 2>&1; then
    # Later matching SBPL rule wins, so the tiers-file deny overrides the
    # ~/.grok write-allow for that one path.
    SBPROF='(version 1)(allow default)
(deny file-write*)
(allow file-write* (subpath "'"$WORK_DIR"'") (subpath "'"$HOME"'/.grok") (subpath "/dev"))
(deny file-write* (literal "'"$HOME"'/.grok/agent-tiers.json"))
(deny file-read* (subpath "'"$HOME"'/.ssh") (subpath "'"$HOME"'/.aws") (subpath "'"$HOME"'/.config") (subpath "'"$HOME"'/.codex") (subpath "'"$HOME"'/.gemini"))'
    RUN=(sandbox-exec -p "$SBPROF" "${CMD[@]}")
elif [[ "${GROK_WORKER_ALLOW_UNSANDBOXED:-0}" == "1" ]]; then
    echo "grok-worker: WARNING dispatching UNSANDBOXED (GROK_WORKER_ALLOW_UNSANDBOXED=1) — the CLI's shell tool can read secrets and write files; only review trusted content this way" >&2
    RUN=("${CMD[@]}")
else
    rm -rf "$WORK_DIR"
    echo "grok-worker: sandbox-exec not available and the grok CLI's own flags do not enforce read-only (measured — adapters/grok/README.md). Refusing; set GROK_WORKER_ALLOW_UNSANDBOXED=1 to accept an unsandboxed dispatch." >&2
    exit 7
fi

# Run as a CHILD (not exec) with signal forwarding, so the EXIT trap fires and
# the prompt file — the untrusted diff — never outlives the dispatch. exec would
# replace this shell and skip cleanup (the classic "diff left in $TMPDIR" leak).
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
