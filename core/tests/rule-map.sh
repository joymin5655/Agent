#!/usr/bin/env bash
# rule-map.sh — the rule -> enforcement map check (docs/gate-registry.md § Rule enforcement map).
#
# A written rule that nothing enforces is a wish. The map lists each normative rule in
# AGENTS.md and rules/policy/operating-contract.md next to the file that enforces it
# (hook / test / CI / lint / git hook), or marks it UNENFORCED. This gate keeps the map honest:
#
#   FAIL  an enforcer path that does not exist (a renamed or deleted file left a dead pointer)
#   FAIL  a malformed RULE / EXCEPT line, a duplicate rule id, an unknown enforcer kind
#   FAIL  an operating-contract bullet with no OC rule row (a new rule slipped in unmapped)
#   FAIL  an EXCEPT that lacks reason / expiry / approver, names an unknown or already-enforced
#         rule, or has expired — an exception is a dated, owned debt, not a permanent pass
#   WARN  the UNENFORCED count and ids (reported, never fails — the number is the pressure)
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

block=$(awk '/^<!-- rule-map:begin -->/{on=1; next} /^<!-- rule-map:end -->/{on=0} on' "$DOC")

rules=""        # newline-separated ids
unenforced=""   # ids whose enforcer is UNENFORCED
excepted=""
n_rules=0
n_oc=0

while IFS= read -r line; do
  case "$line" in
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
      if [[ "$enf" == "UNENFORCED" ]]; then unenforced+="$id"$'\n'; continue; fi
      IFS=',' read -r -a toks <<< "$enf"
      for tok in "${toks[@]}"; do
        tok=$(trim "$tok"); kind="${tok%%:*}"; path="${tok#*:}"
        case "$kind" in
          hook|test|ci|lint|git-hook|script) ;;
          *) fail "$id: unknown enforcer kind '$kind' in '$tok' (hook|test|ci|lint|git-hook|script|UNENFORCED)"; continue ;;
        esac
        [[ "$tok" == *:* && -e "$ROOT/$path" ]] || fail "$id: enforcer path does not exist: $path"
      done ;;
    "EXCEPT "*)
      IFS='|' read -r f_id f_why f_exp f_who f_extra <<< "${line#EXCEPT }"
      id=$(trim "${f_id:-}"); why=$(trim "${f_why:-}"); exp=$(trim "${f_exp:-}"); who=$(trim "${f_who:-}")
      if [[ -z "$id" || -z "$why" || -z "$exp" || -z "$who" || -n "${f_extra:-}" ]]; then
        fail "EXCEPT needs reason, expiry date and approver (id | reason | YYYY-MM-DD | approver): $line"; continue
      fi
      if ! [[ "$exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then fail "EXCEPT $id: expiry '$exp' is not YYYY-MM-DD"; continue; fi
      if [[ "$exp" < "$TODAY" ]]; then fail "EXCEPT $id: expired $exp (today $TODAY) — fix the rule or renew with an approver"; continue; fi
      excepted+="$id"$'\n' ;;
  esac
done <<< "$block"

# every EXCEPT must target a known, UNENFORCED rule (checked after all rows are read)
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  printf '%s\n' "$unenforced" | grep -qxF -- "$id" || fail "EXCEPT $id: no such UNENFORCED rule"
done <<< "$excepted"

# drift: every operating-contract bullet needs an OC row
oc_file="$ROOT/rules/policy/operating-contract.md"
if [[ -f "$oc_file" ]]; then
  bullets=$(grep -c '^- ' "$oc_file" || true)
  (( n_oc >= bullets )) || fail "operating-contract.md has $bullets bullets but only $n_oc OC- rows — map the new rule"
fi

n_unenf=$(printf '%s' "$unenforced" | grep -c . || true)
n_exc=$(printf '%s' "$excepted" | grep -c . || true)
if [[ "$FAILS" -gt 0 ]]; then
  echo "rule-map: $FAILS defect(s)"
  exit 1
fi
if (( n_unenf > 0 )); then
  echo "WARN rule-map: $n_unenf UNENFORCED rule(s) ($n_exc excepted): $(printf '%s' "$unenforced" | paste -sd' ' -)"
fi
echo "PASS rule-map: $n_rules rules, $((n_rules - n_unenf)) enforced, $n_unenf UNENFORCED"
