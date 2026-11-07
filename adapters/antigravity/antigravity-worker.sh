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
# ACCOUNTS: AGENT_WORKER_ACCOUNT=<name> (set by call-worker.sh from the usage policy, never by a
# caller) runs agy on one of the local accounts listed in ~/.agent/antigravity-accounts.json
# (README "Accounts"). A default-slot account is agy as it runs today. A file slot runs agy with
# HOME=~/.agy-<name> inside a sandbox that also forbids /usr/bin/security, so agy keeps that
# login in the slot, not in the keyring; it needs sandbox-exec (exit 7 without, whatever
# ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED says) and refuses ANTIGRAVITY_AUTH=apikey. Every run
# also loses read access to the other ~/.agy-* dirs (python3 is required when an account is
# set, and for the sandbox profile whenever any ~/.agy-* exists). The choice is guaranteed only
# through call-worker.sh: a worker started directly trusts AGENT_WORKER_ACCOUNT, still limited
# to the listed accounts.
# An unusable accounts file, a bad or unlisted name or a bad slot dir exits 2 before agy starts.
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
# everything else (any other name, no name, no toolCall, unparseable input, more than one JSON document, a NUL byte, jq failure).
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
#        AGENT_WORKER_ACCOUNT (account name, see ACCOUNTS),
#        ANTIGRAVITY_WORKER_PRINT_TIMEOUT (agy --print-timeout, default 14m: under the
#        gemini lane's 900s timeout_s, so agy ends the run before the hard kill),
#        ANTIGRAVITY_AUTH=apikey (opt-in Keychain API key, see AUTH)
# exit:  agy's own nonzero exit code (incl. the undocumented 3 = envelope status
#        ERROR); 2 usage/config (incl. a missing Keychain item and any account failure);
#        6 mktemp failure; 7 sandbox unavailable (fail closed; always for a file slot);
#        8 unsafe $HOME or other path for a scheme string;
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

# Account slot. call-worker.sh passes AGENT_WORKER_ACCOUNT=<name> only when the usage policy
# picked an account for this run; the name must be listed in the owner-written accounts file.
# Resolved before the tiers file is touched (its one-time migration copies a file): every
# failure exits 2 here, with agy never started and nothing created. ACCOUNT_SLOT is "" (no
# account), "default" (agy as it runs today, login in the OS keyring) or "file" (agy runs with
# HOME=$SLOT inside the sandbox, which forbids the keyring tool so agy stores its login there).
# python3 -I reads the file: O_NOFOLLOW + fstat on the open descriptor, so a symlink or a
# swapped file cannot slip between the check and the read.
ACCOUNT="${AGENT_WORKER_ACCOUNT:-}"
ACCOUNT_SLOT=""
SLOT=""
if [[ -n "$ACCOUNT" ]]; then
    command -v python3 >/dev/null 2>&1 || { echo "antigravity-worker: python3 is required to read the accounts file — refusing" >&2; exit 2; }
    ACCOUNT_SLOT="$(python3 -I - "$HOME/.agent/antigravity-accounts.json" "$ACCOUNT" <<'ACCOUNTPY'
import json, os, re, stat, sys

path, name = sys.argv[1], sys.argv[2]
NAME = re.compile(r"[a-z][a-z0-9]{0,15}")


def fail(msg):
    sys.stderr.write("antigravity-worker: " + msg + " - refusing\n")
    sys.exit(2)


if not NAME.fullmatch(name):
    fail("AGENT_WORKER_ACCOUNT is not a valid account name (a lowercase letter, then up to 15 "
         "lowercase letters or digits)")
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    fail("the accounts file ~/.agent/antigravity-accounts.json is missing, unreadable or a symlink")
with os.fdopen(fd, "rb") as f:
    st = os.fstat(f.fileno())
    if not stat.S_ISREG(st.st_mode):
        fail("the accounts file is not a regular file")
    if st.st_uid != os.getuid():
        fail("the accounts file is not owned by the current user")
    if st.st_mode & 0o022:
        fail("the accounts file is group- or other-writable")
    raw = f.read(65537)
if len(raw) > 65536:
    fail("the accounts file is larger than 64 KiB")
try:
    doc = json.loads(raw.decode("utf-8"))
except (ValueError, RecursionError):
    fail("the accounts file is not valid JSON")
accounts = doc.get("accounts") if isinstance(doc, dict) else None
if not isinstance(accounts, list) or not 1 <= len(accounts) <= 4:
    fail("the accounts file must be one object whose accounts is an array of 1-4 entries")
