#!/usr/bin/env bash
# call-worker.sh — cross-vendor worker dispatcher.
#
# Resolves a role from core/infra/backends.json (role -> backend at a tier ->
# CLI argv), streams the prompt from stdin to the backend CLI, and captures the
# reply to .agent/workers/<utc-ts>-<role>.md (path printed on stdout). Model
# names never appear here or in backends.json — each vendor's adapter/profile
# owns its tier (docs/model-routing.md § Cross-vendor lanes).
#
# Registry v2 (v1 registries keep exact v1 behavior — every new key optional):
#   - argv = backend.cmd + backend.tier_args[role.tier] + role.args_extra
#   - backend.enabled: false -> loud refusal citing disabled_reason (never a
#     silent fallback); backend.preflight argv is run first when present, and
#     a failing preflight is the same loud-unavailable path.
#   - backend.gateway (e.g. "kiro", retired 2026-10 — legacy/lanes-2026-10/):
#     the vendor is reached THROUGH another vendor's CLI. Such a backend is
#     dispatched from a NEUTRAL, harness-owned working directory instead of the
#     caller's cwd — see "Gateway isolation". No shipped backend uses it now.
#   - The capture header carries "status:" — the mechanical truth layer
#     (complete|failed|timeout|unavailable) beneath any lane self-report.
#
# Gateway isolation (why gateway backends do not inherit the caller's cwd):
#   A gateway CLI resolves its per-lane profile from the WORKING DIRECTORY first
#   (the kiro lanes, retired 2026-10 — legacy/lanes-2026-10/: `--agent <name>`
#   read ./.kiro/agents/<name>.json before ~/.kiro/agents/<name>.json —
#   measured, and the workspace copy won). This dispatcher is normally invoked
#   from the repository under review, so that repository could ship
#   .kiro/agents/kiro-openai-top.json with "tools": ["shell","write"] and
#   replace the read-only profile the framework installed — a write+shell grant
#   handed to an untrusted checkout, with the registry still reading as a pinned
#   read-only lane. A pre-dispatch scan (the kiro preflight did one) cannot
#   close it: the plant can land after the scan and before the dispatch. So the
#   CWD ITSELF is taken off the table —
#   every backend carrying "gateway" runs in a fresh mktemp directory owned by
#   this process, which no repository can write into ahead of time. Non-gateway
#   backends keep inheriting the caller's cwd exactly as before (codex needs it:
#   it reads the repo it is reviewing).
#
# Design (explicit failure over silence):
#   - External calls cost money, so approval is explicit. AGENT_WORKER_POLICY_CMD, when
#     set, is the absolute path of ONE executable (never run through a shell, no PATH
#     search, no relative path — that would resolve inside the repository under review)
#     and is asked per candidate backend right before it would run, WHETHER OR NOT
#     AGENT_WORKER_YES=1 is set:
#         "$AGENT_WORKER_POLICY_CMD" check --lane <vendor> --role <role> --hold <pid>
#     exit 0  = go ahead (approval "policy")
#     exit 3  = not approved: runs only with AGENT_WORKER_YES=1 (a person approved this
#               invocation; approval "user"), else this script exits 3
#     exit 75 = capped: that backend is reported unavailable as "capped: <reason>" and the
#               next candidate is tried. YES=1 does not lift a cap: raising it is the
#               user's own decision, made in the policy, not here.
#     It fails CLOSED, YES=1 or not: a policy that is set but not an absolute path to an
#     executable file, hangs past AGENT_WORKER_POLICY_TIMEOUT_S (default 30; the policy
#     runs in its own process group and the whole group is killed) or exits with any other
#     code ends the run with exit 3. An anthropic-vendor backend is not asked only while it
#     is plainly the host's own subscription: the registry is the shipped one
#     (AGENT_BACKENDS_FILE empty or that same file) and none of ANTHROPIC_API_KEY,
#     ANTHROPIC_AUTH_TOKEN, ANTHROPIC_BASE_URL, CLAUDE_CODE_USE_BEDROCK or
#     CLAUDE_CODE_USE_VERTEX is in the environment (each can route the CLI to per-call
#     billing; presence counts, whatever the value); their values are never printed or
#     logged. With no policy set, AGENT_WORKER_YES=1 is required
#     (exit 3 otherwise, saying how to approve). Both are env-only by design: a
#     dispatched/headless caller cannot answer an interactive confirm — the session that
#     owns the user relationship asks, then sets the env.
#   - AGENT_AUTHOR_VENDOR=<vendor>[,<vendor>...] names every company whose model wrote the
#     work: a backend of any of them is dropped from the candidates ("unavailable", reason
#     recorded), so a company never reviews its own work. Each name must be a known vendor
#     (anthropic, openai, google — review-evidence.py VENDORS), else exit 2. When every
#     candidate is dropped the run ends as unavailable (exit 127) and the caller reports a
#     single-company review.
#   - A role WITHOUT "readonly": true can write the caller's tree (e.g. implementer). Once
#     its backend has run, a line "<vendor><TAB><branch>" ("<vendor><TAB>@<HEAD commit>" on
#     a detached HEAD) is appended to "$(git rev-parse --absolute-git-dir)/agent-author-vendors"
#     of the caller's checkout (nothing outside git; best-effort). review-evidence.py
#     author-vendor counts every line on every branch, so the same company cannot count as an
#     outside reviewer of that work, even after a branch switch or rename carried the
#     uncommitted change along; the branch field only tells the person who clears the file
#     which run a line came from. Recorded on every status where the CLI started (complete,
#     failed, timeout, rate-limited), not only on success as first specified: a run that
#     failed or timed out can still have edited files, and missing such a run would let its
#     company review its own edits.
#     An agent command may not rewrite this file (pre-tool-guard.sh 4b,
#     secret-content-scan.py LEDGER_FILES); the appends here are not agent commands.
#   - The worker (and its preflight probe) runs with AGENT_LANE=<role> in its environment,
#     so a vendor CLI's own session start/stop hooks can tell a dispatched lane from a
#     person's session. A role with "readonly": true gets `--sandbox read-only` on a codex
#     CLI, ahead of the role's args_extra; any other sandbox argument in that argv is a
#     registry error (exit 2), because codex lets a later flag win.
#   - AGENT_WORKER_DISABLE="<name>[,<name>...]" (comma/whitespace/newline
#     separated) refuses the named backends —
#     a name is a backend ("gemini") or a vendor ("google" = every backend with
#     that vendor, which survives a lane rename) — exactly like a registry
#     enabled:false, before their preflight (itself possibly a billable probe),
#     but only for callers whose environment carries it: e.g. a shared machine
#     where one login profile must not bill a vendor CLI signed in to another
#     person's account. A name matching no backend or vendor is reported.
#   - A missing CLI names the missing tool (exit 127 when no backend remains).
#   - Fallback records WHY the primary was skipped (header + stderr).
#   - A hung worker is killed at timeout_s (exit 124 when no fallback remains).
#
# usage: call-worker.sh <role> < prompt.md
# exit:  0 ok | 1 backend failed (its raw exit code is reported on stderr,
#        never forwarded — it would collide with the codes below)
#        2 usage/config (including an unknown AGENT_AUTHOR_VENDOR name) | 3 not approved
#        (no policy and no YES, the policy said no without YES, or the policy failed
#        closed) | 124 timeout | 127 no backend CLI
#        (disabled/preflight-failed/capped/author-vendor backends terminate 127 too —
#        "unavailable")
# captures: $AGENT_WORKERS_DIR, else ~/.agent/workers/<project-key>/ — the key comes
#        from the CALLER's project (git toplevel of $PWD; AGENT_PROJECT_DIR /
#        CLAUDE_PROJECT_DIR only outside a repo — review-evidence.py project-key),
#        never this script's own location, so a plugin-cache
#        install does not bury evidence in the cache. Each capture also appends a
#        row to <workers dir>/reviews.jsonl (diff_key = $AGENT_REVIEW_DIFF_KEY, plus
#        author_vendor = the AGENT_AUTHOR_VENDOR list, sorted and comma-joined, or null,
#        and approval = "user" when a person's AGENT_WORKER_YES=1 let the backend run,
#        else "policy") and to ${AGENT_LOGS_DIR:-~/.agent/logs}/council-lanes.jsonl
#        (which carries author_vendor too); both are best-effort and never change this
#        script's exit code or stdout. Captures and ledger rows are created under
#        umask 077, and each run that writes a capture also tries chmod 700 on the workers
#        dir and chmod 600 on reviews.jsonl (a dir or file made earlier with looser modes is
#        tightened; a failed chmod is ignored). The worker, its preflight and the policy run
#        under the caller's umask.
# env seams (tests): AGENT_BACKENDS_FILE, AGENT_WORKERS_DIR, AGENT_LOGS_DIR,
#                    AGENT_WORKER_YES, AGENT_WORKER_POLICY_CMD, AGENT_WORKER_POLICY_TIMEOUT_S,
#                    AGENT_AUTHOR_VENDOR, AGENT_WORKER_TIMEOUT_S,
#                    AGENT_WORKER_KILL_GRACE_S, AGENT_WORKER_PREFLIGHT_TIMEOUT_S
set -euo pipefail

