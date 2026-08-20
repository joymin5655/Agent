#!/usr/bin/env bash
# council-threshold.sh — deterministic SSOT for "is this diff council-scale?"
#
# Judges a diff against three OR'd signals and prints one summary line so a
# consumer (council-escalation-gate.py, skills/wrap Step 1) never has to
# re-derive the numbers themselves:
#   - changed line total  >= AGENT_COUNCIL_LINES  (default 200)
#   - changed file count  >= AGENT_COUNCIL_FILES  (default 10)
#   - any changed path matches a risk-area pattern (mirrors
#     core/hooks/spec-gate.py:72 GUARD_PATTERNS, plus a project's own
#     risk_areas.secrets.paths override via core/hooks/hook_config.py —
#     the same loader core/hooks/pre-tool-guard.sh already shells out to)
#
# This is the third mirror of spec-gate's GUARD_PATTERNS shape (after
# tdd-guard.py and spec-gate.py itself) — see script comment there for why
# the patterns are kept in lockstep by hand rather than imported (this is a
# bash consumer; spec-gate's are Python).
#
# usage: council-threshold.sh [--staged|--head|<range>]
#   --staged (default): git diff --staged; if that is empty, falls back to
#             HEAD~1..HEAD (so a just-committed change is still judged —
#             the working tree is not left with nothing to say).
#   --head:   git diff HEAD~1..HEAD
#   <range>:  passed through verbatim to `git diff <range>` (terminated with
#             --end-of-options so a range that starts with '-' can never be
#             consumed as a git option — F6, option injection)
#
# stdout: ALWAYS one line — "lines=<N> files=<M> risk=<comma-list|none>"
# exit:   0  = not council-scale
#         10 = council-scale (one or more OR signals fired)
#
# env seams: AGENT_COUNCIL_LINES, AGENT_COUNCIL_FILES
set -u

# FRAMEWORK_ROOT locates THIS script's own tree (core/hooks, for the
# hook_config.py import below) — it is the harness install location, which
# under a plugin install is NOT the same directory as the project being
# judged. PROJECT_ROOT is the consumer project whose .agent/hook-config.yml
# (risk_areas.secrets.paths) actually needs reading; the two must never be
# conflated (F1 — passing FRAMEWORK_ROOT where PROJECT_ROOT belongs meant a
# project's declared secret paths silently never fired under a plugin
# install). PROJECT_ROOT follows the same env-then-git-then-cwd chain
# pre-tool-guard.sh's log_violation() and hook_config's other Bash callers
# use, so all three stay in lockstep.
FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_ROOT="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git -c core.fsmonitor= rev-parse --show-toplevel 2>/dev/null)}}"
PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"

LINES_THRESHOLD="${AGENT_COUNCIL_LINES:-200}"
FILES_THRESHOLD="${AGENT_COUNCIL_FILES:-10}"

# -c core.fsmonitor= and --no-ext-diff/--no-textconv on every diff call (F5):
# this script runs `git diff` automatically, before any trust decision, in
# whatever repo the session happens to be open on — including one delivered
# as an archive with a hostile .git/config or .gitattributes (fsmonitor hook,
# external-diff driver, or textconv driver can all execute code from a diff
# invocation otherwise).
#
# --no-renames (F12, measured empirically 2026-08-21 on this repo's git
# 2.50.1 with diff.renames default-on): rename detection makes --numstat
# report THREE distinct defects at once. (1) the path field takes two
# different shapes — "old/path => new/path" with no common prefix, or the
# compact "common/{old => new}/tail" with one — and risk_area_for()'s
# anchor-on-slash regexes match NEITHER (a risk token after " => " is
# preceded by a space, not "/"; a risk token inside "{...}" has no trailing
# "/" at all), so a rename INTO a risk-area path went silently undetected.
# (2) line accounting collapses: a same-content rename reports 0 changed
# lines regardless of file size, and a rename-plus-edit reports only the
# edited lines, not the file's full size — a large file-reorganization
# refactor (a textbook council-scale change) could never cross
# AGENT_COUNCIL_LINES. --no-renames turns every rename back into a plain
# delete-old + add-new pair, so the path field is always a single real path
# and the line counts are always the file's full add/delete, honestly. The
# only side effect is a pure rename now counts as 2 files instead of 1 —
# strictly more conservative, which is the safe direction for a gate.
ARG="${1:---staged}"
case "$ARG" in
  --staged)
    NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames --staged --numstat 2>/dev/null)"
    if [[ -z "$NUMSTAT" ]]; then
      NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames HEAD~1..HEAD --numstat 2>/dev/null)"
    fi
    ;;
  --head)
    NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames HEAD~1..HEAD --numstat 2>/dev/null)"
    ;;
  *)
    # --end-of-options (F6): ARG is a caller-supplied revision/range that
    # must never be interpreted as a git option — without this, a range
    # starting with '-' (e.g. "--output=FILE") is consumed as an option and
    # can overwrite an arbitrary file.
    NUMSTAT="$(git -c core.fsmonitor= diff --no-ext-diff --no-textconv --no-renames --numstat --end-of-options "$ARG" 2>/dev/null)"
    ;;
