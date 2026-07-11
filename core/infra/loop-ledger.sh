#!/usr/bin/env bash
# loop-ledger.sh — P2-3: the autonomous-loop results ledger (append-only).
#
# The loop (§5) records one row per attempt in `.agent/loop/results.tsv` (untracked
# — it is run state, not source). This helper is the ONLY sanctioned writer: it
# APPENDS a row and never rewrites, so the ledger is a tamper-evident log of what the
# loop tried and what was kept. (The loop-write-guard.py hook enforces the same
# append-only property against ad-hoc edits during a loop session; this script is the
# clean path.)
#
# Schema (5 tab-separated columns, per the backlog):
#   commit  harness_score  duration_s  status  description
#   - commit:       short sha (or '-' for an uncommitted dry run)
#   - harness_score: the grade.sh rollup (X.Y)
#   - duration_s:   integer seconds for the run
#   - status:       one of keep | discard | crash | timeout
#   - description:  <= 80 chars, tabs/newlines stripped (the mission/idea)
#
# A header row is written once when the file is created. Every subsequent call
# appends exactly one data row (>>). The file is created under .agent/loop/ if
# absent; the directory is created as needed.
#
# Usage:
#   loop-ledger.sh append --file <tsv> --commit <c> --score <s> \
#       --duration <n> --status <keep|discard|crash|timeout> --desc <text>
#   loop-ledger.sh path            # print the default ledger path
#
# Test seam: AGENT_LOOP_LEDGER overrides the default .agent/loop/results.tsv path.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_LEDGER="${AGENT_LOOP_LEDGER:-$REPO_ROOT/.agent/loop/results.tsv}"
HEADER=$'commit\tharness_score\tduration_s\tstatus\tdescription'

die() { printf 'loop-ledger: %s\n' "$1" >&2; exit 1; }

cmd_path() { printf '%s\n' "$DEFAULT_LEDGER"; }

cmd_append() {
  local file="$DEFAULT_LEDGER" commit="" score="" duration="" status="" desc=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)     file="${2:-}"; shift 2 ;;
      --commit)   commit="${2:-}"; shift 2 ;;
      --score)    score="${2:-}"; shift 2 ;;
      --duration) duration="${2:-}"; shift 2 ;;
      --status)   status="${2:-}"; shift 2 ;;
      --desc)     desc="${2:-}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  [[ -n "$commit" ]]   || commit="-"
  [[ -n "$score" ]]    || die "--score is required"
  [[ -n "$duration" ]] || duration="0"
  case "$status" in
    keep|discard|crash|timeout) ;;
    *) die "--status must be one of keep|discard|crash|timeout (got: '${status}')" ;;
  esac

  # commit must be a sha (hex) or '-'; anything else (esp. an embedded tab) would
  # forge extra TSV columns — reject rather than sanitize-and-hope (TSV injection).
  printf '%s' "$commit"   | grep -qE '^([0-9a-fA-F]+|-)$'  || die "--commit must be a hex sha or '-' (got: '${commit}')"
  # harness_score must look numeric; duration must be a non-negative integer —
  # a malformed value is rejected, not silently coerced (loose-coercion lesson).
  printf '%s' "$score"    | grep -qE '^[0-9]+(\.[0-9]+)?$' || die "--score must be numeric (got: '${score}')"
  printf '%s' "$duration" | grep -qE '^[0-9]+$'            || die "--duration must be a non-negative integer (got: '${duration}')"

  # sanitize free text: strip tabs/newlines/CR (they would break the TSV row), then
  # cap at 80 CHARACTERS (bash substring is codepoint-aware under a UTF-8 locale, so
  # Korean/multibyte descriptions are not truncated mid-sequence as `cut -c` may).
  desc="$(printf '%s' "$desc" | tr '\t\r\n' '   ')"
  desc="${desc:0:80}"

  mkdir -p "$(dirname "$file")" || die "cannot create ledger dir for $file"
  if [[ ! -s "$file" ]]; then   # missing OR empty -> (re)write the header once
    printf '%s\n' "$HEADER" > "$file" || die "cannot write header to $file"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$commit" "$score" "$duration" "$status" "$desc" >> "$file" \
    || die "cannot append row to $file"
}

case "${1:-}" in
  append) shift; cmd_append "$@" ;;
  path)   cmd_path ;;
  *) die "usage: loop-ledger.sh {append|path} [...]" ;;
esac