slots = {}
default_slots = 0
for entry in accounts:
    n = entry.get("name") if isinstance(entry, dict) else None
    if not isinstance(n, str) or not NAME.fullmatch(n):
        fail("an accounts entry has no valid name")
    if n in slots:
        fail("the accounts file lists a name twice")
    if "slot" not in entry:
        slots[n] = "default"
        default_slots += 1
    elif entry["slot"] == "file":
        slots[n] = "file"
    else:
        fail("an accounts entry has a slot other than file")
if default_slots > 1:
    fail("the accounts file has more than one default-slot entry")
if name not in slots:
    fail("account '" + name + "' is not listed in the accounts file")
print(slots[name])
ACCOUNTPY
)" || exit 2
    case "$ACCOUNT_SLOT" in
        default|file) ;;
        *) echo "antigravity-worker: the accounts check gave no slot kind — refusing" >&2; exit 2 ;;
    esac
    if [[ "$ACCOUNT_SLOT" == file ]]; then
        if [[ "${ANTIGRAVITY_AUTH:-}" == "apikey" ]]; then
            echo "antigravity-worker: ANTIGRAVITY_AUTH=apikey cannot be combined with a file slot account — refusing" >&2
            exit 2
        fi
        SLOT="$HOME/.agy-$ACCOUNT"
        if [[ ! -d "$SLOT" || -L "$SLOT" || ! -O "$SLOT" ]]; then
            echo "antigravity-worker: the file slot for account '$ACCOUNT' must be a real directory (not a symlink) owned by the current user at ~/.agy-$ACCOUNT — refusing" >&2
            exit 2
        fi
        for sub in .gemini .antigravity; do
            if [[ ( -e "$SLOT/$sub" || -L "$SLOT/$sub" ) && ( ! -d "$SLOT/$sub" || -L "$SLOT/$sub" ) ]]; then
                echo "antigravity-worker: ~/.agy-$ACCOUNT/$sub must be a real directory, not a symlink or a file — refusing" >&2
                exit 2
            fi
        done
    fi
fi

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
# jq stops reading at a raw NUL byte and still succeeds (jq 1.7.1), so a NUL could hide a
# second document; the bytes go through tr first, turning a NUL into a control byte that is
# invalid JSON (jq exits 5 -> malformed). An escaped \u0000 inside a string is unaffected.
# tr runs byte-wise (LC_ALL=C), the same in every locale; a failed or missing tr fails the
# pipe (pipefail) and the check refuses too.
if ! LC_ALL=C /usr/bin/tr '\000' '\001' < "$TIERS_FILE" | jq -es 'length == 1 and (.[0] | type) == "object"
             and ((.[0] | has("model") | not) or (.[0].model | type) == "string")
             and ((.[0] | has("tiers") | not)
                  or ((.[0].tiers | type) == "object"
                      and (.[0].tiers | all(.[]; type == "array" and all(.[]; type == "string")))))' \
        >/dev/null 2>&1; then
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
# Every other path interpolated below (WORK_DIR, the file slot, the other ~/.agy-* dirs and
# their real paths) is held to the same rule; a control character counts as one too.
scheme_unsafe() {
    # shellcheck disable=SC1003  # '\' is one literal backslash, not an escaped quote
    case "$1" in *'"'*|*'('*|*')'*|*'\'*) return 0 ;; esac
    [[ "$1" == *[[:cntrl:]]* ]]
}
if scheme_unsafe "$HOME"; then
    echo "antigravity-worker: \$HOME contains a scheme metacharacter — refusing to build a sandbox profile" >&2
    exit 8