# Captures and ledger rows can quote reviewed code: owner-only files. The worker, its preflight
# and the policy get the caller's umask back (an implementer's edits must keep normal modes).
CALLER_UMASK="$(umask)"
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKENDS_FILE="${AGENT_BACKENDS_FILE:-$REPO_ROOT/core/infra/backends.json}"
PROJECT_KEY="$(python3 "$REPO_ROOT/core/infra/review-evidence.py" project-key 2>/dev/null || true)"
PROJECT_KEY="${PROJECT_KEY:-unkeyed}"
# HOME can be unset in a stripped env; resolve it from the account database rather
# than aborting under `set -u` before the usage/cost-gate exits get to run.
HOME_DIR="${HOME:-$(cd ~ 2>/dev/null && pwd || true)}"
WORKERS_DIR="${AGENT_WORKERS_DIR:-$HOME_DIR/.agent/workers/$PROJECT_KEY}"
LOGS_DIR="${AGENT_LOGS_DIR:-$HOME_DIR/.agent/logs}"

ROLE="${1:-}"
if [[ -z "$ROLE" ]]; then
    echo "usage: call-worker.sh <role> < prompt.md   (roles: $(command -v jq >/dev/null 2>&1 && jq -r '.roles | keys | join(", ")' "$BACKENDS_FILE" 2>/dev/null || echo "see backends.json"))" >&2
    exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "call-worker: jq is required (brew install jq / apt install jq)" >&2; exit 2; }
[[ -f "$BACKENDS_FILE" ]] || { echo "call-worker: backends registry not found: $BACKENDS_FILE" >&2; exit 2; }