esac

# Risk-area patterns — mirror spec-gate.py:72 GUARD_PATTERNS exactly (label
# kept identical so a firing reads the same across both gates).
risk_area_for() {
  local path="$1"
  if printf '%s' "$path" | grep -qE '(^|/)migrations/.+\.sql$'; then
    echo "production-migration"; return
  fi
  if printf '%s' "$path" | grep -qE '(^|/)(secrets/|\.env)'; then
    echo "secret"; return
  fi
  if printf '%s' "$path" | grep -qE '(^|/)functions/[^/]+/index\.(ts|js)$'; then
    echo "edge-fn"; return
  fi
  if printf '%s' "$path" | grep -qE '(^|/)billing/'; then
    echo "billing"; return
  fi
}

# Project-declared secret paths (hook_config.py risk_areas.secrets.paths) —
# the SAME loader pre-tool-guard.sh already shells out to, so a project that
# extends its secret-path list gets the extension honored here too instead
# of a second, drifting definition. Reads PROJECT_ROOT's .agent/hook-config,
# not this framework's own tree.
PROJECT_SECRET_TOKENS=""
if command -v python3 >/dev/null 2>&1; then
  PROJECT_SECRET_TOKENS="$(_HD="$FRAMEWORK_ROOT/core/hooks" python3 - "$PROJECT_ROOT" <<'PY' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ.get("_HD", ""))
try:
    import hook_config
    for tok in hook_config.load_risk_area_secret_paths(sys.argv[1]):
        print(tok)
except Exception:
    pass
PY
)"
fi

LINES=0
FILES=0
RISK_AREAS=""

add_risk() {
  local area="$1"
  case ",$RISK_AREAS," in
    *",$area,"*) ;;  # already recorded
    *) RISK_AREAS="${RISK_AREAS:+$RISK_AREAS,}$area" ;;
  esac
}

while IFS=$'\t' read -r add del path; do
  [[ -z "$path" ]] && continue
  FILES=$((FILES + 1))
  [[ "$add" =~ ^[0-9]+$ ]] && LINES=$((LINES + add))
  [[ "$del" =~ ^[0-9]+$ ]] && LINES=$((LINES + del))

  area="$(risk_area_for "$path")"
  [[ -n "$area" ]] && add_risk "$area"

  if [[ -n "$PROJECT_SECRET_TOKENS" ]]; then
    while IFS= read -r tok; do
      [[ -z "$tok" ]] && continue
      [[ "$path" == *"$tok"* ]] && add_risk "secret"
    done <<< "$PROJECT_SECRET_TOKENS"
  fi
done <<< "$NUMSTAT"

ESCALATE=0
[[ "$LINES" -ge "$LINES_THRESHOLD" ]] && ESCALATE=1
[[ "$FILES" -ge "$FILES_THRESHOLD" ]] && ESCALATE=1
[[ -n "$RISK_AREAS" ]] && ESCALATE=1

printf 'lines=%d files=%d risk=%s\n' "$LINES" "$FILES" "${RISK_AREAS:-none}"

[[ "$ESCALATE" -eq 1 ]] && exit 10
exit 0
