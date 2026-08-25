#!/usr/bin/env bash
# openrouter-preflight.sh — fail-closed health probe for the OpenRouter
# free-tier advisory lane. Mirrors adapters/grok/grok-preflight.sh's design
# and exit-code contract.
#
# call-worker.sh runs this before dispatching; nonzero here means "unavailable"
# (125 -> 127) and NO dispatch is made (this lane rides a :free model, so a
# probe round trip is non-billable — still worth gating: an unauthenticated or
# broken lane must not silently degrade the council to fewer seats). Same
# refusal bias and closed holes as the grok/kiro preflights:
#   (a) exit codes prove nothing — only a real inference round trip does;
#   (b) a cached credential can be stale — presence of the Keychain entry is
#       checked FIRST for a fast, actionable error, but is not itself proof;
#   (c) exit 0 + a reply body is not proof of inference — the probe demands ONE
#       EXACT TOKEN back;
#   (d) the probe exercises the argv the dispatch will run: cmd[0] is resolved
#       from core/infra/backends.json (the same file, the same jq lookup
#       call-worker.sh uses), probed on the lane's cheapest tier (low — same
#       worker, same tiers file, same request shape as the top-tier dispatch).
#
# usage: openrouter-preflight.sh [lane]     # lane = a backends.json backend name
# env:   AGENT_PREFLIGHT_LANE (lane when no argv — call-worker.sh sets it)
#        AGENT_BACKENDS_FILE  (registry path — call-worker.sh sets it)
#        OPENROUTER_PREFLIGHT_TIMEOUT_S (default 60)
# exit:  0 reachable+authenticated | 1 worker/CLI missing | 3 auth rejected
#        4 probe timed out | 5 probe failed / no success token | 6 mktemp
#        failure | 7 registry/lane unusable
set -uo pipefail

