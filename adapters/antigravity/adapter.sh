#!/usr/bin/env bash
# Antigravity CLI (agy) native hook adapter launcher.
#
# The plugin's hooks.json wires one command per agy event:
#   adapter.sh <PreToolUse|PostToolUse|Stop>      # stdin = agy hook JSON
# adapter.py translates the event to the canonical protocol, runs the whole
# core-hook chain for it, and prints agy's decision JSON (see adapter.py).
# Always exits 0 for a valid event: agy reads the decision from stdout.
#
# Env: AGENT_ANTIGRAVITY_WORKER=1 (review worker: deny tools, stop immediately),
#      AGENT_STATE_DIR (Stop loop marker root, default ~/.agent/state).

set -euo pipefail

EVENT="${1:-}"
case "$EVENT" in
    PreToolUse|PostToolUse|Stop) ;;
    *) echo "usage: adapter.sh <PreToolUse|PostToolUse|Stop>" >&2; exit 2 ;;
esac

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSLATOR="$ADAPTER_DIR/adapter.py"

if [[ -f "$TRANSLATOR" ]] && command -v python3 >/dev/null 2>&1; then
    exec python3 "$TRANSLATOR" "$EVENT"
fi

# No python3 (or no translator): agy reads `{}` on PreToolUse as a deny anyway,
# but say why. PostToolUse/Stop cannot block, so they answer neutrally.
case "$EVENT" in
    PreToolUse) printf '%s\n' '{"decision":"deny","reason":"[agent/antigravity] python3 or adapter.py not found; Agent guards cannot run, blocked fail-closed."}' ;;
    PostToolUse) printf '%s\n' '{}' ;;
    Stop) printf '%s\n' '{"decision":"stop"}' ;;
esac
