#!/usr/bin/env bash
# gemini-worker.sh — tier bridge for the Gemini CLI worker lane.
#
# call-worker.sh streams the prompt on STDIN; `gemini -p ""` appends stdin to
# the (empty) prompt, so no prompt-file bridge is needed — this wrapper exists
# for the TIER seam (model IDs are forbidden in core/infra/backends.json, and
# the gemini CLI has no profile concept) and for the SAME OS-enforced read-only
# posture as adapters/grok/grok-worker.sh.
#
# THREAT MODEL & sandbox: identical to grok-worker.sh — the prompt carries an
# untrusted diff, agentic CLIs' own flags are not a write barrier, so the
# sandbox-exec profile (fail-closed) denies all writes except this run's
# WORK_DIR and ~/.gemini (minus the tiers file), and denies reads of the
# credential stores so a tool-driven exfil finds nothing to send. Network and
# process-exec stay open (the CLI needs them). Gemini is a SEATED council
# reviewer, so before this lane is re-enabled its tool/web-search posture must
# be pinned too (the CLI's default tool set is not restricted here) — noted in
# the registry's re-enable condition.
#
# Read-only is OS-enforced; without sandbox-exec the worker refuses unless
# GEMINI_WORKER_ALLOW_UNSANDBOXED=1.
#
# usage: gemini-worker [--tier mid|top] < prompt.md
# env:   GEMINI_TIERS_FILE, GEMINI_WORKER_ALLOW_UNSANDBOXED=1
# exit:  the gemini CLI's own exit code; 2 usage/config; 6 mktemp failure;
#        7 sandbox unavailable (fail closed); 8 unsafe $HOME
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
    case "$TIER" in mid|top) ;; *) echo "gemini-worker: --tier must be mid or top (got '$TIER')" >&2; exit 2 ;; esac
fi

command -v jq >/dev/null 2>&1 || { echo "gemini-worker: jq is required to read the tiers file" >&2; exit 2; }
command -v gemini >/dev/null 2>&1 || { echo "gemini-worker: gemini CLI not found on PATH" >&2; exit 127; }

TIERS_FILE="${GEMINI_TIERS_FILE:-$HOME/.gemini/agent-tiers.json}"
[[ -f "$TIERS_FILE" ]] || TIERS_FILE="$SELF_DIR/gemini-tiers.json.template"
[[ -f "$TIERS_FILE" ]] || { echo "gemini-worker: no tiers file (looked at ~/.gemini/agent-tiers.json and the shipped template)" >&2; exit 2; }

TIER_KEY="$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')"
# Allow-list: only `-m <model>` is a legitimate tier arg for gemini.
TIER_ARGS=()
expect_model=0
while IFS= read -r tok; do
    if [[ $expect_model -eq 1 ]]; then TIER_ARGS+=("$tok"); expect_model=0; continue; fi
    case "$tok" in
        -m|--model) TIER_ARGS+=("$tok"); expect_model=1 ;;
        "") ;;
        *) echo "gemini-worker: tiers file $TIERS_FILE carries a non-allowlisted tier arg ('$tok') — refusing" >&2; exit 2 ;;
    esac
done < <(jq -r --arg t "$TIER_KEY" '.tiers[$t] // [] | .[]' "$TIERS_FILE")

case "$HOME" in
    *'"'*|*'('*|*')'*|*'\'*) echo "gemini-worker: \$HOME contains a scheme metacharacter — refusing to build a sandbox profile" >&2; exit 8 ;;
esac

WORK_DIR="$(mktemp -d)" || { echo "gemini-worker: mktemp -d failed" >&2; exit 6; }
PROMPT_FILE="$WORK_DIR/prompt.md"   # capture stdin: backgrounding the child (for
cat > "$PROMPT_FILE"                # signal forwarding) would otherwise detach it

# --skip-trust: the worker runs from a fresh harness-owned mktemp cwd (neutral,
# empty), which the CLI would otherwise refuse as an untrusted folder in
# headless mode. Writes are already sandbox-constrained, so trusting this empty
# scratch dir grants nothing.
CMD=(gemini --skip-trust -o text -p "")
[[ ${#TIER_ARGS[@]} -gt 0 ]] && CMD+=("${TIER_ARGS[@]}")

if command -v sandbox-exec >/dev/null 2>&1; then
    SBPROF='(version 1)(allow default)
(deny file-write*)
(allow file-write* (subpath "'"$WORK_DIR"'") (subpath "'"$HOME"'/.gemini") (subpath "/dev"))
(deny file-write* (literal "'"$HOME"'/.gemini/agent-tiers.json"))
(deny file-read* (subpath "'"$HOME"'/.ssh") (subpath "'"$HOME"'/.aws") (subpath "'"$HOME"'/.config") (subpath "'"$HOME"'/.codex") (subpath "'"$HOME"'/.grok"))'
    RUN=(sandbox-exec -p "$SBPROF" "${CMD[@]}")
elif [[ "${GEMINI_WORKER_ALLOW_UNSANDBOXED:-0}" == "1" ]]; then
    echo "gemini-worker: WARNING dispatching UNSANDBOXED — the CLI's tools can read secrets and write files; only review trusted content this way" >&2
    RUN=("${CMD[@]}")
else
    rm -rf "$WORK_DIR"
    echo "gemini-worker: sandbox-exec not available — refusing an unsandboxed agentic dispatch (set GEMINI_WORKER_ALLOW_UNSANDBOXED=1 to accept the risk)." >&2
    exit 7
fi

# Run as a child with signal forwarding so the EXIT trap cleans WORK_DIR (exec
# would skip it). Prompt is on stdin, streamed straight through to the CLI.
child=
cleanup() { rm -rf "$WORK_DIR"; }
forward() { [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null || true; }
trap cleanup EXIT
trap forward TERM INT
cd "$WORK_DIR"
"${RUN[@]}" < "$PROMPT_FILE" &
child=$!
rc=0
wait "$child" || rc=$?
exit "$rc"
