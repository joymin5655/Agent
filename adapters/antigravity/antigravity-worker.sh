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
# AUTH: by default agy authenticates from the OS keyring, seeded once
# interactively (this machine's was already seeded — see
# adapters/antigravity/README.md). The worker never logs in; a dead credential is
# the preflight's problem (fail closed).
# OPT-IN API KEY: ANTIGRAVITY_AUTH=apikey reads a Gemini API key from the macOS
# Keychain (service gemini-api-key — same pattern as the retired OpenRouter worker) and
# exports GEMINI_API_KEY for agy ONLY through the environment: never argv, never
# logged, never in an error message. agy also needs "modelProvider": "gemini" in
# ~/.gemini/antigravity-cli/settings.json for the variable to take effect — the
# worker warns when it is absent and never edits that file. Any other
# ANTIGRAVITY_AUTH value keeps the keyring path and never calls `security`.
# The worker also exports AGENT_ANTIGRAVITY_WORKER=1 so the harness hook adapter
# can tell it is running under a review worker (deny-all tools).
# ARGON: model ids containing "argon" (any case) are separately metered and are refused
# (exit 2, agy never invoked) if any string in .model or anywhere under .tiers contains it,
# even in a tier this call does not use. A tiers file that is not exactly one JSON object
# of the expected shape, or a jq failure during the scan, also refuses (fail closed).
# Pin a flash id instead.
#
# THREAT MODEL: the prompt carries an untrusted diff (an outside-contributor PR
# is the lane's normal input), so a prompt can try to drive local action.
# 1.1.14 posture (historical, measured 2026-08-19): shell exec was denied by default
# and no probe created a file. On 1.2.12 that fail-closed-by-default posture is NOT
# assumed: an `echo` via run_command ran headless with no allow rule (README "Worker
# threat model (drift from 1.1.14)"). The controls that hold are (a) the OS
# sandbox-exec profile below (deny-write outside WORK_DIR and the agy state dir, with
# the hook/plugin config paths carved back out; deny-read of credential stores;
# network stays open), (b) a workspace deny plugin written into WORK_DIR before agy
# starts — a static tool-allowlist hook (PreToolUse matcher ".*", no env or adapter
# dependence) — and (c) the ban on --dangerously-skip-permissions. A code review needs
# neither write nor exec nor any other tool (it reads the diff from the prompt and emits
# findings text), so in the default review mode the hook denies EVERY tool call, local
# reads and web search included (measured on agy 1.5.2, 2026-11-07: a hook deny does not
# end the run and leaves no trace in denied_actions or the soft-deny notice, so the
# success checks below are unaffected). With --web the hook answers "ask" — agy's own
# permission rules decide; the hook never says "allow" — for exactly search_web, read from
# .toolCall.name with jq called by the absolute path resolved at write time, and denies
# everything else (any other name, no name, no toolCall, unparseable input, jq failure).
# URL reads (read_url_content, read_url) are OFF: they are unmeasured and the hook cannot
# restrict their URL argument, so a prompt-injected page could aim them at localhost or a
# private-network address while the sandbox keeps the network open (README "Unmeasured").
# --web therefore opens web search only, never page reads and never local files. Right after
# the plugin is written the worker runs the hook once with search_web (must answer "ask")
# and once with run_command (must deny); anything else refuses to start (exit 2).
# sandbox-exec is fail-closed: no sandbox-exec => refuse (unless the opt-out is set).
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
# notice on stderr (docs/cli/headless). agy's own --print-timeout exits 0 too.
# So a dispatch counts only when the --output-format json envelope says status
# "SUCCESS" with a non-blank string response AND no soft-deny notice was printed
# AND no print-timeout notice starts a line in the last 20 stderr lines; the
# envelope and stderr are forwarded unchanged either way.
# agy 1.2.12 (measured 2026-09-29) reports a soft-deny structurally — the
# envelope gains a non-empty "denied_actions" array and the run ends at the first
# denial — so that is the primary signal. The stderr notice (wording differs
# between 1.1.14 and 1.2.12) is the fallback, matched by SOFT_DENY_RE.
#
# usage: antigravity-worker [--tier mid|top] [--web] < prompt.md
#        flags in any order, each at most once; anything else exits 2 before stdin is read
# env:   ANTIGRAVITY_TIERS_FILE, ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1,
#        ANTIGRAVITY_WORKER_PRINT_TIMEOUT (agy --print-timeout, default 14m: under the
#        gemini lane's 900s timeout_s, so agy ends the run before the hard kill),
#        ANTIGRAVITY_AUTH=apikey (opt-in Keychain API key, see AUTH)
# exit:  agy's own nonzero exit code (incl. the undocumented 3 = envelope status
#        ERROR); 2 usage/config (incl. a missing Keychain item); 6 mktemp failure;
#        7 sandbox unavailable (fail closed); 8 unsafe $HOME for a scheme string;
#        9 agy exited 0 but soft-denied a tool call; 10 agy exited 0 but the
#        envelope is unparseable, its status is not SUCCESS, or its response is
#        not a non-blank string; 75 quota / rate limit
#        (HTTP 429, RESOURCE_EXHAUSTED, quota, rate limit in stderr or the
#        envelope's .error) — EX_TEMPFAIL, call-worker records `rate-limited`;
#        124 agy exited 0 with a SUCCESS envelope after its own --print-timeout
#        notice — call-worker records `timeout`
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

