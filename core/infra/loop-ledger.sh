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
# Tamper evidence (High: delete-recreate): every successful append records a
# WITNESS (`<ledger>.witness` = sha256 + line count of the ledger). The witness
# notarizes a PREFIX: on the next append, a witness with no ledger
# (delete-then-recreate), a ledger with fewer lines than the witness (truncation),
# or a first-N-lines hash that no longer matches (rewritten history) is REFUSED —
# not silently adopted as a fresh first creation. Extra rows beyond the witnessed
# prefix are append-only extension and are accepted (this self-heals the crash
# window where an append landed but the process died before the witness update).
# A pre-witness ledger is adopted on its first sanctioned append (protection
# starts there). This is tamper-EVIDENT, not tamper-proof — a
# shell can still delete both files, but that is a two-target act that
# loop-write-guard.py escalates during a loop; the honest bound is documented
# (defense-in-depth framing, L-2).
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

# sha256, portable (macOS shasum / GNU sha256sum / python3 fallback — python3 is
# already a hard dependency of the harness). file_sha hashes a file;
# prefix_stream_sha hashes stdin (used to verify the witnessed prefix).
file_sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  fi
}
prefix_stream_sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  fi
}

write_witness() {  # write_witness <ledger> <witness>
  printf '%s %s\n' "$(file_sha "$1")" "$(wc -l < "$1" | tr -d ' ')" > "$2" \
    || die "cannot write witness $2"
}

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

  # --- tamper-evidence check (High: delete-recreate). Fail closed BEFORE any write.
  # The witness notarizes a PREFIX (sha256 + line count at the last sanctioned
  # append): a ledger whose first N lines still hash to the witness is untampered
  # history — extra rows beyond N are append-only extension, which is exactly what
  # the ledger permits (this also self-heals the crash window where the `>>` append
  # landed but the process died before write_witness — the row is a legitimate
  # extension, not tampering; the stale witness is refreshed by this append).
  # Refused: missing/empty file (delete-recreate), fewer lines than N (truncation),
  # or a prefix that no longer hashes to the witness (rewritten history).
  local witness="$file.witness"
  if [[ -f "$witness" ]]; then
    if [[ ! -s "$file" ]]; then
      die "witness exists but ledger $file is missing/empty — delete-recreate refused (restore the ledger, or remove the witness as an explicit human reset)"
    fi
    local want_sha want_lines have_lines prefix_sha
    want_sha="$(awk '{print $1}' "$witness")"
    want_lines="$(awk '{print $2}' "$witness")"
    have_lines="$(wc -l < "$file" | tr -d ' ')"
    if ! printf '%s' "$want_lines" | grep -qE '^[0-9]+$'; then
      die "witness $witness is malformed — refused (restore it from a backup, or remove it as an explicit human reset)"
    fi
    if [[ "$have_lines" -lt "$want_lines" ]]; then
      die "ledger $file has fewer lines than its witness (truncated) — refused (restore the ledger, or remove the witness as an explicit human reset)"
    fi
    prefix_sha="$(head -n "$want_lines" "$file" | prefix_stream_sha)"
    if [[ -z "$want_sha" || "$prefix_sha" != "$want_sha" ]]; then
      die "ledger $file does not match its witness (history rewritten since the last sanctioned append) — refused (restore the ledger, or remove the witness as an explicit human reset)"
    fi
  fi

  if [[ ! -s "$file" ]]; then   # missing OR empty (and no witness) -> header once
    printf '%s\n' "$HEADER" > "$file" || die "cannot write header to $file"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$commit" "$score" "$duration" "$status" "$desc" >> "$file" \
    || die "cannot append row to $file"
  write_witness "$file" "$witness"
}

case "${1:-}" in
  append) shift; cmd_append "$@" ;;
  path)   cmd_path ;;
  *) die "usage: loop-ledger.sh {append|path} [...]" ;;
esac