PRIMARY="$(jq -r --arg r "$ROLE" '.roles[$r].backend // empty' "$BACKENDS_FILE")"
if [[ -z "$PRIMARY" ]]; then
    echo "call-worker: unknown role '$ROLE' (known: $(jq -r '.roles | keys | join(", ")' "$BACKENDS_FILE"))" >&2
    exit 2
fi
FALLBACK="$(jq -r --arg r "$ROLE" '.roles[$r].fallback // empty' "$BACKENDS_FILE")"
ROLE_TIER="$(jq -r --arg r "$ROLE" '.roles[$r].tier // empty' "$BACKENDS_FILE")"
ROLE_READONLY="$(jq -r --arg r "$ROLE" '.roles[$r].readonly == true' "$BACKENDS_FILE")"

# The companies whose models wrote the work under review (header). Known names only — the
# list review-evidence.py VENDORS holds: a typo would exclude nothing, which is the failure
# this switch exists to prevent, so it is a config error. Kept sorted and comma-joined.
KNOWN_VENDORS="anthropic google openai"
AUTHOR_VENDORS=""
IFS=$', \t' read -r -a _author_raw <<< "$(printf '%s' "${AGENT_AUTHOR_VENDOR:-}" | tr '[:upper:]' '[:lower:]' | tr '\n' ',')"
for _v in ${_author_raw[@]+"${_author_raw[@]}"}; do
    [[ -n "$_v" ]] || continue
    case " $KNOWN_VENDORS " in
        *" $_v "*) ;;
        *) echo "call-worker: AGENT_AUTHOR_VENDOR names an unknown vendor '$_v' (known: $KNOWN_VENDORS) — refusing" >&2
           exit 2 ;;
    esac
done
for _k in $KNOWN_VENDORS; do
    for _v in ${_author_raw[@]+"${_author_raw[@]}"}; do
        if [[ "$_v" == "$_k" ]]; then AUTHOR_VENDORS="${AUTHOR_VENDORS:+$AUTHOR_VENDORS,}$_k"; break; fi
    done
done
author_has() {  # author_has <vendor> — is <vendor> one of the work's authors?
    [[ -n "$1" && -n "$AUTHOR_VENDORS" ]] || return 1
    case ",$AUTHOR_VENDORS," in *",$1,"*) return 0 ;; esac
    return 1
}