# Strict arguments: [--tier mid|top] [--web], any order, each at most once. Anything else
# (unknown flag, positional word, repeated flag, missing value) exits 2 before stdin is
# read or agy is touched.
usage() { echo "usage: antigravity-worker [--tier mid|top] [--web] < prompt.md${1:+ ($1)}" >&2; exit 2; }
TIER=""
WEB=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier)
            [[ -z "$TIER" ]] || usage "--tier given twice"
            [[ $# -ge 2 ]] || usage "--tier needs mid or top"
            case "$2" in mid|top) TIER="$2" ;; *) usage "--tier must be mid or top, got '$2'" ;; esac
            shift 2 ;;
        --web)
            [[ $WEB -eq 0 ]] || usage "--web given twice"
            WEB=1; shift ;;
        *) usage "unexpected argument '$1'" ;;
    esac
done
TIER="${TIER:-mid}"

command -v jq >/dev/null 2>&1 || { echo "antigravity-worker: jq is required to read the tiers file" >&2; exit 2; }
# Web mode bakes jq's ABSOLUTE path into the hook (the hook never trusts PATH or env). The
# path lands inside a single-quoted shell word: allowlist, never escape.
JQ_BIN="$(command -v jq)"
if [[ $WEB -eq 1 && ! "$JQ_BIN" =~ ^/[A-Za-z0-9._/+=@%-]+$ ]]; then
    echo "antigravity-worker: jq resolves to '$JQ_BIN', which is not an absolute path of safe characters — refusing --web (the web hook needs it)" >&2
    exit 2
fi
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

# Argon ids are separately metered: refuse ANY of them anywhere in the tiers file (the
# base .model and every string under .tiers), even in a tier this call does not use, so a
# later --tier top cannot reach one. Fail closed twice: the file must first be exactly one
# JSON object of the expected shape (so no unused slot can hide a value the scan skips),
# and any jq status other than the two expected results refuses. Other keys (a "comment")
# are allowed and never scanned. Runs before any model resolution; agy is never invoked.
if ! jq -es 'length == 1 and (.[0] | type) == "object"
             and ((.[0] | has("model") | not) or (.[0].model | type) == "string")
             and ((.[0] | has("tiers") | not)
                  or ((.[0].tiers | type) == "object"
                      and (.[0].tiers | all(.[]; type == "array" and all(.[]; type == "string")))))' \
        "$TIERS_FILE" >/dev/null 2>&1; then
    echo "antigravity-worker: tiers file $TIERS_FILE is malformed — it must be exactly one JSON object, .model a string, .tiers an object of arrays of strings" >&2
    exit 2
fi
argon_rc=0
jq -e '[.model // empty, (.tiers // {} | .[] | .[])] | map(ascii_downcase | contains("argon")) | any' \
    "$TIERS_FILE" >/dev/null 2>&1 || argon_rc=$?
case $argon_rc in
    0) echo "antigravity-worker: Argon ids are not accepted — separately metered; pin a flash id ($TIERS_FILE)" >&2
       exit 2 ;;
    1) ;;
    *) echo "antigravity-worker: could not check the tiers file for Argon ids ($TIERS_FILE) — refusing" >&2
       exit 2 ;;
esac

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

PRINT_TIMEOUT="${ANTIGRAVITY_WORKER_PRINT_TIMEOUT:-14m}"

