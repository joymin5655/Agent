#!/usr/bin/env bash
# openrouter-worker.sh — stdin->HTTP bridge for the OpenRouter free-tier
# advisory lane.
#
# Unlike adapters/grok/ and adapters/gemini/ (wrapped agentic CLIs with a
# live local `shell` tool, needing an OS sandbox), this lane is a direct
# HTTPS call to OpenRouter's chat-completions API — there is no local tool
# for a prompt to drive. The real risk here is DATA, not code execution: a
# `:free` OpenRouter route is served by an upstream model whose provider is
# often anonymous and explicitly documented to retain and/or train on
# prompts/responses. So this worker enforces two things instead of a
# sandbox:
#   (1) a SENSITIVE-CWD GUARD — refuse to dispatch when the caller's working
#       directory is under a path listed in the shared, locally-owned
#       ~/.config/agent-harness/sensitive-paths file (installed from
#       sensitive-paths.template — generic defaults only; personal entries
#       are added locally, never committed). AGENT_OPENROUTER_FORCE=1 is the
#       explicit, warned override.
#   (2) a RETENTION WARNING printed on every dispatch, so the caller cannot
#       miss what "free" costs here.
#
# Credential: macOS Keychain service "openrouter-api-key" (same service the
# personal adapters/claude-code/launchers/claude-ox gateway launcher uses).
# The key is NEVER placed in argv (visible to other local users via `ps`) or
# logged — it is written into a private curl config file (`-K`, not `-H` on
# the command line) inside this run's private WORK_DIR and removed with it.
#
# Tier policy: model IDs are forbidden in core/infra/backends.json
# (no-model-ids gate), so the model pin per tier lives in a tiers file THIS
# adapter owns: $OPENROUTER_TIERS_FILE > ~/.openrouter/agent-tiers.json > the
# shipped template. Each tier (LOW/MID/TOP) pins its own model — unlike
# grok's single model + per-tier CLI flags, an HTTP `:free` lane has no
# reasoning-effort flag to vary; a different tier can mean a different model.
#
# usage: openrouter-worker [--tier low|mid|top] < prompt.md
# env:   OPENROUTER_TIERS_FILE, OPENROUTER_SENSITIVE_PATHS_FILE,
#        AGENT_OPENROUTER_FORCE=1, OPENROUTER_WORKER_TIMEOUT_S (default 280)
# exit:  0 ok
#        2 usage/config (bad --tier, tiers file missing a model pin)
#        4 no/invalid Keychain credential (fail-closed)
#        6 mktemp failure
#        9 sensitive-cwd refusal (AGENT_OPENROUTER_FORCE=1 overrides)
#        75 HTTP 429 rate-limited (EX_TEMPFAIL — fail-open signal, mirrors
#           grok's usage-limit contract; core/infra/call-worker.sh already
#           maps this to status: rate-limited)
#        1 any other request/transport failure
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

TIER="mid"
if [[ "${1:-}" == "--tier" ]]; then
    TIER="${2:-}"
    case "$TIER" in low|mid|top) ;; *) echo "openrouter-worker: --tier must be low, mid, or top (got '$TIER')" >&2; exit 2 ;; esac
fi
TIER_KEY="$(printf '%s' "$TIER" | tr '[:lower:]' '[:upper:]')"

command -v jq >/dev/null 2>&1 || { echo "openrouter-worker: jq is required to read the tiers file" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "openrouter-worker: curl is required" >&2; exit 2; }
command -v security >/dev/null 2>&1 || { echo "openrouter-worker: 'security' (macOS Keychain) not found — this worker requires macOS" >&2; exit 4; }

TIERS_FILE="${OPENROUTER_TIERS_FILE:-$HOME/.openrouter/agent-tiers.json}"
[[ -f "$TIERS_FILE" ]] || TIERS_FILE="$SELF_DIR/openrouter-tiers.json.template"
[[ -f "$TIERS_FILE" ]] || { echo "openrouter-worker: no tiers file (looked at ~/.openrouter/agent-tiers.json and the shipped template)" >&2; exit 2; }

MODEL="$(jq -r --arg t "$TIER_KEY" '.tiers[$t].model // empty' "$TIERS_FILE")"
[[ -n "$MODEL" ]] || { echo "openrouter-worker: tiers file $TIERS_FILE pins no model for tier $TIER_KEY" >&2; exit 2; }