# Cost gate — env-only on purpose: headless callers can't answer prompts. A usage policy, when
# set, is asked per candidate backend (policy_gate, below) even with AGENT_WORKER_YES=1, which
# only overrides its "not approved" (3), never its cap (75). Without a policy, YES=1 is the
# only approval; with neither, refuse here before any work is done. A policy that is set but
# not callable refuses whatever YES says (fail closed).
WORKER_YES=0
[[ "${AGENT_WORKER_YES:-0}" == "1" ]] && WORKER_YES=1
POLICY_CMD="${AGENT_WORKER_POLICY_CMD:-}"
POLICY_TIMEOUT_S="${AGENT_WORKER_POLICY_TIMEOUT_S:-30}"
if [[ -n "$POLICY_CMD" ]]; then
    # An absolute path to one executable: no shell, no PATH search, and no relative path
    # (./x or bin/x would resolve inside the repository under review, i.e. the caller's cwd).
    if [[ "$POLICY_CMD" != /* || ! -f "$POLICY_CMD" || ! -x "$POLICY_CMD" ]]; then
        echo "call-worker: AGENT_WORKER_POLICY_CMD is not an absolute path to an executable file ('$POLICY_CMD') — refusing (failing closed)" >&2
        exit 3
    fi
    [[ "$POLICY_TIMEOUT_S" =~ ^[0-9]+$ ]] \
        || { echo "call-worker: AGENT_WORKER_POLICY_TIMEOUT_S is not numeric ('$POLICY_TIMEOUT_S') — the watchdog would silently never fire" >&2; exit 2; }
elif [[ $WORKER_YES -ne 1 ]]; then
    echo "call-worker: '$ROLE' dispatches to external backend '$PRIMARY' (paid call)." >&2
    echo "call-worker: approve with AGENT_WORKER_YES=1 (per-invocation; the caller asks the user first)." >&2
    exit 3
fi
# What let the backend that ran go ahead; run_backend settles it per candidate.
APPROVAL="user"
[[ -n "$POLICY_CMD" && $WORKER_YES -ne 1 ]] && APPROVAL="policy"
# An anthropic backend skips the policy only while it is plainly the host's own subscription:
# the shipped registry (a custom one could point "claude" at anything) and no variable in the
# environment that can switch the CLI to per-call billing: an API credential, another API
# endpoint, or a cloud provider (Bedrock / Vertex). Presence is tested, whatever the value; the
# values are never read into a variable, printed or logged.
POLICY_ANTHROPIC_EXEMPT=0
if [[ -z "${AGENT_BACKENDS_FILE:-}" || "$BACKENDS_FILE" -ef "$REPO_ROOT/core/infra/backends.json" ]] \
   && [[ -z "${ANTHROPIC_API_KEY+set}" && -z "${ANTHROPIC_AUTH_TOKEN+set}" \
         && -z "${ANTHROPIC_BASE_URL+set}" && -z "${CLAUDE_CODE_USE_BEDROCK+set}" \
         && -z "${CLAUDE_CODE_USE_VERTEX+set}" ]]; then
    POLICY_ANTHROPIC_EXEMPT=1
fi

# Env-scoped lane opt-out (header). An unknown name would silently disable
# nothing — the exact failure this switch exists to prevent — so say so.
# Newlines count as separators too: `read` stops at the first one.
WORKER_DISABLE_RAW="${AGENT_WORKER_DISABLE:-}"
IFS=$', \t' read -r -a WORKER_DISABLE <<< "${WORKER_DISABLE_RAW//$'\n'/,}"
for off in ${WORKER_DISABLE[@]+"${WORKER_DISABLE[@]}"}; do
    [[ -n "$off" ]] || continue
    jq -e --arg n "$off" '.backends[$n] or any(.backends[]; .vendor == $n)' "$BACKENDS_FILE" >/dev/null 2>&1 \
        || echo "call-worker: AGENT_WORKER_DISABLE names no backend or vendor '$off' — it disables nothing" >&2
done

# The prompt is consumed once so both primary and fallback can replay it.
PROMPT_TMP="$(mktemp)"
OUT_TMP="$(mktemp)"
# Gateway isolation (see header): a fresh, empty, process-owned directory that no
# repository can plant a profile into. mktemp -d, not a fixed path under the
# repo — a fixed path is plantable before the run, which is the same TOCTOU the
# preflight's scan cannot close.
NEUTRAL_CWD="$(mktemp -d)"
[[ -n "$NEUTRAL_CWD" && -d "$NEUTRAL_CWD" ]] \
    || { echo "call-worker: could not create a neutral working directory for gateway dispatch — refusing" >&2; exit 2; }
cleanup() {
    rm -f "$PROMPT_TMP" "$OUT_TMP"
    if [[ -n "${NEUTRAL_CWD:-}" && -d "$NEUTRAL_CWD" ]]; then rm -rf "$NEUTRAL_CWD"; fi
}
trap cleanup EXIT INT TERM
cat > "$PROMPT_TMP"
START_S=$SECONDS

# policy_gate <name> <lane> — ask AGENT_WORKER_POLICY_CMD whether this candidate may run now.
# 0 = go ahead (APPROVAL settled: "policy", or "user" when the policy said 3 and a person
# set AGENT_WORKER_YES=1) | 125 = capped (UNAVAILABLE_REASON set, the caller moves on to the
# next candidate; YES does not lift a cap). Any other verdict — not approved without YES,
# hung, an unexpected exit — ends the run with exit 3, exactly like an unapproved call (no
# capture, no index row). The policy runs as the leader of its own process group (python3
# setpgrp + execv: no setsid on macOS, and `set -m` is not dependable in a script), so a
# timeout kills whatever it spawned too; the watchdog is silenced so it cannot keep a
# caller's stdout pipe open after the policy has answered.
policy_gate() {
    local name="$1" lane="$2" out prc=0 pid wpid reason
    out="$(mktemp)"
    ( umask "$CALLER_UMASK"
      exec python3 -c 'import os, sys; os.setpgrp(); os.execv(sys.argv[1], sys.argv[1:])' \
          "$POLICY_CMD" check --lane "$lane" --role "$ROLE" --hold "$$" ) </dev/null >"$out" 2>&1 &
    pid=$!
    ( sleep "$POLICY_TIMEOUT_S" \
        && { kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null; } ) >/dev/null 2>&1 &
    wpid=$!
    wait "$pid" || prc=$?
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    # The reason is a JSON "reason" field, else the first line of output. One line with
    # control characters stripped: it lands in a capture header and on stderr.
    reason="$(jq -r 'if type == "object" then ((.reason // "") | tostring | split("\n")[0]) else "" end' "$out" 2>/dev/null || true)"
    [[ -n "$reason" ]] || reason="$(grep -m1 '[^[:space:]]' "$out" 2>/dev/null | sed -E 's/^[Rr]eason:[[:space:]]*//' || true)"
    reason="$(printf '%s' "${reason:-no reason given}" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-200)"
    rm -f "$out"
    case "$prc" in
        0)  APPROVAL="policy"
            return 0 ;;
        75) UNAVAILABLE_REASON="capped: $reason"
            echo "call-worker: backend '$name' unavailable — $UNAVAILABLE_REASON" >&2
            return 125 ;;
        3)  if [[ $WORKER_YES -eq 1 ]]; then
                echo "call-worker: policy did not approve '$ROLE' on lane '$lane' ($reason) — running on the person's AGENT_WORKER_YES=1" >&2
                APPROVAL="user"
                return 0
            fi
            echo "call-worker: policy did not approve '$ROLE' on lane '$lane' (exit 3): $reason" >&2 ;;
        *)  echo "call-worker: policy command exited $prc for lane '$lane' (want 0, 3 or 75; $reason) — failing closed" >&2 ;;
    esac
    exit 3
}

# record_author <vendor> — a role that can write the caller's tree (no "readonly": true) leaves
# the vendor of a backend whose CLI actually started in the caller's per-worktree git dir, so
# review-evidence.py author-vendor counts that company among the work's authors (header).
# The line is "<vendor><TAB><branch>", "<vendor><TAB>@<HEAD commit>" on a detached HEAD, or
# the bare vendor when neither can be read; review-evidence.py counts every line on every
# branch, and the second field is provenance for the person who clears the file.
# Called from run_backend once the CLI has exited, whatever its status: a failed or timed-out
# run can still have edited files, and a primary that failed before a fallback is recorded
# too. Outside git nothing is written; a failure warns and changes nothing else.
record_author() {
    local v="$1" gd where
    [[ "$ROLE_READONLY" != "true" ]] || return 0
    [[ "$v" =~ ^[a-z0-9-]+$ ]] || return 0
    gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    [[ -n "$gd" && -d "$gd" ]] || return 0
    where="$(git symbolic-ref --short -q HEAD 2>/dev/null)" \
        || where="@$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" \
        || where=""
    [[ "$where" != *[[:cntrl:]]* ]] || where=""
    if [[ -n "$where" ]]; then
        printf '%s\t%s\n' "$v" "$where" >> "$gd/agent-author-vendors" 2>/dev/null
    else
        printf '%s\n' "$v" >> "$gd/agent-author-vendors" 2>/dev/null
    fi || echo "call-worker: author record append failed ($gd/agent-author-vendors)" >&2
}