if [[ "${ANTIGRAVITY_AUTH:-}" == "apikey" ]]; then
    command -v security >/dev/null 2>&1 || { echo "antigravity-worker: ANTIGRAVITY_AUTH=apikey needs the macOS 'security' CLI to read Keychain service 'gemini-api-key' — not found on PATH" >&2; exit 2; }
    GEMINI_KEY="$(security find-generic-password -a "${USER:-$(id -un)}" -s gemini-api-key -w 2>/dev/null)" || GEMINI_KEY=""
    [[ -n "$GEMINI_KEY" ]] || {
        echo "antigravity-worker: no Keychain entry 'gemini-api-key' — register: security add-generic-password -a \"\$USER\" -s gemini-api-key -w" >&2
        exit 2
    }
    # Exported only after the workspace deny plugin is written (see below): with the key
    # in agy's environment, a prompt-injected run_command could otherwise read it.
    if ! jq -e '.modelProvider == "gemini"' "$HOME/.gemini/antigravity-cli/settings.json" >/dev/null 2>&1; then
        echo "antigravity-worker: WARNING ANTIGRAVITY_AUTH=apikey but $HOME/.gemini/antigravity-cli/settings.json does not set \"modelProvider\": \"gemini\" — GEMINI_API_KEY has no effect until it does (this worker never edits that file)" >&2
    fi
fi
export AGENT_ANTIGRAVITY_WORKER=1

# $HOME is interpolated into the SBPL scheme string; a value containing scheme
# metacharacters could widen the profile. Refuse rather than emit a profile
# whose meaning we can't vouch for.
case "$HOME" in
    *'"'*|*'('*|*')'*|*'\'*) echo "antigravity-worker: \$HOME contains a scheme metacharacter — refusing to build a sandbox profile" >&2; exit 8 ;;
esac

WORK_DIR="$(mktemp -d)" || { echo "antigravity-worker: mktemp -d failed" >&2; exit 6; }
PROMPT_FILE="$WORK_DIR/prompt.md"   # inside WORK_DIR so cleanup takes it too
cat > "$PROMPT_FILE"

# Workspace tool-allowlist plugin (agy loads .agents/plugins/<name>/ from its cwd — measured on
# 1.2.12, w5-design M1; still loads on 1.5.2, 2026-11-07). The PreToolUse matcher ".*" catches
# every tool call and the hook is a static script that decides only from what was baked into
# it at write time — never from environment variables, never needing the adapter or the
# global plugin. Review mode (default): every tool call is denied. Web mode (--web): only
# search_web answers "ask" (agy's own permission rules decide — the hook never answers
# "allow"); everything else, including both URL tools and unparseable input, is denied.
# Fail closed: a worker that cannot write it refuses to start, and never gets the API key.
DENY_DIR="$WORK_DIR/.agents/plugins/agent-worker-deny"
write_deny_plugin() {
    # The path lands inside a double-quoted shell word in hooks.json: allowlist, never escape.
    [[ "$WORK_DIR" =~ ^[A-Za-z0-9._/+=@%-]+$ ]] || return 1
    mkdir -p "$DENY_DIR" || return 1
    if [[ $WEB -eq 1 ]]; then
        cat > "$DENY_DIR/deny.sh" <<'WEBSH' || return 1
#!/bin/sh
# web worker: only web search may reach agy's own permission rules ("ask"); URL reads are off.
# Only .toolCall.name counts (an args payload naming a tool changes nothing); any failure denies.
if [ "${1:-}" = Stop ]; then cat >/dev/null; printf '%s\n' '{"decision":"stop"}'; exit 0; fi
verdict=$(@JQ@ -r 'if (.toolCall | type) == "object" and (.toolCall.name | type) == "string" and (.toolCall.name | IN("search_web")) then "ask" else "deny" end' 2>/dev/null) || verdict=deny
if [ "$verdict" = ask ]; then
    printf '%s\n' '{"decision":"ask"}'
else
    printf '%s\n' '{"decision":"deny","reason":"web worker: only web search is allowed"}'
fi
WEBSH
        # Bake in jq's absolute path (allowlisted above) as a single-quoted word.
        local body q="'"
        body="$(<"$DENY_DIR/deny.sh")" || return 1
        printf '%s\n' "${body//@JQ@/$q$JQ_BIN$q}" > "$DENY_DIR/deny.sh" || return 1
    else
        cat > "$DENY_DIR/deny.sh" <<'REVSH' || return 1
#!/bin/sh
# review worker: every tool call is denied; nothing may keep the run going.
cat >/dev/null
case "${1:-}" in
    Stop) printf '%s\n' '{"decision":"stop"}' ;;
    *)    printf '%s\n' '{"decision":"deny","reason":"review worker: tools are disabled"}' ;;
