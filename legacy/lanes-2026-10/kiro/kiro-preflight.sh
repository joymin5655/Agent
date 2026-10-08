#!/usr/bin/env bash
# kiro-preflight.sh — fail-closed health probe for the Kiro gateway backends.
#
# call-worker.sh runs this before dispatching. A nonzero exit here means the
# backend is "unavailable" (125 -> 127) and NO paid call is made. Everything in
# this script is therefore biased toward refusing: an unknown state is a refusal,
# never a pass.
#
# Four holes this closes, all measured on kiro-cli 2.15.2 (2026-07-30):
#
# (a) NO SUBCOMMAND REPORTS AUTH FAILURE VIA EXIT CODE.
#         kiro-cli --version            -> 0 with no key / bogus key / valid key
#         kiro-cli chat --list-models   -> 0 with no key / bogus key / valid key
#         kiro-cli agent list           -> 0 in all three; prints "not logged in"
#                                          to stderr and still exits 0
#     Worse, `agent list` is a LOCAL directory enumeration — with a bogus key it
#     prints the workspace/global agent paths and nothing else. It cannot
#     validate a credential. Only a real inference call proves the lane is live,
#     so that is what this probe does, on the lane's cheapest profile.
#
# (b) THE CREDENTIAL IS CACHED, SO ENV-VAR PRESENCE PROVES NOTHING.
#     After one successful dispatch the CLI stores a derived session token in the
#     macOS Keychain (service "kirocli:social:token"). From then on a BOGUS
#     KIRO_API_KEY — or none at all — still authenticates. Checking that the env
#     var is set is therefore not an auth check; only the round trip is.
#
# (c) A ZERO EXIT WITH A REPLY BODY IS NOT PROOF OF INFERENCE.
#     "no output" was the only body check an earlier revision made, so a CLI
#     printing "Error: insufficient credits" and exiting 0 passed as healthy.
#     The probe now asks for ONE EXACT TOKEN back and requires it in the output:
#     a reply that does not contain $PROBE_TOKEN is a refusal. That is the only
#     positive evidence available without a paid second call to grade.
#
# (d) THE PROBE MUST EXERCISE THE ARGV THAT WILL ACTUALLY BE DISPATCHED.
#     An earlier revision probed "${KIRO_CLI_BIN:-kiro-cli}" with a bare
#     --model, while call-worker.sh dispatches the registry's
#     cmd + tier_args[tier] (i.e. `--agent <profile>`). Two ways that lied:
#       * KIRO_CLI_BIN=/bin/echo made the probe validate a DIFFERENT executable
#         than the dispatch (echo exits 0 with nonempty output), and the real
#         dispatch then died 127.
#       * --model never touches `--agent` resolution, so every profile could be
#         missing, malformed or shadowed while the probe reported health.
#     So: the argv is composed from core/infra/backends.json — the same file,
#     the same lane, the same jq lookups call-worker.sh uses. The KIRO_CLI_BIN
#     override is DELETED rather than kept as a test seam: the whole point of
#     this probe is that nothing can point it at a binary the dispatch will not
#     run, and an env-gated seam is exactly such a pointer (tests instead put a
#     stub named after the registry's own cmd[0] on PATH, which exercises the
#     real resolution path).
#
# (e) WORKSPACE AGENT PROFILES SHADOW GLOBAL ONES — now defense in depth only.
#     `--agent <name>` resolves ./.kiro/agents/<name>.json BEFORE
#     ~/.kiro/agents/<name>.json, so a repository can ship
#     .kiro/agents/kiro-openai-top.json with "tools": ["shell","write"] and
#     silently replace the read-only profile this framework installed. Measured:
#     the CLI logged "Agent conflict for kiro-openai-low. Using workspace
#     version." and the dispatch then wrote a file under --trust-all-tools.
#     THIS SCAN IS NO LONGER THE PRIMARY CONTROL: a scan before dispatch is
#     TOCTOU-open (anything planting the shadow after the scan wins). The
#     primary control is in core/infra/call-worker.sh, which runs every backend
#     carrying a "gateway" field from a neutral, harness-owned working directory
#     so no repository is ever on the resolution path. The scan stays because it
#     still catches the human-run case (`kiro-preflight` invoked by hand inside
#     a checkout) and costs nothing.
#
# usage: kiro-preflight.sh [lane]           # lane = a backends.json backend name
# env:   AGENT_PREFLIGHT_LANE (lane, when no argv — call-worker.sh sets it)
#        AGENT_BACKENDS_FILE  (registry path — call-worker.sh sets it)
#        KIRO_PREFLIGHT_TIMEOUT_S, KIRO_PREFLIGHT_MODEL (no-profile fallback)
# exit:  0 reachable+authenticated | 1 gateway CLI missing | 2 workspace shadow
#        3 auth rejected | 4 probe timed out | 5 probe failed for another reason
#        (including a reply with no success token) | 6 internal (mktemp) failure
#        7 registry/lane unusable (no jq, no registry, unknown lane, bad shapes)
set -uo pipefail