# --- sensitive-cwd guard ---------------------------------------------------
# Same shape adapters/claude-code/launchers/claude-ox.template uses, generalized
# to a shared, locally-owned file so both consumers stay in sync.
# An EXPLICIT OPENROUTER_SENSITIVE_PATHS_FILE is honored strictly — absent or
# empty means fail closed below, never a silent fall-back to the template
# (that fall-back was an unaudited bypass; security review 2026-08-25). Only
# the DEFAULT location falls back to the shipped template.
if [[ -n "${OPENROUTER_SENSITIVE_PATHS_FILE:-}" ]]; then
    SENSITIVE_FILE="$OPENROUTER_SENSITIVE_PATHS_FILE"
else
    SENSITIVE_FILE="$HOME/.config/agent-harness/sensitive-paths"
    [[ -f "$SENSITIVE_FILE" ]] || SENSITIVE_FILE="$SELF_DIR/sensitive-paths.template"
fi
# FAIL CLOSED when no guard file resolves at all (security review 2026-08-25):
# a data-egress lane with a silently absent blocklist is a guard that lies.
# OPENROUTER_SENSITIVE_PATHS_FILE=/dev/null is likewise not a quiet bypass —
# the documented override is AGENT_OPENROUTER_FORCE=1, which announces itself.
if [[ ! -s "$SENSITIVE_FILE" && "${AGENT_OPENROUTER_FORCE:-0}" != "1" ]]; then
    echo "openrouter-worker: refusing — no sensitive-paths guard file resolves (looked at \$OPENROUTER_SENSITIVE_PATHS_FILE, ~/.config/agent-harness/sensitive-paths, shipped template); run setup.sh --openrouter, or override explicitly: AGENT_OPENROUTER_FORCE=1" >&2
    exit 9
fi
if [[ "${AGENT_OPENROUTER_FORCE:-0}" == "1" ]]; then
    echo "openrouter-worker: NOTICE — AGENT_OPENROUTER_FORCE=1: sensitive-cwd guard overridden for this dispatch" >&2