esac
REVSH
    fi
    chmod +x "$DENY_DIR/deny.sh" || return 1
    local desc="Antigravity review worker: denies every tool call."
    [[ $WEB -eq 1 ]] && desc="Antigravity web worker: only web search reaches agy's permission rules; every other tool call is denied."
    cat > "$DENY_DIR/plugin.json" <<PLUGINJSON || return 1
{
  "name": "agent-worker-deny",
  "description": "$desc"
}
PLUGINJSON
    cat > "$DENY_DIR/hooks.json" <<HOOKSJSON || return 1
{
  "agent-worker-deny": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [{"type": "command", "command": "\"$DENY_DIR/deny.sh\" PreToolUse", "timeout": 10}]
      }
    ],
    "Stop": [{"type": "command", "command": "\"$DENY_DIR/deny.sh\" Stop", "timeout": 10}]
  }
}
HOOKSJSON
}
if ! write_deny_plugin; then
    rm -rf "$WORK_DIR"
    echo "antigravity-worker: could not write the workspace deny plugin — refusing to start (the worker relies on it to deny tool calls); no API key was exported" >&2
    exit 2
fi
if [[ $WEB -eq 1 ]]; then
    # Self-test the generated web hook: a jq too old for the expression (or broken) would
    # make it deny everything, or worse answer something unintended. Fail closed.
    if [[ "$(printf '%s' '{"toolCall":{"name":"search_web"}}' | "$DENY_DIR/deny.sh" PreToolUse 2>/dev/null)" != '{"decision":"ask"}' ]] \
       || [[ "$(printf '%s' '{"toolCall":{"name":"run_command"}}' | "$DENY_DIR/deny.sh" PreToolUse 2>/dev/null)" != '{"decision":"deny",'* ]]; then
        rm -rf "$WORK_DIR"
        echo "antigravity-worker: web hook self-test failed — jq too old or broken?" >&2
        exit 2
    fi
fi
if [[ -n "${GEMINI_KEY:-}" ]]; then
    export GEMINI_API_KEY="$GEMINI_KEY"
    unset GEMINI_KEY
fi

# Flags BEFORE the positional prompt (measured: flags after -p are misparsed).
# --dangerously-skip-permissions is NEVER present. --output-format json gives
# call-worker the status/response envelope; --print-timeout caps a hung run.
CMD=(agy --model "$MODEL")
[[ -n "$EFFORT" ]] && CMD+=(--effort "$EFFORT")
CMD+=(--output-format json --print-timeout "$PRINT_TIMEOUT"
      -p "$(cat "$PROMPT_FILE")")

if command -v sandbox-exec >/dev/null 2>&1; then
    # Deny writes outside this run's WORK_DIR and the agy state dir; deny reads
    # of the obvious credential stores so a prompt-driven exfil finds nothing. The
    # agy hook/plugin config (config/hooks.json, config/plugins, settings.json) is
    # carved back out of the writable ~/.gemini: a planted hook there would run
    # unsandboxed in the user's next interactive agy. antigravity-cli/settings.json
    # stays writable because agy rewrites it itself (permissions.allow could still
    # be widened by an injected write; unmeasured whether agy runs without it).
    # Network + process-exec stay open: agy needs the vendor API, and denying
    # process-exec blocks the CLI's own launch. Later matching SBPL rule wins.
    SBPROF='(version 1)(allow default)
(deny file-write*)
(allow file-write* (subpath "'"$WORK_DIR"'") (subpath "'"$HOME"'/.gemini") (subpath "'"$HOME"'/.antigravity") (subpath "/dev"))
(deny file-write* (literal "'"$HOME"'/.gemini/config/hooks.json") (subpath "'"$HOME"'/.gemini/config/plugins") (literal "'"$HOME"'/.gemini/settings.json"))
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