# run_backend <name> — 0 ok, 124 timeout, 125 unavailable (disabled/preflight/capped/author's
# own vendor, reason in $UNAVAILABLE_REASON), 127 CLI missing, else CLI's exit.
# Reply lands in $OUT_TMP. Portable timeout (macOS ships no GNU timeout):
# background worker + watchdog; TERM from the watchdog maps to 124.
UNAVAILABLE_REASON=""
# Extra argv for ONE re-run (the model self-heal below); empty on every other call.
EXTRA_ARGV=()
run_backend() {
    local name="$1" timeout_s grace_s rc=0 pid wpid
    jq -e --arg b "$name" '.backends[$b]' "$BACKENDS_FILE" >/dev/null 2>&1 \
        || { echo "call-worker: backend '$name' not defined in $BACKENDS_FILE" >&2; return 64; }
    # v2: a declared backend can be switched off — refuse loudly, never silently.
    # (== false, not `// true`: jq's // treats false itself as absent.)
    if [[ "$(jq -r --arg b "$name" '.backends[$b].enabled == false' "$BACKENDS_FILE")" == "true" ]]; then
        UNAVAILABLE_REASON="backend '$name' disabled in registry: $(jq -r --arg b "$name" '.backends[$b].disabled_reason // "no reason recorded"' "$BACKENDS_FILE")"
        echo "call-worker: $UNAVAILABLE_REASON" >&2
        return 125
    fi
    local off vendor=""
    for off in ${WORKER_DISABLE[@]+"${WORKER_DISABLE[@]}"}; do
        [[ -n "$off" ]] || continue
        # A space stands in for a vendor-less backend: the lookup runs once, and no
        # list item can equal it (spaces separate items). An unreadable vendor
        # refuses: guessing "no match" would fail open on an opt-out switch.
        if [[ -z "$vendor" ]]; then
            vendor="$(jq -r --arg b "$name" '.backends[$b].vendor // " "' "$BACKENDS_FILE")" || {
                UNAVAILABLE_REASON="backend '$name': AGENT_WORKER_DISABLE is set but the vendor could not be read — refusing"
                echo "call-worker: $UNAVAILABLE_REASON" >&2
                return 125
            }
        fi
        if [[ "$off" == "$name" || "$off" == "$vendor" ]]; then
            UNAVAILABLE_REASON="backend '$name' disabled by AGENT_WORKER_DISABLE ('$off') in the caller's environment"
            echo "call-worker: $UNAVAILABLE_REASON" >&2
            return 125
        fi
    done
    # A company never reviews its own work: drop a backend whose vendor wrote it.
    local bvendor
    bvendor="$(jq -r --arg b "$name" '.backends[$b].vendor // "" | tostring | ascii_downcase' "$BACKENDS_FILE" 2>/dev/null || true)"
    if author_has "$bvendor"; then
        UNAVAILABLE_REASON="backend '$name' skipped: its vendor '$bvendor' wrote the work under review (AGENT_AUTHOR_VENDOR)"
        echo "call-worker: $UNAVAILABLE_REASON" >&2
        return 125
    fi
    local cmd=()
    while IFS= read -r line; do cmd+=("$line"); done \
        < <(jq -r --arg b "$name" '.backends[$b].cmd[]' "$BACKENDS_FILE")
    [[ ${#cmd[@]} -gt 0 ]] || { echo "call-worker: backend '$name' has an empty cmd in $BACKENDS_FILE" >&2; return 64; }
    if ! command -v "${cmd[0]}" >/dev/null 2>&1; then
        UNAVAILABLE_REASON="backend '$name' CLI '${cmd[0]}' not found"
        return 127
    fi
    # Usage policy (AGENT_WORKER_POLICY_CMD): asked last before any spend, so before the
    # preflight too (a probe can itself be a billable inference call), and asked even with
    # AGENT_WORKER_YES=1 (header). Only the host's own anthropic subscription is exempt
    # (POLICY_ANTHROPIC_EXEMPT); a vendor-less (v1) backend is asked about under its own name.
    if [[ -z "$POLICY_CMD" ]]; then
        APPROVAL="user"
    elif [[ "$bvendor" == "anthropic" && $POLICY_ANTHROPIC_EXEMPT -eq 1 ]]; then
        if [[ $WORKER_YES -eq 1 ]]; then APPROVAL="user"; else APPROVAL="policy"; fi
    else
        policy_gate "$name" "${bvendor:-$name}" || return $?
    fi
    # Gateway isolation (see header). Any non-empty "gateway" value isolates —
    # including a malformed one: an unrecognized shape is treated as "this
    # backend reaches its vendor through someone else's CLI", which is the
    # cautious reading. The tostring keeps a non-string value from crashing jq.
    local gateway dispatch_cwd
    gateway="$(jq -r --arg b "$name" '(.backends[$b].gateway // "") | tostring' "$BACKENDS_FILE")"
    if [[ -n "$gateway" ]]; then
        dispatch_cwd="$NEUTRAL_CWD"
    else
        dispatch_cwd="$PWD"
    fi
    # v2 preflight (absent in v1 registries -> skipped): a cheap health probe
    # so an unauthenticated/broken CLI surfaces as "unavailable", not a paid
    # dispatch that dies mid-flight. Watchdogged so a hung probe can't wedge us.
    # The probe runs in the SAME cwd as the dispatch it is vetting (a probe that
    # inspects a different directory than the dispatch resolves from is exactly
    # the class of lie this lane already paid for), and is told which lane and
    # which registry to reproduce: AGENT_PREFLIGHT_LANE + AGENT_BACKENDS_FILE let
    # adapters/antigravity/antigravity-preflight.sh compose the real dispatch
    # argv instead of guessing a binary and a model. Harmless for probes that
    # ignore them.
    local pf=()
    while IFS= read -r line; do pf+=("$line"); done \
        < <(jq -r --arg b "$name" '.backends[$b].preflight // [] | .[]' "$BACKENDS_FILE")
    if [[ ${#pf[@]} -gt 0 ]]; then
        local prc=0 pf_timeout
        # A gateway probe is a real (cheap) inference round trip, not a --version
        # call, so the default budget is wider; the env seam still wins.
        # Per-backend preflight_timeout_s beats the gateway/non-gateway split:
        # the split encoded "non-gateway probes are cheap version checks", but a
        # non-gateway lane whose probe is a REAL inference round trip (gemini's
        # exact-token probe; the retired grok lane's was another) dies at 10s
        # under ordinary LLM latency and spuriously reports unavailable. The
        # registry entry that declares such a probe now declares its budget too.
        pf_timeout="${AGENT_WORKER_PREFLIGHT_TIMEOUT_S:-}"
        if [[ -z "$pf_timeout" ]]; then
            pf_timeout="$(jq -r --arg b "$name" '.backends[$b].preflight_timeout_s // empty' "$BACKENDS_FILE")"
        fi
        if [[ -z "$pf_timeout" ]]; then
            if [[ -n "$gateway" ]]; then pf_timeout=60; else pf_timeout=10; fi
        fi
        [[ "$pf_timeout" =~ ^[0-9]+$ ]] \
            || { echo "call-worker: AGENT_WORKER_PREFLIGHT_TIMEOUT_S is not numeric ('$pf_timeout') — the watchdog would silently never fire" >&2; return 64; }
        ( cd "$dispatch_cwd" && umask "$CALLER_UMASK" && exec env \
            AGENT_BACKENDS_FILE="$BACKENDS_FILE" \
            AGENT_PREFLIGHT_LANE="$name" \
            AGENT_LANE="$ROLE" \
            "${pf[@]}" ) </dev/null >/dev/null 2>&1 &
        pid=$!
        ( sleep "$pf_timeout" && kill -KILL "$pid" 2>/dev/null ) &
        wpid=$!
        wait "$pid" || prc=$?
        kill "$wpid" 2>/dev/null || true
        wait "$wpid" 2>/dev/null || true
        if [[ $prc -ne 0 ]]; then
            UNAVAILABLE_REASON="backend '$name' preflight failed (${pf[*]} -> exit $prc)"
            echo "call-worker: $UNAVAILABLE_REASON" >&2
            return 125
        fi
    fi
    # v2 argv composition: cmd + tier_args[role.tier] + [read-only sandbox] + role.args_extra.
    # All optional — a v1 registry composes to bare cmd, byte-for-byte.
    if [[ -n "$ROLE_TIER" ]]; then
        while IFS= read -r line; do cmd+=("$line"); done \
            < <(jq -r --arg b "$name" --arg t "$ROLE_TIER" '.backends[$b].tier_args[$t] // [] | .[]' "$BACKENDS_FILE")
    fi
    local role_extra=()
    while IFS= read -r line; do role_extra+=("$line"); done \
        < <(jq -r --arg r "$ROLE" '.roles[$r].args_extra // [] | .[]' "$BACKENDS_FILE")
    # A readonly role on a codex CLI runs in codex's read-only sandbox. Nothing else in the
    # argv may set a sandbox: codex lets a later flag win, so a second one would quietly
    # un-pin it. That is a registry error (exit 2), never a silent pass.
    if [[ "${cmd[0]##*/}" == "codex" && "$ROLE_READONLY" == "true" ]]; then
        local arg prev="" fight=""
        for arg in "${cmd[@]}" ${role_extra[@]+"${role_extra[@]}"}; do
            case "$arg" in
                -s|-s=*|--sandbox|--sandbox=*|--full-auto|--approve-for-me|--dangerously-bypass-approvals-and-sandbox) fight="$arg" ;;
                # one-argument config overrides: --config=sandbox_mode=…, -csandbox_mode=…, -c=…
                --config=sandbox*|-csandbox*|-c=sandbox*) fight="$arg" ;;
                sandbox*) if [[ "$prev" == "-c" || "$prev" == "--config" ]]; then fight="$prev $arg"; fi ;;
            esac
            prev="$arg"
        done
        if [[ -n "$fight" ]]; then
            echo "call-worker: role '$ROLE' is readonly but its argv already sets a sandbox ('$fight') — remove it from $BACKENDS_FILE" >&2
            return 64
        fi
        cmd+=(--sandbox read-only)
    fi
    cmd+=(${role_extra[@]+"${role_extra[@]}"})
    local extra
    for extra in ${EXTRA_ARGV[@]+"${EXTRA_ARGV[@]}"}; do cmd+=("$extra"); done
    timeout_s="${AGENT_WORKER_TIMEOUT_S:-$(jq -r --arg b "$name" '.backends[$b].timeout_s // 300' "$BACKENDS_FILE")}"
    [[ "$timeout_s" =~ ^[0-9]+$ ]] \
        || { echo "call-worker: backend '$name' timeout_s is not numeric ('$timeout_s') — the watchdog would silently never fire" >&2; return 64; }
    grace_s="${AGENT_WORKER_KILL_GRACE_S:-5}"

    # cd + exec in a subshell: `exec` replaces the subshell with the CLI, so $!
    # is the CLI's own pid and the watchdog's TERM/KILL still lands on it. For a
    # non-gateway backend dispatch_cwd is $PWD, i.e. byte-for-byte the previous
    # behavior (the caller's cwd is inherited); only gateway backends move. The
    # export lives and dies with this subshell: AGENT_LANE marks the process as a
    # dispatched lane (see header), whatever the caller's own environment says.
    ( cd "$dispatch_cwd" && umask "$CALLER_UMASK" && export AGENT_LANE="$ROLE" && exec "${cmd[@]}" ) < "$PROMPT_TMP" > "$OUT_TMP" 2>&1 &
    pid=$!
    # TERM at timeout, KILL after a grace period — a CLI wrapper that traps or
    # fails to forward TERM must not defeat the timeout guarantee.
    ( sleep "$timeout_s" && kill -TERM "$pid" 2>/dev/null \
        && sleep "$grace_s" && kill -KILL "$pid" 2>/dev/null ) &
    wpid=$!
    wait "$pid" || rc=$?
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
    record_author "$bvendor" || true
    # SIGTERM (143) / SIGKILL (137) can only come from the watchdog in this
    # process tree — report the conventional timeout code (race-free: no
    # watchdog liveness check, which the fired-vs-tearing-down window defeats).
    [[ $rc -eq 143 || $rc -eq 137 ]] && rc=124
    return "$rc"
}

FALLBACK_REASON=""
BACKEND_USED="$PRIMARY"
rc=0
run_backend "$PRIMARY" || rc=$?

# Model self-heal: a codex pin that the vendor retired or the account cannot use
# fails identically on every call. Only codex's own "ERROR:" lines count: it
# echoes the prompt into the output, and a reviewed diff may quote this very
# text. Re-run ONCE on the catalog's successor and say so; the profile files
# are never edited here (codex-models.py apply does that, behind a paid probe
# and the user's consent).
RETRY_REASON=""
if [[ "$PRIMARY" == "codex" && $rc -ne 0 && $rc -ne 124 ]] \
   && grep -Eq "^ERROR:.*(model is not supported|has been retired|is retired)" "$OUT_TMP"; then
    old_model="$(sed -nE "/^ERROR:/s/.*The '([^']+)' model.*/\1/p" "$OUT_TMP" | head -n 1)"
    # codex prints its header (model: <id>) before echoing the prompt, so the first
    # such line is the model actually running; an ERROR: line quoted from the
    # prompt names some other model and must not steer a paid retry.
    running_model="$(sed -n 's/^model: *//p' "$OUT_TMP" | head -n 1)"
    new_model=""
    if [[ -n "$old_model" && "$old_model" == "$running_model" ]]; then
        new_model="$(python3 "$(dirname "${BASH_SOURCE[0]}")/codex-models.py" upgrade-for "$old_model" 2>/dev/null || true)"
    fi
    if [[ -n "$new_model" && "$new_model" != "$old_model" ]]; then
        RETRY_REASON="model-unsupported $old_model->$new_model"
        echo "call-worker: codex model '$old_model' unsupported — retrying once with '$new_model'" >&2
        echo "call-worker: persist the fix with: python3 $(dirname "${BASH_SOURCE[0]}")/codex-models.py apply" >&2
        EXTRA_ARGV=(-m "$new_model")
        rc=0
        run_backend "$PRIMARY" || rc=$?
        EXTRA_ARGV=()
    fi
fi

if [[ $rc -ne 0 && -n "$FALLBACK" ]]; then
    case "$rc" in
        127) FALLBACK_REASON="primary '$PRIMARY' CLI not found" ;;
        125) FALLBACK_REASON="primary '$PRIMARY' unavailable (${UNAVAILABLE_REASON:-backend exited 125})" ;;
        124) FALLBACK_REASON="primary '$PRIMARY' timed out" ;;
        *)   FALLBACK_REASON="primary '$PRIMARY' exited $rc" ;;
    esac
    echo "call-worker: $FALLBACK_REASON — falling back to '$FALLBACK'" >&2
    BACKEND_USED="$FALLBACK"
    # The primary's reason now lives in FALLBACK_REASON; UNAVAILABLE_REASON describes the
    # backend that ran (or failed to), so a complete fallback capture carries none.
    UNAVAILABLE_REASON=""
    rc=0
    run_backend "$FALLBACK" || rc=$?