fi

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
# Input goes through tr first: jq stops at a raw NUL byte and succeeds, so a NUL could hide a
# second document; a NUL becomes a control byte (invalid JSON, jq exits 5 -> deny). tr runs
# byte-wise (LC_ALL=C): in a UTF-8 locale macOS tr stops at an invalid byte and passes on only
# the part before it. sh has no pipefail, so a failed or missing tr sends a \001 byte to jq
# instead (-> deny); the self-test then refuses to start.
verdict=$( { LC_ALL=C /usr/bin/tr '\000' '\001' || printf '\001'; } | @JQ@ -r 'if (.toolCall | type) == "object" and (.toolCall.name | type) == "string" and (.toolCall.name | IN("search_web")) then "ask" else "deny" end' 2>/dev/null) || verdict=deny
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
    # With a file slot the writable state dir and its carve-outs sit under $SLOT instead of
    # the real $HOME, so the real ~/.gemini is not writable, and two more rules apply (below).
    sb_fail() { rm -rf "$WORK_DIR"; echo "antigravity-worker: $1" >&2; exit "$2"; }
    sb_check() {  # sb_check <path>: one path headed for the profile must carry no metacharacter
        if scheme_unsafe "$1"; then sb_fail "a path for the sandbox profile contains a scheme metacharacter — refusing to build it" 8; fi
    }
    # rpath <var> <path>: <var> = the exact real path. python adds a "/" so command substitution
    # cannot strip a trailing newline that belongs to the name; exactly that one "/" is removed.
    rpath() {
        local o
        o="$(python3 -I -c 'import os, sys; sys.stdout.write(os.path.realpath(sys.argv[1]) + "/")' "$2")" || return 1
        printf -v "$1" '%s' "${o%/}"
    }
    sb_check "$WORK_DIR"
    STATE_BASE="$HOME"
    if [[ "$ACCOUNT_SLOT" == file ]]; then
        sb_check "$SLOT"
        STATE_BASE="$SLOT"
    fi
    # Every existing ~/.agy-* dir except the current file slot is unreadable: one account's run
    # must not see another account's stored login. Each real path is denied too, so a symlinked
    # dir cannot dodge a subpath rule. An unmatched glob stays a literal pattern: -d skips it.
    SB_OTHER_AGY=""
    SLOT_RP=""
    d_rp=""
    if [[ -n "$SLOT" ]]; then rpath SLOT_RP "$SLOT" || sb_fail "python3 failed resolving the file slot — refusing" 2; fi
    for d in "$HOME"/.agy-*; do
        [[ -d "$d" && "$d" != "$SLOT" ]] || continue
        rpath d_rp "$d" || sb_fail "python3 failed resolving an ~/.agy-* dir — refusing" 2
        [[ -z "$SLOT_RP" || "$d_rp" != "$SLOT_RP" ]] || continue
        sb_check "$d"
        SB_OTHER_AGY+=" (subpath \"$d\")"
        if [[ "$d_rp" != "$d" ]]; then
            sb_check "$d_rp"
            SB_OTHER_AGY+=" (subpath \"$d_rp\")"
        fi
    done
    SBPROF='(version 1)(allow default)
(deny file-write*)
(allow file-write* (subpath "'"$WORK_DIR"'") (subpath "'"$STATE_BASE"'/.gemini") (subpath "'"$STATE_BASE"'/.antigravity") (subpath "/dev"))
(deny file-write* (literal "'"$STATE_BASE"'/.gemini/config/hooks.json") (subpath "'"$STATE_BASE"'/.gemini/config/plugins") (literal "'"$STATE_BASE"'/.gemini/settings.json"))
(deny file-read* (subpath "'"$HOME"'/.ssh") (subpath "'"$HOME"'/.aws") (subpath "'"$HOME"'/.config") (subpath "'"$HOME"'/.codex") (subpath "'"$HOME"'/.grok"))'
    if [[ -n "$SB_OTHER_AGY" ]]; then
        SBPROF+="
(deny file-read*$SB_OTHER_AGY)"
    fi
    if [[ "$ACCOUNT_SLOT" == file ]]; then
        # The keyring tool is forbidden (agy then falls back to storing its login under
        # $SLOT — measured on agy 1.5.2: "falling back to file", keyring entry unchanged), and the
        # default slot's stored token file is unreadable so this account never borrows it.
        TOKEN="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
        rpath TOKEN_RP "$TOKEN" || sb_fail "python3 failed resolving the default token path — refusing" 2
        sb_check "$TOKEN"
        SBPROF+='
(deny process-exec (literal "/usr/bin/security"))
(deny file-read* (literal "'"$TOKEN"'")'
        if [[ "$TOKEN_RP" != "$TOKEN" ]]; then
            sb_check "$TOKEN_RP"
            SBPROF+=' (literal "'"$TOKEN_RP"'")'
        fi
        SBPROF+=')'
        # env sets HOME for the agy child only: the worker's own tiers file, work dir and
        # captures keep the real $HOME.
        RUN=(sandbox-exec -p "$SBPROF" /usr/bin/env HOME="$SLOT" "${CMD[@]}")
    else
        RUN=(sandbox-exec -p "$SBPROF" "${CMD[@]}")
    fi
elif [[ "$ACCOUNT_SLOT" != file && "${ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED:-0}" == "1" ]]; then
    echo "antigravity-worker: WARNING dispatching UNSANDBOXED (ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1) — only review trusted content this way" >&2
    RUN=("${CMD[@]}")
else
    rm -rf "$WORK_DIR"
    if [[ "$ACCOUNT_SLOT" == file ]]; then
        echo "antigravity-worker: a file slot account needs sandbox-exec (it keeps the keyring tool out of agy); ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED does not apply — refusing" >&2
    else
        echo "antigravity-worker: sandbox-exec not available. Refusing; set ANTIGRAVITY_WORKER_ALLOW_UNSANDBOXED=1 to accept an unsandboxed dispatch." >&2
    fi
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