# Quota / rate-limit detection (EX_TEMPFAIL 75, the adapter contract
# call-worker.sh maps to `rate-limited`) so the lane is recorded `rate-limited`,
# not `failed` (observed 2026-10-07: a gemini 429 captured as failed). A false match
# turns a hard failure into a fail-open lane, so only quota-specific phrases with
# non-alphanumeric boundaries count — never bare "quota", "rate limit" or "429"
# ("disk quota exceeded", "separate limits", "took 0.429s" must stay failures).
# Scope: on a nonzero exit, the LAST 20 stderr lines (agy may echo prompt/diff
# text earlier) plus the envelope's .error; on exit 0 with a non-SUCCESS
# envelope, .error only. Never .response (the model's own text). Watchdog kills
# (124/137/143) are excluded: a timeout must not be reclassified.
QB='(^|[^[:alnum:]_])'
QE='([^[:alnum:]_]|$)'
QUOTA_RE="${QB}(RESOURCE_EXHAUSTED|too many requests|(gemini|http|https|status|code|error)[^[:alnum:]]{0,4}429${QE}|https?/[0-9.]+[[:space:]]+429${QE}|429[^[:alnum:]]{1,3}too many|quota[^[:alnum:]]+(exceeded|exhausted)|exceeded[^[:alnum:]]+((your|the)[^[:alnum:]]+)?quota|rate[ _-]?limit(ed|[ _-]+(exceeded|reached|hit))|usage limit[ _-]+(reached|exceeded))"
# is_quota_error <stderr|envelope>: "stderr" also scans the stderr tail.
is_quota_error() {
    local scope="$1" blob env_err rcm=1
    env_err="$(jq -rs 'if length == 1 then (.[0].error // "" | tostring) else "" end' "$CAP_DIR/out" 2>/dev/null || true)"
    blob="$env_err"
    [[ "$scope" == "stderr" ]] && blob="$(tail -n 20 "$CAP_DIR/err")"$'\n'"$env_err"
    # "disk quota" is a filesystem condition, not a vendor quota: drop it first.
    blob="$(printf '%s' "$blob" | sed -E 's/[Dd][Ii][Ss][Kk][ _-]+[Qq][Uu][Oo][Tt][Aa]//g')"
    shopt -s nocasematch
    [[ "$blob" =~ $QUOTA_RE ]] && rcm=0
    shopt -u nocasematch
    return $rcm
}
if [[ $rc -ne 0 && $rc -ne 124 && $rc -ne 137 && $rc -ne 143 ]] && is_quota_error stderr; then
    echo "antigravity-worker: agy reported a quota / rate-limit error (exit $rc) — exiting 75 (EX_TEMPFAIL)" >&2
    exit 75
fi
[[ $rc -eq 0 ]] || exit "$rc"

SOFT_DENY_RE='permission check failed|denied permission to|auto-denied|cannot prompt for'
err_text="$(<"$CAP_DIR/err")"
# -s + length==1 mirrors the status check below: only a single json value counts.
denied_n="$(jq -rs 'if length == 1 then ((.[0].denied_actions // []) | length) else 0 end' "$CAP_DIR/out" 2>/dev/null || true)"
denied=0
[[ "$denied_n" =~ ^[0-9]+$ && "$denied_n" -gt 0 ]] && denied=1
shopt -s nocasematch
if [[ $denied -eq 1 || "$err_text" =~ $SOFT_DENY_RE ]]; then
    echo "antigravity-worker: agy exited 0 but soft-denied a tool call (notice above) — result is incomplete; not reporting success" >&2
    exit 9
fi
shopt -u nocasematch
# -s: the whole stdout must be exactly ONE json value — trailing text fails.
status="$(jq -rs 'if length == 1 then (.[0].status // empty) else empty end' "$CAP_DIR/out" 2>/dev/null || true)"
if [[ "$status" != "SUCCESS" ]]; then
    if is_quota_error envelope; then
        echo "antigravity-worker: agy exited 0 but the envelope reports a quota / rate-limit error — exiting 75 (EX_TEMPFAIL)" >&2
        exit 75
    fi
    echo "antigravity-worker: agy exited 0 but the json envelope status is '${status:-<unparseable>}', not SUCCESS — not reporting success" >&2
    exit 10
fi
# agy's own --print-timeout also exits 0 with a SUCCESS envelope, its response
# empty or cut short (measured 2026-10-11..25: 13 timed-out runs recorded complete,
# the notice always the last stderr line). Checked only past the SUCCESS gate so a
# soft-deny, quota or bad status keeps its code; 124 makes call-worker record
# `timeout`. Same last-20-lines scope as the quota scan, never .response.
if grep -Eq '^\[agy\] print timeout after ' <(tail -n 20 "$CAP_DIR/err"); then
    echo "antigravity-worker: agy hit its own --print-timeout (notice above) — the response is partial or empty; exiting 124 (timeout)" >&2
    exit 124
fi
# Every role's contract returns text. call-worker's own blank check cannot see
# an empty answer here: it merges stderr, so any notice makes its capture non-blank.
has_text="$(jq -rs 'if length == 1 and (.[0].response | type) == "string" then (.[0].response | test("[^[:space:]]")) else false end' "$CAP_DIR/out" 2>/dev/null || true)"
if [[ "$has_text" != "true" ]]; then
    echo "antigravity-worker: agy exited 0 with a SUCCESS envelope but no text response — not reporting success" >&2
    exit 10
fi
exit 0