fi

# log_evidence <status> <capture-path> — best-effort index + lane-log rows. JSON is
# built by jq from --arg values (never string-concatenated); any failure here is
# swallowed so evidence bookkeeping cannot change the dispatcher's contract.
log_evidence() {
    local status="$1" capture="$2" ts vendor
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    vendor="$(jq -r --arg b "$BACKEND_USED" '.backends[$b].vendor // empty' "$BACKENDS_FILE" 2>/dev/null || true)"
    jq -cn --arg ts "$ts" --arg role "$ROLE" --arg backend "$BACKEND_USED" \
        --arg vendor "$vendor" --arg status "$status" \
        --arg dk "${AGENT_REVIEW_DIFF_KEY:-}" --arg capture "$capture" \
        --arg av "$AUTHOR_VENDORS" --arg approval "$APPROVAL" \
        '{ts:$ts, role:$role, backend:$backend, vendor:($vendor|if .=="" then null else . end),
          status:$status, diff_key:($dk|if .=="" then null else . end), capture:$capture,
          author_vendor:($av|if .=="" then null else . end), approval:$approval}' \
        >> "$WORKERS_DIR/reviews.jsonl" 2>/dev/null \
        || echo "call-worker: review index append failed ($WORKERS_DIR/reviews.jsonl)" >&2
    chmod 600 "$WORKERS_DIR/reviews.jsonl" 2>/dev/null || true
    { mkdir -p "$LOGS_DIR" \
        && jq -cn --arg ts "$ts" --arg pk "$PROJECT_KEY" --arg role "$ROLE" \
            --arg vendor "$vendor" --argjson rc "$rc" \
            --argjson dur "$((SECONDS - START_S))" \
            --argjson pb "$(wc -c < "$PROMPT_TMP" | tr -d ' ')" \
            --arg status "$status" --arg retry "$RETRY_REASON" --arg av "$AUTHOR_VENDORS" \
            '{ts:$ts, project_key:$pk, role:$role, vendor:($vendor|if .=="" then null else . end),
              rc:$rc, duration_s:$dur, prompt_bytes:$pb, status:$status,
              retry_reason:($retry|if .=="" then null else . end),
              author_vendor:($av|if .=="" then null else . end)}' \
            >> "$LOGS_DIR/council-lanes.jsonl"; } 2>/dev/null \
        || echo "call-worker: lane log append failed ($LOGS_DIR/council-lanes.jsonl)" >&2
}

