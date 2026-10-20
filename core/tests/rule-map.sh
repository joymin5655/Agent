#!/usr/bin/env bash
# rule-map.sh — the rule -> enforcement map check (docs/gate-registry.md § Rule enforcement map).
#
# A written rule that nothing enforces is a wish. The map lists each normative rule in
# AGENTS.md and rules/policy/operating-contract.md next to the file that enforces it
# (hook / test / CI / lint / git hook), `PARTIAL <enforcers> ~ <gap>` when the enforcer covers
# only part of the rule, or UNENFORCED. This gate keeps the map honest:
#
#   FAIL  an enforcer path that does not exist (a renamed or deleted file left a dead pointer)
#   FAIL  a `hook:` enforcer that is not registered in hooks/hooks.json (a file that never runs
#         enforces nothing). Chosen over a per-file back-reference tag because that would edit
#         every enforcing hook (risk-area files) just to satisfy a doc check.
#   FAIL  a malformed RULE / EXCEPT line, any other non-blank non-# line inside the block, a
#         duplicate rule id, an unknown enforcer kind, a PARTIAL without a stated gap
#   FAIL  an operating-contract bullet with no OC rule row (a new rule slipped in unmapped)
#   FAIL  an EXCEPT that lacks reason / expiry / approver, has an impossible date, names an
#         unknown or fully-enforced rule, or has expired — an exception is a dated, owned debt
#   WARN  the PARTIAL and UNENFORCED counts and ids (reported, never fails — the number is the
#         pressure)
#
# Usage: bash core/tests/rule-map.sh [--doc <file>] [--root <dir>]
#   --doc   map document (default docs/gate-registry.md under --root)
#   --root  repo root that enforcer paths resolve against (default: this repo)
#   RULE_MAP_TODAY=YYYY-MM-DD pins "today" (tests); default `date +%F`.
#
# Exit 0: clean (warnings allowed). Exit 1: defects. Exit 2: usage / map block missing.
#
# Idea credit: cursor/plugins pstack skills/correct (MIT) — every rule gets a named enforcer —
# and the "build the check instead of writing the rule" retro (mattpocock). Rewritten here.
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --doc) DOC="${2:?--doc needs a file}"; shift 2 ;;
    --root) ROOT="${2:?--root needs a dir}"; shift 2 ;;
    *) echo "usage: rule-map.sh [--doc <file>] [--root <dir>]" >&2; exit 2 ;;
  esac
done
[[ -n "$DOC" ]] || DOC="$ROOT/docs/gate-registry.md"
TODAY="${RULE_MAP_TODAY:-$(date +%F)}"

if [[ ! -f "$DOC" ]] || ! grep -q '^<!-- rule-map:begin -->' "$DOC"; then
  echo "rule-map: no <!-- rule-map:begin --> block in $DOC" >&2
  exit 2
fi

FAILS=0
fail() { echo "FAIL rule-map: $*"; FAILS=$((FAILS + 1)); }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
real_date() { python3 -I -c 'import datetime,sys; datetime.date.fromisoformat(sys.argv[1])' "$1" 2>/dev/null; }

block=$(awk '/^<!-- rule-map:begin -->/{on=1; next} /^<!-- rule-map:end -->/{on=0} on' "$DOC")
hooks_json="$ROOT/hooks/hooks.json"

rules=""        # newline-separated ids
unenforced=""   # ids with enforcer UNENFORCED
partial=""      # ids with enforcer PARTIAL
excepted=""
n_rules=0
n_oc=0

# check_tokens <id> <comma-separated kind:path list>
check_tokens() {
  local id="$1" list="$2" tok kind path
  local -a toks
  IFS=',' read -r -a toks <<< "$list"
  for tok in "${toks[@]}"; do
    tok=$(trim "$tok"); kind="${tok%%:*}"; path="${tok#*:}"
    case "$kind" in
      hook|test|ci|lint|git-hook|script) ;;
      *) fail "$id: unknown enforcer kind '$kind' in '$tok' (hook|test|ci|lint|git-hook|script)"; continue ;;
    esac
    if [[ "$tok" != *:* || ! -e "$ROOT/$path" ]]; then fail "$id: enforcer path does not exist: $path"; continue; fi
    if [[ "$kind" == hook ]]; then
      if [[ ! -f "$hooks_json" ]] || ! grep -qF -- "${path##*/}" "$hooks_json"; then
        fail "$id: hook ${path##*/} is not registered in hooks/hooks.json (an unregistered hook never runs)"
      fi
    fi
  done
}

