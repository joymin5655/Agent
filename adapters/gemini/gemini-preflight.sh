#!/usr/bin/env bash
# gemini-preflight.sh — fail-closed health probe for the Gemini CLI worker lane.
#
# This lane was RETIRED 2026-07-17 (individual OAuth sign-in removed upstream)
# and re-verified 2026-08-19: a cached ~/.gemini/oauth_creds.json still gets
# 401 UNAUTHENTICATED / ACCESS_TOKEN_TYPE_UNSUPPORTED from the API. The
# backend stays enabled:false until THIS probe passes after a real login —
# that is the registry's re-enable condition, not the presence of a
# credential file.
#
# call-worker.sh runs this before dispatching; nonzero here means "unavailable"
# (125 -> 127) and NO paid dispatch is made. Same refusal bias and the same
# closed holes as adapters/kiro/kiro-preflight.sh:
#   (a) exit codes prove nothing — only a real inference round trip does;
#   (b) a cached credential (~/.gemini/oauth_creds.json) can be stale — presence of the
#       file is not an auth check;
#   (c) exit 0 + a reply body is not proof of inference — the probe demands ONE
#       EXACT TOKEN back;
#   (d) the probe exercises the argv the dispatch will run: cmd[0] is resolved
#       from core/infra/backends.json (the same file, the same jq lookup
#       call-worker.sh uses), probed on the lane's cheapest tier (mid — same
#       binary, same tiers file, same sandbox path as the top-tier dispatch).
#
# usage: gemini-preflight.sh [lane]           # lane = a backends.json backend name
# env:   AGENT_PREFLIGHT_LANE (lane when no argv — call-worker.sh sets it)
#        AGENT_BACKENDS_FILE  (registry path — call-worker.sh sets it)
#        GEMINI_PREFLIGHT_TIMEOUT_S (default 60)
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

LANE="${1:-${AGENT_PREFLIGHT_LANE:-gemini}}"
REGISTRY="${AGENT_BACKENDS_FILE:-$SELF_DIR/../../core/infra/backends.json}"
PROBE_TIMEOUT_S="${GEMINI_PREFLIGHT_TIMEOUT_S:-60}"
PROBE_TOKEN="GEMINI-PREFLIGHT-OK-7d1f3a"
PROBE_PROMPT="Reply with exactly this token and nothing else: $PROBE_TOKEN"

# sanitize — strip control bytes from file-derived text before it reaches
# stderr (C0/DEL; multi-byte text passes untouched under LC_ALL=C).
sanitize() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?'; }

[[ "$PROBE_TIMEOUT_S" =~ ^[0-9]+$ ]] || {
    echo "gemini-preflight: GEMINI_PREFLIGHT_TIMEOUT_S is not numeric ('$(sanitize "$PROBE_TIMEOUT_S")') — refusing" >&2
    exit 7
}
command -v jq >/dev/null 2>&1 || {
    echo "gemini-preflight: jq is required to resolve lane '$(sanitize "$LANE")' from the backends registry — refusing rather than guessing the dispatch argv" >&2
    exit 7
}
[[ -f "$REGISTRY" ]] || {
    echo "gemini-preflight: backends registry not found: $(sanitize "$REGISTRY") — refusing" >&2
    exit 7
}

# (d) cmd[0] from the registry — the same executable the dispatch resolves.
CLI="$(jq -r --arg lane "$LANE" '(.backends[$lane].cmd // [])[0] // empty' "$REGISTRY" 2>/dev/null)"
[[ -n "$CLI" ]] || {
    echo "gemini-preflight: lane '$(sanitize "$LANE")' yields no cmd[0] from $(sanitize "$REGISTRY") — refusing" >&2
    exit 7
}
command -v "$CLI" >/dev/null 2>&1 || {
    echo "gemini-preflight: worker '$(sanitize "$CLI")' (cmd[0] of lane '$(sanitize "$LANE")') not found on PATH — install: ln -sf .../adapters/gemini/gemini-worker.sh ~/bin/gemini-worker" >&2
    exit 1
}

OUT="$(mktemp)" || { echo "gemini-preflight: mktemp failed — refusing rather than probing blind" >&2; exit 6; }
trap 'rm -f "$OUT"' EXIT INT TERM

# (a)+(c)+(d) Real round trip through the worker on the cheapest tier. Portable
# watchdog — macOS ships no GNU timeout (same shape as call-worker.sh).
printf '%s' "$PROBE_PROMPT" | "$CLI" --tier mid > "$OUT" 2>&1 &
probe_pid=$!
( sleep "$PROBE_TIMEOUT_S" && kill -KILL "$probe_pid" 2>/dev/null ) &
watchdog_pid=$!
probe_rc=0
wait "$probe_pid" || probe_rc=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

emit_capture() { tr -d '\000-\010\013-\037\177' < "$OUT" | sed -e 's/^/gemini-preflight:   /' >&2; }

if [[ $probe_rc -eq 137 ]]; then
    echo "gemini-preflight: probe timed out after ${PROBE_TIMEOUT_S}s — refusing" >&2
    exit 4
fi
# Auth text FIRST — a CLI can print an auth failure and still exit 0.
if grep -qiE 'IneligibleTierError|ACCESS_TOKEN_TYPE_UNSUPPORTED|UNAUTHENTICATED|not logged in|please log in|log ?in with|unauthorized|unauthenticated|forbidden|access denied|authentication failed|invalid.*(api.?key|credential|token)|(credential|token|session|login|subscription)[^.]{0,40}(expired|has expired)' "$OUT"; then
    echo "gemini-preflight: the CLI reports an authentication failure — refusing" >&2
    emit_capture
    exit 3
fi
if [[ $probe_rc -ne 0 ]]; then
    echo "gemini-preflight: probe exited $probe_rc — refusing (state unknown)" >&2
    emit_capture
    exit 5
fi
# (c) Positive proof: the exact token, matched on an ANSI-stripped copy.
if ! sed -e 's/'$'\033''\[[0-9;?]*[a-zA-Z]//g' "$OUT" | grep -Fq "$PROBE_TOKEN"; then
    echo "gemini-preflight: probe exited 0 but the reply does not contain the requested token ($PROBE_TOKEN) — no proof of inference, refusing" >&2
    emit_capture
    exit 5
fi
exit 0