# write_capture <status> — durable evidence for every terminal path where a
# backend was (or should have been) engaged; path printed on stdout. status is
# the mechanical truth layer: a lane's own success claim never overrides it.
write_capture() {
    mkdir -p "$WORKERS_DIR"
    # umask 077 only covers what this run creates; tighten a dir made earlier, best-effort.
    chmod 700 "$WORKERS_DIR" 2>/dev/null || true
    OUT_FILE="$WORKERS_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$ROLE.md"
    {
        echo "---"
        echo "role: $ROLE"
        echo "backend: $BACKEND_USED"
        echo "status: $1"
        echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [[ -n "$FALLBACK_REASON" ]] && echo "fallback_reason: $FALLBACK_REASON"
        [[ -n "$RETRY_REASON" ]] && echo "retry_reason: $RETRY_REASON"
        [[ -n "$UNAVAILABLE_REASON" ]] && echo "unavailable_reason: $UNAVAILABLE_REASON"
        echo "---"
        echo
        cat "$OUT_TMP"
    } > "$OUT_FILE"
    echo "$OUT_FILE"
    log_evidence "$1" "$OUT_FILE" || true
}

if [[ $rc -eq 127 || $rc -eq 125 ]]; then
    if [[ -n "$FALLBACK_REASON" ]]; then
        echo "call-worker: no backend available for '$ROLE' — $FALLBACK_REASON, and fallback '$FALLBACK' is unavailable too. Fix one of them." >&2
    elif [[ $rc -eq 127 ]]; then
        echo "call-worker: backend '$PRIMARY' CLI not found (role '$ROLE' has no fallback). Install it or add a fallback in $BACKENDS_FILE." >&2
    fi   # 125 with no fallback already printed its reason inside run_backend
    write_capture "unavailable" >/dev/null
    exit 127