self="${BASH_SOURCE[0]}"
while [[ -L "$self" ]]; do
    target="$(readlink "$self")"
    case "$target" in
        /*) self="$target" ;;
        *)  self="$(cd "$(dirname "$self")" && pwd)/$target" ;;
    esac
done
SELF_DIR="$(cd "$(dirname "$self")" && pwd)"

LANE="${1:-${AGENT_PREFLIGHT_LANE:-openrouter}}"
REGISTRY="${AGENT_BACKENDS_FILE:-$SELF_DIR/../../core/infra/backends.json}"
PROBE_TIMEOUT_S="${OPENROUTER_PREFLIGHT_TIMEOUT_S:-60}"
PROBE_TOKEN="OPENROUTER-PREFLIGHT-OK-7f1a3d"
PROBE_PROMPT="Reply with exactly this token and nothing else: $PROBE_TOKEN"

# sanitize — strip control bytes from file-derived text before it reaches
# stderr (C0/DEL; multi-byte text passes untouched under LC_ALL=C).
sanitize() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?'; }

[[ "$PROBE_TIMEOUT_S" =~ ^[0-9]+$ ]] || {
    echo "openrouter-preflight: OPENROUTER_PREFLIGHT_TIMEOUT_S is not numeric ('$(sanitize "$PROBE_TIMEOUT_S")') — refusing" >&2
    exit 7
}
command -v jq >/dev/null 2>&1 || {
    echo "openrouter-preflight: jq is required to resolve lane '$(sanitize "$LANE")' from the backends registry — refusing rather than guessing the dispatch argv" >&2
    exit 7
}
[[ -f "$REGISTRY" ]] || {
    echo "openrouter-preflight: backends registry not found: $(sanitize "$REGISTRY") — refusing" >&2
    exit 7
}

# (d) cmd[0] from the registry — the same executable the dispatch resolves.
CLI="$(jq -r --arg lane "$LANE" '(.backends[$lane].cmd // [])[0] // empty' "$REGISTRY" 2>/dev/null)"
[[ -n "$CLI" ]] || {
    echo "openrouter-preflight: lane '$(sanitize "$LANE")' yields no cmd[0] from $(sanitize "$REGISTRY") — refusing" >&2
    exit 7
}
command -v "$CLI" >/dev/null 2>&1 || {
    echo "openrouter-preflight: worker '$(sanitize "$CLI")' (cmd[0] of lane '$(sanitize "$LANE")') not found on PATH — install: ln -sf .../adapters/openrouter/openrouter-worker.sh ~/bin/openrouter-worker" >&2
    exit 1
}

# (b) fast, actionable failure for the common case — a missing credential —
# before paying for a round trip that would fail the same way, less clearly.
if command -v security >/dev/null 2>&1; then
    security find-generic-password -a "$USER" -s openrouter-api-key -w >/dev/null 2>&1 || {
        echo "openrouter-preflight: no Keychain entry 'openrouter-api-key' — register: security add-generic-password -a \"\$USER\" -s openrouter-api-key -w" >&2
        exit 3
    }
fi

OUT="$(mktemp)" || { echo "openrouter-preflight: mktemp failed — refusing rather than probing blind" >&2; exit 6; }
trap 'rm -f "$OUT"' EXIT INT TERM HUP

# (a)+(c)+(d) Real round trip through the worker on the cheapest tier. Portable
# watchdog — macOS ships no GNU timeout (same shape as call-worker.sh).
printf '%s' "$PROBE_PROMPT" | "$CLI" --tier low > "$OUT" 2>&1 &
probe_pid=$!
# Stdio explicitly closed on the watchdog subshell itself: `kill "$watchdog_pid"`
# below only terminates the subshell, not the `sleep` it is blocked inside —
# that grandchild is orphaned, not killed, and keeps running until its own
# timeout. If it inherited this script's stdout/stderr (the default), a caller
# capturing this preflight via command substitution (`out="$(... 2>&1)"`) would
# not see EOF — and so would not return — until that orphaned sleep actually
# expires, up to the full $PROBE_TIMEOUT_S, even though the probe itself
# finished instantly. call-worker.sh's own invocation already redirects this
# script's stdio to a file rather than a pipe, so it never hits this; closing
# it here too makes the script correct under either calling convention.
# TERM first, KILL only after a grace period: the worker holds the API key in
# a file inside its WORK_DIR and scrubs it via an EXIT trap — SIGKILL would
# skip that trap and leave the key on disk (council review 2026-08-25).
( sleep "$PROBE_TIMEOUT_S" && kill -TERM "$probe_pid" 2>/dev/null \
  && sleep 5 && kill -KILL "$probe_pid" 2>/dev/null ) >/dev/null 2>&1 &
watchdog_pid=$!
probe_rc=0
wait "$probe_pid" || probe_rc=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

emit_capture() { tr -d '\000-\010\013-\037\177' < "$OUT" | sed -e 's/^/openrouter-preflight:   /' >&2; }

if [[ $probe_rc -eq 137 ]]; then
    echo "openrouter-preflight: probe timed out after ${PROBE_TIMEOUT_S}s — refusing" >&2
    exit 4
fi
# Auth/refusal text FIRST — the worker can print an auth or config failure and
# still exit nonzero for a reason grep below wouldn't catch cleanly.
if grep -qiE 'no keychain entry|unauthorized|unauthenticated|forbidden|access denied|authentication failed|invalid.*(api.?key|credential|token)|(credential|token|session|login)[^.]{0,40}(expired|has expired)' "$OUT"; then
    echo "openrouter-preflight: the worker reports an authentication failure — refusing" >&2
    emit_capture
    exit 3
fi
if [[ $probe_rc -ne 0 ]]; then
    echo "openrouter-preflight: probe exited $probe_rc — refusing (state unknown)" >&2
    emit_capture
    exit 5
fi
# (c) Positive proof: the exact token, matched on an ANSI-stripped copy.
if ! sed -e 's/'$'\033''\[[0-9;?]*[a-zA-Z]//g' "$OUT" | grep -Fq "$PROBE_TOKEN"; then
    echo "openrouter-preflight: probe exited 0 but the reply does not contain the requested token ($PROBE_TOKEN) — no proof of inference, refusing" >&2
    emit_capture
    exit 5
fi
exit 0