# Resolve through symlinks: the documented install is
# `ln -sf .../adapters/kiro/kiro-preflight.sh ~/bin/kiro-preflight`, and the
# default registry path is relative to the REAL script location, not the link.
self="${BASH_SOURCE[0]}"
while [[ -L "$self" ]]; do
    target="$(readlink "$self")"
    case "$target" in
        /*) self="$target" ;;
        *)  self="$(cd "$(dirname "$self")" && pwd)/$target" ;;
    esac
done
SELF_DIR="$(cd "$(dirname "$self")" && pwd)"

LANE="${1:-${AGENT_PREFLIGHT_LANE:-kiro-openai}}"
REGISTRY="${AGENT_BACKENDS_FILE:-$SELF_DIR/../../core/infra/backends.json}"
PROBE_TIMEOUT_S="${KIRO_PREFLIGHT_TIMEOUT_S:-45}"
# Only used when the lane pins NO profile at all (a registry that reaches the
# gateway without --agent). Cheapest lane on the price list (0.05x).
PROBE_MODEL="${KIRO_PREFLIGHT_MODEL:-qwen3-coder-next}"
# (c) The one literal that proves inference happened. Distinctive on purpose:
# it cannot plausibly appear in an error string, a banner or a spinner frame.
PROBE_TOKEN="KIRO-PREFLIGHT-OK-4f7c1a"
PROBE_PROMPT="Reply with exactly this token and nothing else: $PROBE_TOKEN"

# sanitize <string> — neutralize terminal-control characters (C8). Every string
# that reaches stderr from here is file-derived (registry values, CLI output,
# filenames), and raw ESC/CR/LF in them can erase lines and forge rows on the
# terminal. Each offender becomes '?' so a crafted name cannot split a message
# either.
#
# Neutralized: C0 (U+0000-U+001F), DEL (U+007F), C1 (U+0080-U+009F) and the bidi
# controls (U+200E, U+200F, U+202A-U+202E, U+2066-U+2069). C0+DEL alone was not
# enough: U+009B is a single-character CSI, so on a terminal that honours C1 it
# is equivalent to ESC[ and reinstates exactly the row-spoofing primitive this
# function exists to stop, and U+202E reverses displayed text so a refusal can
# be made to read as something else. Both are reachable from an attacker-chosen
# filename under ./.kiro/agents/ and from registry-derived text.
#
# `tr` cannot do this: it works on BYTES, so deleting \200-\237 in the C locale
# would shred the continuation bytes of every multi-byte character (this repo's
# own output is partly Korean). python3 filters by CODE POINT instead. Because
# this runs on a probe's FAILURE path it must never fail itself:
#   * invalid UTF-8 decodes with U+FFFD replacement instead of raising (and a
#     lone C1 byte in such input is replaced, not passed through),
#   * python3 absent/erroring falls back to the old byte-level tr — a narrower
#     filter, but a swallowed error message would be its own defect. That
#     fallback is pinned to LC_ALL=C: measured, BSD tr in a UTF-8 locale aborts
#     with "Illegal byte sequence" on invalid input and TRUNCATES the message at
#     the offending byte. In C the same two byte ranges are filtered, multi-byte
#     text (all bytes >= 0x80) is untouched, and nothing aborts.
SANITIZE_FILTER='
import sys
bad = set(range(0x00, 0x20)) | {0x7f} | set(range(0x80, 0xa0)) \
    | {0x200e, 0x200f} | set(range(0x202a, 0x202f)) | set(range(0x2066, 0x206a))
text = sys.stdin.buffer.read().decode("utf-8", "replace")
sys.stdout.buffer.write(
    "".join("?" if ord(ch) in bad else ch for ch in text).encode("utf-8", "replace"))
'
if command -v python3 >/dev/null 2>&1; then SANITIZE_PY=1; else SANITIZE_PY=0; fi

sanitize() {
    local out=""
    if [[ $SANITIZE_PY -eq 1 ]]; then
        out="$(printf '%s' "$1" | python3 -c "$SANITIZE_FILTER" 2>/dev/null)"
        # The filter substitutes and never deletes, so nonempty-in/empty-out can
        # only mean python3 itself failed: fall through instead of blanking.
        if [[ -n "$out" || -z "$1" ]]; then
            printf '%s' "$out"
            return 0
        fi
    fi
    printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '[?*]'
}

# emit_capture — the probe's own output, prefixed, with control characters
# removed (TAB and LF kept so multi-line CLI output stays readable).
emit_capture() {
    tr -d '\000-\010\013-\037\177' < "$OUT" | sed -e 's/^/kiro-preflight:   /' >&2
}

[[ "$PROBE_TIMEOUT_S" =~ ^[0-9]+$ ]] || {
    echo "kiro-preflight: KIRO_PREFLIGHT_TIMEOUT_S is not numeric ('$(sanitize "$PROBE_TIMEOUT_S")') — the watchdog would never fire, refusing" >&2
    exit 7
}

# (d) Registry-derived argv. jq is the same parser call-worker.sh uses; without
# it the probe REFUSES rather than guessing a binary or a profile name.
command -v jq >/dev/null 2>&1 || {
    echo "kiro-preflight: jq is required to resolve lane '$(sanitize "$LANE")' from the backends registry — refusing rather than guessing the dispatch argv (brew install jq / apt install jq)" >&2
    exit 7
}
[[ -f "$REGISTRY" ]] || {
    echo "kiro-preflight: backends registry not found: $(sanitize "$REGISTRY") — refusing" >&2
    exit 7
}

# One jq pass, TAB-separated tagged lines. Control chars are replaced INSIDE jq
# so a crafted registry cannot inject an extra line into this protocol.
REG_OUT=""
reg_rc=0
REG_OUT="$(jq -r --arg lane "$LANE" '
    def sane: gsub("[[:cntrl:]]"; "?");
    ((.backends // {})[$lane]) as $b
    | if $b == null then "err\tlane is not defined in the registry"
      elif ($b | type) != "object" then "err\tbackend entry is not an object"
      else
        ( ($b.cmd // [])
          | if (type == "array") and (length > 0)
               and ((.[0] | type) == "string") and (.[0] != "")
            then (.[] | if type == "string" then "cmd\t" + sane else "err\tcmd contains a non-string element" end)
            else "err\tcmd[0] is not a nonempty string" end ),
        ( ($b.tier_args // {})
          | if type == "object"
            then ( to_entries[] | .key as $t | .value
                   | if type == "array"
                     then ( . as $a | range(0; ($a | length)) as $i
                            | select($a[$i] == "--agent")
                            | select(($i + 1) < ($a | length))
                            | select(($a[$i + 1] | type) == "string")
                            | select($a[$i + 1] != "")
                            | "prof\t" + ($t | sane) + "\t" + ($a[$i + 1] | sane) )
                     else empty end )
            else "err\ttier_args is not an object" end )
      end
' "$REGISTRY" 2>&1)" || reg_rc=$?
if [[ $reg_rc -ne 0 ]]; then
    echo "kiro-preflight: backends registry unreadable ($(sanitize "$REGISTRY")): $(sanitize "$(printf '%s' "$REG_OUT" | head -1)") — refusing" >&2
    exit 7
fi

CMD=()
PROF_LOW="" PROF_MID="" PROF_TOP="" PROF_ANY=""
while IFS=$'\t' read -r tag f1 f2; do
    case "$tag" in
        cmd)  CMD+=("$f1") ;;
        prof) case "$f1" in
                  LOW) [[ -n "$PROF_LOW" ]] || PROF_LOW="$f2" ;;
                  MID) [[ -n "$PROF_MID" ]] || PROF_MID="$f2" ;;
                  TOP) [[ -n "$PROF_TOP" ]] || PROF_TOP="$f2" ;;
              esac
              [[ -n "$PROF_ANY" ]] || PROF_ANY="$f2" ;;
        err)  echo "kiro-preflight: lane '$(sanitize "$LANE")' in $(sanitize "$REGISTRY") is unusable: $f1 — refusing (the dispatch argv cannot be reproduced)" >&2
              exit 7 ;;
    esac
done <<< "$REG_OUT"

[[ ${#CMD[@]} -gt 0 ]] || {
    echo "kiro-preflight: lane '$(sanitize "$LANE")' yielded no dispatch argv from $(sanitize "$REGISTRY") — refusing" >&2
    exit 7
}
CLI="${CMD[0]}"

# Cheapest first: a probe is a real billable call, so it rides the lane's LOW
# profile when one exists (README § Cost of a preflight). MID/TOP only when the
# lane has no LOW tier; --model only when the lane pins no profile at all, in
# which case --agent resolution is genuinely not part of this lane's path.
PROBE_PROFILE="${PROF_LOW:-${PROF_MID:-${PROF_TOP:-$PROF_ANY}}}"
if [[ -n "$PROBE_PROFILE" ]]; then
    RESOLUTION_ARGS=("--agent" "$PROBE_PROFILE")
else
    RESOLUTION_ARGS=("--model" "$PROBE_MODEL")
fi

command -v "$CLI" >/dev/null 2>&1 || {
    echo "kiro-preflight: gateway CLI '$(sanitize "$CLI")' (cmd[0] of lane '$(sanitize "$LANE")') not found on PATH" >&2
    exit 1
}

# (e) Defense in depth — see the header. Deliberately broad: ANY
# ./.kiro/agents/kiro-*.json is treated as hostile, because this probe does not
# know which profile name the pending dispatch will request.
shadow_dir="./.kiro/agents"
if [[ -d "$shadow_dir" ]]; then
    shadows=""
    for f in "$shadow_dir"/kiro-*.json; do
        [[ -e "$f" ]] || continue          # bash 3.2: unmatched glob stays literal
        shadows="$shadows $(sanitize "$f")"
    done
    if [[ -n "$shadows" ]]; then
        echo "kiro-preflight: refusing — workspace agent profile(s) would shadow the installed read-only ones:$shadows" >&2
        echo "kiro-preflight: '--agent <name>' resolves ./.kiro/agents before ~/.kiro/agents, so these would replace the framework's profiles (model pin AND tool restrictions). Dispatch from a directory without them, or remove them if they are yours." >&2
        exit 2
    fi
fi

OUT="$(mktemp)" || { echo "kiro-preflight: mktemp failed — refusing rather than probing blind" >&2; exit 6; }
[[ -n "$OUT" && -f "$OUT" ]] || { echo "kiro-preflight: mktemp returned an unusable path — refusing" >&2; exit 6; }
trap 'rm -f "$OUT"' EXIT INT TERM

# (a)+(b)+(c)+(d) Real authenticated round trip over the dispatch argv.
# Portable watchdog (macOS ships no GNU timeout), same shape as call-worker.sh.
"${CMD[@]}" "${RESOLUTION_ARGS[@]}" "$PROBE_PROMPT" </dev/null >"$OUT" 2>&1 &
probe_pid=$!
( sleep "$PROBE_TIMEOUT_S" && kill -KILL "$probe_pid" 2>/dev/null ) &
watchdog_pid=$!
probe_rc=0
wait "$probe_pid" || probe_rc=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

# 137 = KILLed by our watchdog; the CLI does not exit 137 on its own here.
if [[ $probe_rc -eq 137 ]]; then
    echo "kiro-preflight: probe timed out after ${PROBE_TIMEOUT_S}s — refusing" >&2
    exit 4
fi

# Auth-failure text is checked FIRST because the CLI has been observed printing
# it while still exiting 0 (hole (a)) — status alone would let it through.
# "expired" is only an auth signal when it is a CREDENTIAL that expired: a bare
# /expired/ alternative fired on any healthy reply containing the word (e.g. "the
# trial expired last year"), reporting an auth failure that did not happen.
if grep -qiE 'not logged in|please log in|log ?in with|unauthorized|forbidden|access denied|authentication failed|invalid.*(api.?key|credential|token)|(api.?key|credential|token|session|login|subscription|sign.?in)[^.]{0,40}(expired|has expired)|expired[^.]{0,20}(api.?key|credential|token|session|login|subscription)' "$OUT"; then
    echo "kiro-preflight: the CLI reports an authentication failure — refusing" >&2
    emit_capture
    exit 3
fi

# FAIL CLOSED on every other nonzero exit. An earlier revision only inspected
# 137 and otherwise fell through to `exit 0`, so a TLS error, a service outage,
# a malformed config or a panic all passed as "authenticated" and the paid
# dispatch went ahead. Anything nonzero now refuses.
if [[ $probe_rc -ne 0 ]]; then
    echo "kiro-preflight: probe exited $probe_rc — refusing (state unknown)" >&2
    emit_capture
    exit 5
fi

# (c) POSITIVE proof of inference: the reply must carry the token the prompt
# asked for. Empty output, a banner, "insufficient credits", a usage dump — all
# exit 0 paths that carry no token, and all refusals. Matched against an
# ANSI-stripped copy because the CLI decorates its output heavily.
if ! sed -e 's/'$'\033''\[[0-9;?]*[a-zA-Z]//g' "$OUT" | grep -Fq "$PROBE_TOKEN"; then
    echo "kiro-preflight: probe exited 0 but the reply does not contain the requested token ($PROBE_TOKEN) — no proof of inference, refusing" >&2
    emit_capture
    exit 5
fi

exit 0