fi
if [[ $rc -ne 0 ]]; then
    echo "call-worker: backend '$BACKEND_USED' failed (exit $rc) for role '$ROLE'; output follows:" >&2
    cat "$OUT_TMP" >&2
    # Normalize: only the documented codes escape this script — a backend's
    # raw exit code (reported above) must not collide with 2/3/124/127.
    [[ $rc -eq 124 ]] && { write_capture "timeout" >/dev/null; exit 124; }
    # 75 (EX_TEMPFAIL) from an adapter = vendor quota/rate limit, not a backend
    # fault: capture status 'rate-limited' so the consumer can fail open and
    # report "retry later". The escaping exit code stays 1 (lane failed) — no
    # new code leaves this script.
    [[ $rc -eq 75 ]] && { write_capture "rate-limited" >/dev/null; exit 1; }
    [[ $rc -eq 64 ]] && exit 2     # run_backend registry/config error (EX_USAGE internally, so a backend's own raw 2 can't collide)
    write_capture "failed" >/dev/null
    exit 1
fi

# rc 0 with nothing but whitespace is not an answer — every role's contract
# returns text (reviews reply NO-FINDINGS when clean). Seen 2026-10-17: an agy
# print timeout exited 0 with an empty body and was captured as complete,
# letting an absent lane count as seated. stderr is merged into $OUT_TMP, so a
# CLI notice defeats this check: antigravity-worker.sh judges that case itself.
if ! grep -q '[^[:space:]]' "$OUT_TMP" 2>/dev/null; then
    echo "call-worker: backend '$BACKEND_USED' exited 0 with empty output for role '$ROLE' — treated as failed." >&2
    write_capture "failed" >/dev/null
    exit 1
fi

write_capture "complete"