while IFS= read -r line; do
  case "$line" in
    "" | "#"*) ;;
    "RULE "*)
      IFS='|' read -r f_id f_src f_rule f_enf f_extra <<< "${line#RULE }"
      id=$(trim "${f_id:-}"); src=$(trim "${f_src:-}"); rule=$(trim "${f_rule:-}"); enf=$(trim "${f_enf:-}")
      if [[ -z "$id" || -z "$src" || -z "$rule" || -z "$enf" || -n "${f_extra:-}" ]]; then
        fail "RULE line needs exactly 4 fields (id | source | rule | enforcer): $line"; continue
      fi
      if printf '%s\n' "$rules" | grep -qxF -- "$id"; then fail "duplicate rule id $id"; continue; fi
      rules+="$id"$'\n'; n_rules=$((n_rules + 1))
      [[ "$id" == OC-* ]] && n_oc=$((n_oc + 1))
      srcfile="${src%% *}"
      [[ -f "$ROOT/$srcfile" ]] || fail "$id: source file $srcfile does not exist"
      if [[ "$enf" == "UNENFORCED" ]]; then unenforced+="$id"$'\n'
      elif [[ "$enf" == "PARTIAL "* ]]; then
        body="${enf#PARTIAL }"
        if [[ "$body" != *" ~ "* ]]; then fail "$id: PARTIAL needs '<enforcers> ~ <gap>' (state what is NOT covered)"; continue; fi
        gap=$(trim "${body#* ~ }")
        [[ -n "$gap" ]] || { fail "$id: PARTIAL has an empty gap"; continue; }
        partial+="$id"$'\n'
        check_tokens "$id" "${body%% ~ *}"
      else
        check_tokens "$id" "$enf"
      fi ;;
    "EXCEPT "*)
      IFS='|' read -r f_id f_why f_exp f_who f_extra <<< "${line#EXCEPT }"
      id=$(trim "${f_id:-}"); why=$(trim "${f_why:-}"); exp=$(trim "${f_exp:-}"); who=$(trim "${f_who:-}")
      if [[ -z "$id" || -z "$why" || -z "$exp" || -z "$who" || -n "${f_extra:-}" ]]; then
        fail "EXCEPT needs reason, expiry date and approver (id | reason | YYYY-MM-DD | approver): $line"; continue
      fi
      if ! [[ "$exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! real_date "$exp"; then
        fail "EXCEPT $id: expiry '$exp' is not a real YYYY-MM-DD date"; continue
      fi
      if [[ "$exp" < "$TODAY" ]]; then fail "EXCEPT $id: expired $exp (today $TODAY) — fix the rule or renew with an approver"; continue; fi
      excepted+="$id"$'\n' ;;
    *) fail "unrecognized line in the rule-map block (want RULE, EXCEPT, #, or blank): $line" ;;
  esac
done <<< "$block"

# every EXCEPT must target a known rule that is UNENFORCED or PARTIAL
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  if ! printf '%s\n%s\n' "$unenforced" "$partial" | grep -qxF -- "$id"; then
    fail "EXCEPT $id: no such UNENFORCED or PARTIAL rule"
  fi
done <<< "$excepted"

# drift: every operating-contract bullet needs an OC row
oc_file="$ROOT/rules/policy/operating-contract.md"
if [[ -f "$oc_file" ]]; then
  bullets=$(grep -c '^- ' "$oc_file" || true)
  (( n_oc >= bullets )) || fail "operating-contract.md has $bullets bullets but only $n_oc OC- rows — map the new rule"
fi

n_unenf=$(printf '%s' "$unenforced" | grep -c . || true)
n_part=$(printf '%s' "$partial" | grep -c . || true)
n_exc=$(printf '%s' "$excepted" | grep -c . || true)
if [[ "$FAILS" -gt 0 ]]; then
  echo "rule-map: $FAILS defect(s)"
  exit 1
fi
if (( n_unenf > 0 )); then
  echo "WARN rule-map: $n_unenf UNENFORCED rule(s): $(printf '%s' "$unenforced" | paste -sd' ' -)"
fi
if (( n_part > 0 )); then
  echo "WARN rule-map: $n_part PARTIAL rule(s): $(printf '%s' "$partial" | paste -sd' ' -)"
fi
echo "PASS rule-map: $n_rules rules, $((n_rules - n_unenf - n_part)) enforced, $n_part PARTIAL, $n_unenf UNENFORCED, $n_exc excepted"