else
    CWD="$(pwd -P)"
    echo "openrouter-worker: cwd guard source: $SENSITIVE_FILE" >&2
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        case "$line" in
            "~") line="$HOME" ;;
            "~/"*) line="$HOME/${line#\~/}" ;;
        esac
        # a trailing slash would silently disable both match arms ("$line"/*
        # becomes path//*): strip it (never the root slash itself)
        while [[ "$line" == */ && "$line" != / ]]; do line="${line%/}"; done
        # canonicalize through the same producer as CWD (pwd -P) so a
        # blocklist entry that is (or sits behind) a symlink still matches;
        # keep the raw form as fallback for entries that do not exist yet
        real="$(cd "$line" 2>/dev/null && pwd -P)" || real=""
        for cand in "$line" "$real"; do
            [[ -z "$cand" ]] && continue
            if [[ "$CWD" == "$cand" || "$CWD" == "$cand"/* ]]; then
                echo "openrouter-worker: refusing — cwd is under a sensitive path ($line, from $SENSITIVE_FILE)" >&2
                echo "openrouter-worker:   :free routes may retain/train on prompts; override: AGENT_OPENROUTER_FORCE=1" >&2
                exit 9
            fi
        done
    done < "$SENSITIVE_FILE"
fi

echo "openrouter-worker: WARNING — OpenRouter :free routes are commonly served by an anonymous provider that may log/retain and/or train on prompts and responses (policy varies per model). Do not send anything you would not send to an anonymous third party." >&2

KEY="$(security find-generic-password -a "$USER" -s openrouter-api-key -w 2>/dev/null)"
[[ -n "$KEY" ]] || {
    echo "openrouter-worker: no Keychain entry 'openrouter-api-key' — register: security add-generic-password -a \"\$USER\" -s openrouter-api-key -w" >&2
    exit 4
}

WORK_DIR="$(mktemp -d)" || { echo "openrouter-worker: mktemp -d failed" >&2; exit 6; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
# A bare SIGTERM/SIGINT would kill the shell WITHOUT running the EXIT trap,
# leaving the key-bearing curl config on disk — convert them into a normal
# exit so cleanup always runs (pairs with the preflight's TERM-first watchdog).
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP   # closed terminal/SSH drop must also run the EXIT scrub (security review 2026-08-25)

PROMPT_FILE="$WORK_DIR/prompt.txt"
cat > "$PROMPT_FILE"

# --- egress floor (security review 2026-08-25) -----------------------------
# This lane controls where the CALLER stands, but the PROMPT can still carry
# secrets assembled elsewhere. Before anything leaves the machine to an
# anonymous retention-flagged endpoint: a hard byte cap and a regex floor for
# unmistakable credential shapes. Not a gitleaks replacement — a floor. Loud
# override: AGENT_OPENROUTER_UNSAFE_PROMPT=1.
PROMPT_MAX_BYTES="${OPENROUTER_PROMPT_MAX_BYTES:-262144}"
prompt_bytes=$(wc -c < "$PROMPT_FILE")
if (( prompt_bytes > PROMPT_MAX_BYTES )) && [[ "${AGENT_OPENROUTER_UNSAFE_PROMPT:-0}" != "1" ]]; then
    echo "openrouter-worker: refusing — prompt is $prompt_bytes bytes (> $PROMPT_MAX_BYTES cap) for an anonymous :free endpoint; trim it or override explicitly: AGENT_OPENROUTER_UNSAFE_PROMPT=1" >&2
    exit 9
fi
if [[ "${AGENT_OPENROUTER_UNSAFE_PROMPT:-0}" != "1" ]] \
   && grep -Eq -e 'BEGIN [A-Z ]*PRIVATE KEY' -e 'AKIA[0-9A-Z]{16}' -e 'sk-[A-Za-z0-9_-]{20,}' -e 'ghp_[A-Za-z0-9]{36}' -e 'xox[baprs]-[A-Za-z0-9-]{10,}' "$PROMPT_FILE"; then
    echo "openrouter-worker: refusing — prompt matches a credential pattern (private key / AWS / sk- / ghp_ / xox-) and this endpoint may retain/train on it; scrub it or override explicitly: AGENT_OPENROUTER_UNSAFE_PROMPT=1" >&2
    exit 9
fi

PAYLOAD_FILE="$WORK_DIR/payload.json"
jq -n --rawfile prompt "$PROMPT_FILE" --arg model "$MODEL" \
    '{model: $model, messages: [{role: "user", content: $prompt}]}' \
    > "$PAYLOAD_FILE" \
    || { echo "openrouter-worker: jq failed to build the request payload — refusing" >&2; exit 6; }

# The key is interpolated into a double-quoted curl-config value below; a
# credential containing a quote, backslash, or newline would break that
# quoting into a silent-auth-failure (or a mangled request). Real OpenRouter
# keys are sk-or-… token charset; refuse anything outside it rather than
# escape-and-hope.
case "$KEY" in
    *'"'*|*'\'*|*$'\n'*)
        echo "openrouter-worker: Keychain credential contains quote/backslash/newline — refusing to build the curl config with it" >&2
        exit 9 ;;
esac

# Curl config file (not -H on argv) so the key never appears in `ps` output.
CURL_CFG="$WORK_DIR/curl.cfg"
(
    umask 077
    printf 'url = "https://openrouter.ai/api/v1/chat/completions"\n' > "$CURL_CFG"
    printf 'header = "Authorization: Bearer %s"\n' "$KEY" >> "$CURL_CFG"
    printf 'header = "Content-Type: application/json"\n' >> "$CURL_CFG"
    printf 'data = @%s\n' "$PAYLOAD_FILE" >> "$CURL_CFG"
)

RESP_FILE="$WORK_DIR/response.json"
HTTP_CODE_FILE="$WORK_DIR/http_code"
CURL_ERR="$WORK_DIR/curl.err"
TIMEOUT_S="${OPENROUTER_WORKER_TIMEOUT_S:-280}"

# Run as a CHILD (not exec) with signal forwarding, so the EXIT trap fires and
# the prompt/key material never outlive the dispatch.
child=
forward() { [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null || true; }
trap forward TERM INT
curl -sS --max-time "$TIMEOUT_S" -o "$RESP_FILE" -w '%{http_code}' -K "$CURL_CFG" \
    > "$HTTP_CODE_FILE" 2>"$CURL_ERR" &
child=$!
curl_rc=0
wait "$child" || curl_rc=$?

if [[ $curl_rc -ne 0 ]]; then
    echo "openrouter-worker: curl transport failure (exit $curl_rc)" >&2
    cat "$CURL_ERR" >&2
    exit 1
fi

HTTP_CODE="$(cat "$HTTP_CODE_FILE" 2>/dev/null)"

if [[ "$HTTP_CODE" == "429" ]]; then
    echo "openrouter-worker: rate-limited; lane skipped; retry later" >&2
    exit 75
fi

if [[ "$HTTP_CODE" != 2* ]]; then
    ERR_MSG="$(jq -r '.error.message // empty' "$RESP_FILE" 2>/dev/null)"
    echo "openrouter-worker: request failed (HTTP $HTTP_CODE)${ERR_MSG:+: $ERR_MSG}" >&2
    exit 1
fi

CONTENT="$(jq -r '.choices[0].message.content // empty' "$RESP_FILE" 2>/dev/null)"
[[ -n "$CONTENT" ]] || {
    echo "openrouter-worker: HTTP 200 but no assistant content in the response — refusing to report success" >&2
    cat "$RESP_FILE" >&2
    exit 1
}
printf '%s\n' "$CONTENT"
exit 0
